#!/usr/bin/env python3
"""Adapted from SmallGit (MIT, Copyright 2026 VUBA). AIGauge release workflow. Standard library only; invoked by ./release.sh."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import zipfile

from notarization import Notarizer
from release_errors import ReleaseError


def github_repository(remote: str) -> str:
    """Resolve only the configured GitHub origin; never print URL credentials."""
    if remote.startswith('git@github.com:'):
        path = remote[len('git@github.com:'):]
    else:
        parsed = urlsplit(remote)
        if parsed.hostname != 'github.com' or parsed.scheme not in ('https', 'ssh'):
            raise ReleaseError('origin must point to a GitHub repository on github.com.')
        if parsed.password or (parsed.scheme == 'https' and parsed.username):
            raise ReleaseError('Remove embedded credentials from origin; use gh auth setup-git.')
        path = parsed.path.lstrip('/')
    path = path.removesuffix('.git')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*', path):
        raise ReleaseError('origin does not identify an owner/repository on GitHub.')
    return path


def parse_api_response(result: subprocess.CompletedProcess):
    """Auth, rate-limit, missing-resource, and network failures always stop."""
    status = re.search(r'^HTTP/\S+ (\d+)', result.stdout)
    if not status:
        raise ReleaseError('Cannot reach GitHub. Check connectivity and gh auth status.')
    code = int(status[1])
    if code != 200 or result.returncode:
        raise ReleaseError(f'GitHub request failed (HTTP {code}).')
    try:
        return json.loads(re.split(r'\r?\n\r?\n', result.stdout, maxsplit=1)[1])
    except (ValueError, IndexError) as error:
        raise ReleaseError('GitHub returned an invalid API response.') from error


class ReleaseWorkflow:
    def __init__(self, root: Path, *, local=False, publish=False, check_only=False, notes: Path | None = None,
                 notarize=False, notary_profile: str | None = None):
        self.root = root.resolve()
        self.local, self.publish, self.notes = local, publish, notes
        self.check_only = check_only
        self.package = self.root / 'aigauge'
        self.work = self.package / '.build/release-workflow'
        self.output = self.package / 'release'
        self.env = os.environ.copy()
        self.require_notarization = notarize or not local
        self.notarizer = Notarizer(self.work / 'notary', self.command)
        self.notary_profile = notary_profile or self.env.get('NOTARY_KEYCHAIN_PROFILE', 'AIGauge')
        self.notarization = {'status': 'not requested (local build)', 'stapled': False}
        # GitHub operations inherit the user's real auth/config. Isolated Git
        # settings live only in the test script's subprocess, never in this env.
        self.env.update(GH_PROMPT_DISABLED='1', GH_PAGER='cat', GH_DEBUG='', GIT_TERMINAL_PROMPT='0')
        for variable in ('GIT_TRACE', 'GIT_TRACE_CURL', 'GIT_CURL_VERBOSE', 'GIT_TRACE_PACKET'):
            self.env.pop(variable, None)

    def command(self, args, *, check=True):
        result = subprocess.run([str(x) for x in args], cwd=self.root, env=self.env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and result.returncode:
            raise ReleaseError(f'{args[0]} {args[1]} failed: {result.stderr.strip()}')
        return result

    def logged(self, args, name):
        path = self.work / f'{name}.log'
        print(f'[{name}] Log: {path.relative_to(self.root)}', flush=True)
        with path.open('w') as log:
            process = subprocess.Popen([str(x) for x in args], cwd=self.root, env=self.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                       start_new_session=True)
            try:
                for line in process.stdout:
                    log.write(line)
                    print(line, end='', flush=True)
                if process.wait():
                    raise ReleaseError(f'{name} failed; see {path.relative_to(self.root)}. No upload attempted.')
            except BaseException:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                raise

    def git(self, *args):
        return self.command(['git', *args]).stdout.strip()

    def api(self, path):
        result = self.command(['gh', 'api', '--hostname', 'github.com', '--include', path], check=False)
        return parse_api_response(result)

    def preflight(self):
        if sys.platform != 'darwin':
            raise ReleaseError('Release packaging requires macOS.')
        required = ['git', 'swift', 'ditto', 'codesign', 'nm', 'otool', 'file', 'lipo', 'strip']
        if not self.local:
            required.append('gh')
        if self.require_notarization:
            required += ['security', 'xcrun', 'spctl']
        for tool in required:
            if not shutil.which(tool):
                raise ReleaseError(f'Missing command: {tool}')
        if Path(self.git('rev-parse', '--show-toplevel')).resolve() != self.root:
            raise ReleaseError('Run the workflow from the AIGauge checkout, not a parent repository.')
        self.commit = self.git('rev-parse', 'HEAD')
        self.dirty = bool(self.git('status', '--porcelain', '--untracked-files=all'))
        if self.dirty and not self.local:
            raise ReleaseError('Commit all intended changes before release. Use --local to test an uncommitted build.')
        self.command([self.root / 'make_version.sh', '--check'])
        info = plistlib.loads((self.package / 'Info.plist').read_bytes())
        self.version, self.build = info['CFBundleShortVersionString'], info['CFBundleVersion']
        if not re.fullmatch(r'\d+\.\d+\.\d+', self.version) or not re.fullmatch(r'[1-9]\d*', self.build):
            raise ReleaseError('Invalid version metadata. Update AppVersion and run ./make_version.sh.')
        self.tag = f'v{self.version}'
        if self.notes and not self.notes.is_file():
            raise ReleaseError(f'Release notes file does not exist: {self.notes}')
        if self.require_notarization:
            self.env['SIGN_ID'] = self.notarizer.configure(
                identity=self.env.get('SIGN_ID'), profile=self.notary_profile)
        if not self.local:
            self.repo = github_repository(self.git('remote', 'get-url', 'origin'))
            self.branch = self.git('branch', '--show-current')
            if not self.branch:
                raise ReleaseError('Check out the pushed release branch before uploading.')
            self.check_remote()
        print(f'AIGauge {self.version} ({self.build}) at {self.commit[:12]} — '
              f'{"local only" if self.local else ("publish" if self.publish else "draft")}', flush=True)

    def check_branch(self):
        ref = f'refs/heads/{self.branch}'
        lines = self.git('ls-remote', '--heads', 'origin', ref).splitlines()
        if not any(line.split() == [self.commit, ref] for line in lines):
            raise ReleaseError('HEAD must match the pushed origin branch. Push the intended commit, then rerun.')

    def find_release(self):
        # The list endpoint includes drafts for callers with push access, unlike
        # relying on a lookup of a published release by tag. Paginate to include
        # old versions too, not just the latest page of releases.
        page = 1
        while True:
            releases = self.api(f'repos/{self.repo}/releases?per_page=100&page={page}')
            if not isinstance(releases, list):
                raise ReleaseError('GitHub returned an invalid release list.')
            for release in releases:
                if release.get('tag_name') == self.tag:
                    return release
            if len(releases) < 100:
                return None
            page += 1

    def check_remote(self):
        self.check_branch()
        repository = self.api(f'repos/{self.repo}')
        if repository.get('archived'):
            raise ReleaseError('The origin repository is archived; releases cannot be uploaded.')
        if not repository.get('permissions', {}).get('push'):
            raise ReleaseError('The active gh account needs push access to the origin repository.')
        if self.find_release() is not None:
            raise ReleaseError(f'{self.tag} already has a release. Nothing is overwritten. '
                               'Choose a new version, or review and publish the existing draft separately.')
        self.check_tag()

    def check_tag(self, *, required=False):
        refs = self.git('ls-remote', '--tags', 'origin', f'refs/tags/{self.tag}', f'refs/tags/{self.tag}^{{}}')
        tags = dict(reversed(line.split()) for line in refs.splitlines())
        target = tags.get(f'refs/tags/{self.tag}^{{}}', tags.get(f'refs/tags/{self.tag}'))
        if required and not target:
            raise ReleaseError('Published release tag is missing on origin.')
        if target and target != self.commit:
            raise ReleaseError(f'{self.tag} already points to another commit. Bump the version; do not move the tag.')

    def verify_bundle(self):
        app = self.output / 'AIGauge.app'
        executable = app / 'Contents/MacOS/AIGauge'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (self.version, self.build):
            raise ReleaseError('Packaged app version does not match AppVersion metadata.')
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.txt'):
            if (app / 'Contents/Resources' / name).read_bytes() != (self.root / name).read_bytes():
                raise ReleaseError(f'Packaged {name} is missing or stale.')
        if (app / 'Contents/Resources/ClaudeGauge-LICENSE').read_bytes() != (self.root / 'claude-gauge/LICENSE').read_bytes():
            raise ReleaseError('Packaged ClaudeGauge license is missing or stale.')
        if list(app.rglob('*.dSYM')):
            raise ReleaseError('Release bundle contains a dSYM.')
        binaries = ['Contents/MacOS/AIGauge'] + [
            f'Contents/Resources/{name}' for name in ('ClaudeGauge', 'CodexGauge', 'MistralGauge')]
        allowed = set(binaries) | {
            'Contents/Info.plist', 'Contents/Resources/LICENSE',
            'Contents/Resources/THIRD_PARTY_NOTICES.txt', 'Contents/Resources/ClaudeGauge-LICENSE',
            'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources',
            'Contents/CodeResources'}  # Apple's stapled notarization ticket.
        for item in app.rglob('*'):
            if item.is_symlink() or (item.is_file() and item.relative_to(app).as_posix() not in allowed):
                raise ReleaseError('Release bundle contains unexpected files or symlinks; inspect it for private data.')
        for relative in binaries:
            binary = app / relative
            if not binary.is_file() or 'Mach-O' not in self.command(['file', '-b', binary]).stdout:
                raise ReleaseError('A required bundled executable is missing or invalid.')
            if re.search(rb'/(?:Users/[A-Za-z0-9._-]+/|Volumes/Workspace/|private/var/folders/)', binary.read_bytes()):
                raise ReleaseError('Release executable contains personal build paths; remove source/debug path metadata.')
            if '__DWARF' in self.command(['otool', '-l', binary]).stdout:
                raise ReleaseError('Release bundle contains embedded DWARF debug data.')
            symbols = self.command(['nm', '-a', binary]).stdout.splitlines()
            defined = [re.match(r'^[0-9a-fA-F]+\s+([A-Za-z])\s+(\S+)', line) for line in symbols]
            if any(match and match[1] not in ('u', 'U') and match[2] != '__mh_execute_header' for match in defined):
                raise ReleaseError('Release executable still contains defined symbols; strip it before distribution.')
        self.command(['codesign', '--verify', '--deep', '--strict', app])
        arches = set(self.command(['lipo', '-archs', executable]).stdout.split())
        if arches == {'arm64', 'x86_64'}:
            self.arch = 'universal'
        elif arches in ({'arm64'}, {'x86_64'}):
            self.arch = next(iter(arches))
        else:
            raise ReleaseError('Unexpected executable architecture.')
        for relative in binaries[1:]:
            if set(self.command(['lipo', '-archs', app / relative]).stdout.split()) != arches:
                raise ReleaseError('Bundled helper architecture does not match the app.')
        signature = self.command(['codesign', '-d', '--verbose=2', app]).stderr
        self.signing = ('ad-hoc' if 'Signature=adhoc' in signature else
                        'Developer ID' if 'Authority=Developer ID Application:' in signature else 'other identity')
        return app

    def package_assets(self, app):
        stem = f'AIGauge-{self.version}-macos-{self.arch}'
        archive = self.output / f'{stem}.zip'
        # ditto can add to an existing archive. Always create a fresh temporary
        # archive, then replace only this version/architecture's local ZIP.
        temporary = self.work / 'AIGauge.zip'
        temporary.unlink(missing_ok=True)
        self.command(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, temporary])
        with zipfile.ZipFile(temporary) as zipped:
            if zipped.testzip() is not None:
                raise ReleaseError('ZIP integrity check failed.')
            for name in zipped.namelist():
                parts = PurePosixPath(name).parts
                if '..' in parts or not name.startswith('AIGauge.app/'):
                    raise ReleaseError('ZIP contains files outside AIGauge.app.')
            expected = {'AIGauge.app/' + path.relative_to(app).as_posix(): path
                        for path in app.rglob('*') if path.is_file()}
            members = [entry.filename for entry in zipped.infolist() if not entry.is_dir()]
            if len(members) != len(expected) or set(members) != set(expected):
                raise ReleaseError('ZIP contains unexpected, missing or duplicate app files.')
            for name, path in expected.items():
                if zipped.read(name) != path.read_bytes():
                    raise ReleaseError('ZIP contents do not match the verified app.')
        os.replace(temporary, archive)
        if self.require_notarization:
            self.notarizer.verify_archive(archive)
        checksum = self.output / f'{stem}.zip.sha256'
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum.write_text(f'{digest}  {archive.name}\n')
        manifest = self.output / f'{stem}.json'
        manifest.write_text(json.dumps({
            'version': self.version, 'build': self.build, 'tag': self.tag,
            'commit': self.commit, 'dirty': self.dirty, 'architecture': self.arch,
            'signing': self.signing, 'notarization': self.notarization,
            'archive': archive.name, 'sha256': digest,
            'checks': ['release tooling tests', 'four provider/GUI unit suites',
                       'version', 'licenses', 'four stripped executables', 'no DWARF/dSYM',
                       'source privacy scan', 'bundle file allowlist', 'codesign', 'ZIP integrity; no extended attributes']
                      + (['Apple Accepted', 'stapled ticket', 'Gatekeeper', 'extracted ZIP ticket']
                         if self.require_notarization else []),
        }, indent=2) + '\n')
        return [archive, checksum, manifest]

    def ensure_unchanged(self):
        if self.git('rev-parse', 'HEAD') != self.commit:
            raise ReleaseError('HEAD changed during the release; rerun from the intended commit.')
        if not self.local and self.git('status', '--porcelain', '--untracked-files=all'):
            raise ReleaseError('Files changed during the release; commit and restart before uploading.')
        self.command([self.root / 'make_version.sh', '--check'])

    def verify_uploaded(self, assets, *, draft, release_id=None):
        release = self.find_release()
        if (not release or type(release.get('id')) is not int
                or release.get('draft') is not draft
                or release.get('target_commitish') != self.commit
                or (release_id is not None and release['id'] != release_id)):
            raise ReleaseError('GitHub release identity, target commit or draft state does not match.')
        remote = self.api(f'repos/{self.repo}/releases/{release["id"]}/assets?per_page=100')
        expected = {path.name: path for path in assets}
        if (not isinstance(remote, list) or len(remote) != len(expected)
                or {asset.get('name') for asset in remote} != set(expected)):
            raise ReleaseError('GitHub does not contain exactly the expected release assets.')
        missing_digests = []
        for asset in remote:
            path = expected[asset['name']]
            if asset.get('state') != 'uploaded' or asset.get('size') != path.stat().st_size:
                raise ReleaseError(f'Incomplete GitHub asset: {path.name}')
            digest = asset.get('digest')
            if not digest:
                missing_digests.append(path)
            elif digest != 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest():
                raise ReleaseError(f'GitHub checksum mismatch: {path.name}')
        if missing_digests:
            # Older assets/API responses may lack digests. Download into a fresh
            # project-local directory and compare bytes, never skip verification.
            with tempfile.TemporaryDirectory(prefix='verify-', dir=self.work) as directory:
                args = ['gh', 'release', 'download', self.tag, '--repo', self.repo, '--dir', directory]
                for path in missing_digests:
                    args.extend(['--pattern', path.name])
                self.command(args)
                for path in missing_digests:
                    if (Path(directory) / path.name).read_bytes() != path.read_bytes():
                        raise ReleaseError(f'Downloaded GitHub asset mismatch: {path.name}')
        return release

    def upload(self, assets):
        if self.notarization.get('status') != 'Accepted' or not self.notarization.get('stapled'):
            raise ReleaseError('GitHub upload requires Apple acceptance and a validated stapled ticket.')
        # Repeat after the potentially long build: fail if a release was created
        # or the remote branch/tag moved in the meantime. Never clobber assets.
        self.check_remote()
        notes = self.work / 'notes.md'
        notes.write_text((self.notes.read_text() + '\n\n' if self.notes else '') +
                         f'Build {self.build}; macOS {self.arch}; commit `{self.commit}`.\n\n'
                         f'Signing: {self.signing}. Apple notarization: Accepted; ticket stapled and Gatekeeper verified.\n'
                         'The ZIP contains AIGauge.app. SHA-256 and build metadata are attached.\n')
        args = ['gh', 'release', 'create', self.tag, *assets, '--repo', self.repo,
                '--target', self.commit, '--title', f'AIGauge {self.version} ({self.build})',
                '--notes-file', notes, '--draft']
        if not self.notes:
            args.append('--generate-notes')
        result = self.command(args, check=False)
        if result.returncode:
            raise ReleaseError('GitHub upload failed. A partial draft may remain; inspect it with '
                               f'gh release view {self.tag} --repo {self.repo}. Local assets are retained. '
                               'No existing release or assets were overwritten.')
        try:
            release = self.verify_uploaded(assets, draft=True)
            if self.publish:
                self.ensure_unchanged()
                self.check_branch()
                self.check_tag()
                self.command(['gh', 'release', 'edit', self.tag, '--repo', self.repo,
                              '--draft=false'])
                release = self.verify_uploaded(assets, draft=False, release_id=release['id'])
                self.check_tag(required=True)
        except (ReleaseError, OSError) as error:
            raise ReleaseError(f'Release verification/publication did not complete: {error} '
                               f'Inspect gh release view {self.tag} --repo {self.repo} before retrying. '
                               'Local assets are retained; nothing was deleted or overwritten.') from error
        print(f'Verified {len(assets)} GitHub assets; {"published" if self.publish else "draft"}.', flush=True)
        print(release['html_url'], flush=True)

    def run(self):
        self.work.mkdir(parents=True, exist_ok=True)
        with (self.work / 'run.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ReleaseError('Another release workflow is already running in this checkout.') from error
            self.preflight()
            self.logged(['python3', '-B', self.package / 'scripts/check-privacy.py'], 'privacy')
            if self.check_only:
                print('Ready: source, version, GitHub permissions and release/tag checks passed. '
                      'No build, upload or GitHub changes performed.', flush=True)
                return
            self.logged([self.package / 'scripts/test-release.sh'], 'tests')
            # Keep caches/temp in the project without overriding GitHub auth.
            for name, path in {
                'TMPDIR': self.work / 'tmp',
                'CLANG_MODULE_CACHE_PATH': self.package / '.build/cache/clang',
                'SWIFTPM_MODULECACHE_OVERRIDE': self.package / '.build/cache/swift',
            }.items():
                path.mkdir(parents=True, exist_ok=True)
                self.env[name] = str(path) + ('/' if name == 'TMPDIR' else '')
            self.logged([self.package / 'build.sh'], 'build')
            app = self.verify_bundle()
            if self.require_notarization:
                self.notarization = self.notarizer.notarize(app)
                self.verify_bundle()  # Recheck signed bundle and allowed files after stapling.
            assets = self.package_assets(app)
            self.ensure_unchanged()
            if not self.local:
                self.upload(assets)
            print('Local assets:\n' + '\n'.join(str(p.relative_to(self.root)) for p in assets), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(prog='./release.sh', description='Test, build, verify, ZIP, and upload AIGauge using gh. Default: draft release.')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--local', action='store_true', help='run checks and package locally; no release API calls, tags, or upload')
    mode.add_argument('--check', action='store_true', help='check clean/pushed source, version and GitHub access; no build or upload')
    mode.add_argument('--publish', action='store_true', help='publish a new release immediately instead of leaving a draft')
    parser.add_argument('--notarize', action='store_true', help='also notarize a --local build; required automatically for GitHub upload modes')
    parser.add_argument('--notary-profile', help='notarytool Keychain profile (default: NOTARY_KEYCHAIN_PROFILE or AIGauge)')
    parser.add_argument('--notes', type=Path, help='release notes file; default: generated GitHub notes plus build details')
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    try:
        ReleaseWorkflow(root, local=args.local, publish=args.publish, check_only=args.check,
                        notes=args.notes.resolve() if args.notes else None,
                        notarize=args.notarize, notary_profile=args.notary_profile).run()
        return 0
    except (ReleaseError, OSError, ValueError, zipfile.BadZipFile) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Release interrupted. Check GitHub for a partial draft if upload had started.', file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())

"""Developer ID / Apple notarization gates. Credentials stay in Keychain."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import re
import tempfile
import uuid
import zipfile

from release_errors import NotarizationError

BINARY_PATHS = ['Contents/MacOS/AIGauge'] + [
    f'Contents/Resources/{name}' for name in ('ClaudeGauge', 'CodexGauge', 'MistralGauge')]


class Notarizer:
    def __init__(self, work: Path, command):
        self.work = work
        self.command = command
        self.profile = None
        self.identity = None
        self.team = None
        self.result = None

    def configure(self, *, identity: str | None, profile: str):
        output = self.command(['security', 'find-identity', '-v', '-p', 'codesigning']).stdout
        identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(Developer ID Application:[^"]+)"\s*$',
                                output, re.MULTILINE)
        if identity:
            identities = [(digest, name) for digest, name in identities
                          if identity.lower() == digest.lower() or identity == name]
        if not identities:
            raise NotarizationError('A valid Developer ID Application certificate with its private key is required. '
                                    'Apple Development, Apple Distribution and ad-hoc signatures cannot be used.')
        if len(identities) != 1:
            raise NotarizationError('Multiple Developer ID Application identities found. Select one with SIGN_ID.')
        if not profile.strip():
            raise NotarizationError('Set --notary-profile or NOTARY_KEYCHAIN_PROFILE to a stored notarytool profile.')
        self.identity = identities[0][0]
        team = re.search(r'\(([A-Z0-9]{10})\)$', identities[0][1])
        if team is None:
            raise NotarizationError('Could not determine the Developer ID certificate Team ID.')
        self.team = team[1]
        self.profile = profile
        self.command(['xcrun', '--find', 'notarytool'])
        self.command(['xcrun', '--find', 'stapler'])
        # Validate stored credentials without printing/saving other submission history.
        self.command(['xcrun', 'notarytool', 'history', '--keychain-profile', self.profile,
                      '--output-format', 'json', '--no-progress'])
        return self.identity

    def verify_signatures(self, app: Path):
        teams = set()
        for relative in BINARY_PATHS:
            binary = app / relative
            signature = self.command(['codesign', '-d', '--verbose=4', binary]).stderr
            if 'Authority=Developer ID Application:' not in signature:
                raise NotarizationError('Every executable must be signed with Developer ID Application.')
            if not re.search(r'flags=0x[0-9a-fA-F]+\([^\n)]*\bruntime\b', signature):
                raise NotarizationError('Hardened Runtime is missing from a bundled executable.')
            if not re.search(r'^Timestamp=', signature, re.MULTILINE):
                raise NotarizationError('A bundled executable is missing a secure signing timestamp.')
            team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signature, re.MULTILINE)
            if team is None:
                raise NotarizationError('A bundled executable is missing its signing Team ID.')
            teams.add(team[1])
            raw = self.command(['codesign', '-d', '--entitlements', '-', binary]).stdout
            if raw.strip():
                try:
                    entitlements = plistlib.loads(raw.encode())
                except (ValueError, plistlib.InvalidFileException) as error:
                    raise NotarizationError('Could not inspect signed entitlements.') from error
                if not isinstance(entitlements, dict) or entitlements.get('com.apple.security.get-task-allow') not in (None, False):
                    raise NotarizationError('Debug get-task-allow entitlements cannot be distributed.')
        if teams != {self.team}:
            raise NotarizationError('The app and all bundled CLIs must match the selected Developer ID Team ID.')
        self.command(['codesign', '--verify', '--deep', '--strict', app])

    def notarize(self, app: Path):
        self.verify_signatures(app)
        self.work.mkdir(parents=True, exist_ok=True, mode=0o700)
        archive = self.work / 'submission.zip'
        archive.unlink(missing_ok=True)
        self.command(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, archive])
        expected = {'AIGauge.app/' + path.relative_to(app).as_posix(): path
                    for path in app.rglob('*') if path.is_file()}
        with zipfile.ZipFile(archive) as zipped:
            names = [entry.filename for entry in zipped.infolist() if not entry.is_dir()]
            if (zipped.testzip() is not None or len(names) != len(expected) or set(names) != set(expected)
                    or any(zipped.read(name) != path.read_bytes() for name, path in expected.items())):
                raise NotarizationError('Apple submission ZIP does not contain exactly the verified app.')
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        print('Submitting Developer ID-signed app to Apple; waiting for acceptance…', flush=True)
        response = self.command(['xcrun', 'notarytool', 'submit', archive,
                                 '--keychain-profile', self.profile, '--wait', '--timeout', '20m',
                                 '--output-format', 'json', '--no-progress'], check=False)
        (self.work / 'submission.json').write_text(response.stdout)
        try:
            submission = json.loads(response.stdout)
            identifier = str(uuid.UUID(submission['id']))
        except (ValueError, KeyError, TypeError) as error:
            raise NotarizationError('Apple did not return a valid submission ID. Inspect local notary/submission.json; no upload to GitHub was attempted.') from error
        log_response = self.command(['xcrun', 'notarytool', 'log', identifier,
                                     '--keychain-profile', self.profile], check=False)
        (self.work / 'notary-log.json').write_text(log_response.stdout)
        if response.returncode or submission.get('status') != 'Accepted':
            raise NotarizationError(f'Apple has not accepted submission {identifier}. Inspect local notary logs. '
                                    'If processing continues, use notarytool wait for this ID rather than resubmitting. No GitHub upload attempted.')
        try:
            log = json.loads(log_response.stdout)
        except (ValueError, TypeError) as error:
            raise NotarizationError('Could not read Apple notarization log; no GitHub upload attempted.') from error
        if (not isinstance(log, dict) or log_response.returncode or log.get('jobId') != identifier
                or log.get('status') != 'Accepted' or log.get('sha256') != digest):
            raise NotarizationError('Apple notarization log does not confirm acceptance of this exact archive.')
        issues = log.get('issues') or []
        if not isinstance(issues, list) or any(not isinstance(issue, dict) for issue in issues):
            raise NotarizationError('Apple notarization log has an invalid issues list.')
        if any(issue.get('severity') == 'error' for issue in issues):
            raise NotarizationError('Apple notarization log contains an error; inspect it before distribution.')
        self.command(['xcrun', 'stapler', 'staple', app])
        self.verify_ticket(app)
        self.result = {'status': 'Accepted', 'submissionId': identifier,
                       'stapled': True, 'gatekeeper': 'accepted',
                       'warningCount': sum(issue.get('severity') == 'warning' for issue in issues)}
        print('Apple accepted the app; stapled ticket and Gatekeeper checks passed.', flush=True)
        return self.result

    def verify_ticket(self, app: Path):
        self.command(['xcrun', 'stapler', 'validate', app])
        self.command(['codesign', '--verify', '--deep', '--strict', app])
        self.command(['spctl', '--assess', '--type', 'execute', '--verbose=2', app])

    def verify_archive(self, archive: Path):
        # Validate the actual distributable after extraction: this catches losing
        # a staple during ZIP creation even if the original app still passes.
        with tempfile.TemporaryDirectory(prefix='final-zip-', dir=self.work) as directory:
            self.command(['ditto', '-x', '-k', archive, directory])
            self.verify_ticket(Path(directory) / 'AIGauge.app')

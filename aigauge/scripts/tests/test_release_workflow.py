"""Exercise release gates and upload arguments without GitHub, Swift, or a desktop."""
import contextlib
import fcntl
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release import ReleaseError, ReleaseWorkflow, github_repository, parse_api_response

# scripts/tests -> scripts -> AIGauge; keep all fixtures in the project.
SCRATCH = Path(__file__).resolve().parents[2] / '.build/release-tool-tests'


class SimulatedWorkflow(ReleaseWorkflow):
    """Real orchestration, filesystem packaging and manifest; external tools scripted."""
    def __init__(self, root, **kwargs):
        super().__init__(root, **kwargs)
        self.calls = []
        self.status = ''
        self.remote_sha = 'a' * 40
        self.remote_tag = ''
        self.existing_release = None
        self.api_status = 200
        self.can_push = True
        self.release_pages = None
        self.fail_stage = None
        self.defect = None
        self.upload_failure = False
        self.upload_defect = None
        self.publish_failure = False
        self.uploaded_content = {}
        self.archived = False
        self.head = 'a' * 40
        self.notary_defect = None
        self.env['SIGN_ID'] = 'D' * 40

    def command(self, args, *, check=True):
        args = [str(x) for x in args]
        self.calls.append(args)
        out, err, code = '', '', 0
        if args[:3] == ['git', 'rev-parse', '--show-toplevel']:
            out = str(self.root)
        elif args[:3] == ['git', 'rev-parse', 'HEAD']:
            out = self.head
        elif args[:2] == ['git', 'status']:
            out = self.status
        elif args[:2] == ['git', 'branch']:
            out = 'main'
        elif args[:3] == ['git', 'remote', 'get-url']:
            out = 'https://github.com/example/AIGauge.git'
        elif args[:3] == ['git', 'ls-remote', '--heads']:
            out = self.remote_sha + '\trefs/heads/main\n'
        elif args[:3] == ['git', 'ls-remote', '--tags']:
            out = self.remote_tag
        elif args[:2] == ['security', 'find-identity']:
            out = '  1) ' + 'D' * 40 + ' "Developer ID Application: Example (TEAMID1234)"\n'
            if self.notary_defect == 'no Developer ID':
                out = '  1) ' + 'D' * 40 + ' "Apple Distribution: Example (TEAMID1234)"\n'
            if self.notary_defect == 'multiple identities':
                out += '  2) ' + 'E' * 40 + ' "Developer ID Application: Other (OTHERT1234)"\n'
        elif args[:2] == ['xcrun', '--find']:
            out = '/mock/' + args[-1]
        elif args[:3] == ['xcrun', 'notarytool', 'history']:
            out = '{"history":[]}'
            if self.notary_defect == 'credentials': code, err = 1, 'No stored profile'
        elif args[:3] == ['xcrun', 'notarytool', 'submit']:
            status = 'Invalid' if self.notary_defect == 'rejected' else 'Accepted'
            if self.notary_defect == 'timeout': status, code = 'In Progress', 1
            if self.notary_defect == 'nonzero accepted': code = 1
            out = json.dumps({'id': '00000000-0000-4000-8000-000000000001', 'status': status})
            if self.notary_defect == 'invalid JSON': out = 'invalid'
        elif args[:3] == ['xcrun', 'notarytool', 'log']:
            digest = hashlib.sha256((self.work / 'notary/submission.zip').read_bytes()).hexdigest()
            if self.notary_defect == 'wrong archive': digest = '0' * 64
            out = json.dumps({'jobId': args[3], 'status': 'Accepted', 'sha256': digest, 'issues': None})
            if self.notary_defect == 'invalid log JSON': out = 'invalid'
            if self.notary_defect == 'wrong log type': out = '[]'
            if self.notary_defect == 'log request': code = 1
            if self.notary_defect in ('error issue', 'malformed issues'):
                issues = [{'severity': 'error'}] if self.notary_defect == 'error issue' else 'invalid'
                out = json.dumps({'jobId': args[3], 'status': 'Accepted', 'sha256': digest, 'issues': issues})
        elif args[:3] == ['xcrun', 'stapler', 'staple']:
            if self.notary_defect == 'staple': code, err = 1, 'Staple failed'
            else: (Path(args[-1]) / 'Contents/CodeResources').write_bytes(b'fake Apple ticket')
        elif args[:3] == ['xcrun', 'stapler', 'validate']:
            if not (Path(args[-1]) / 'Contents/CodeResources').exists(): code, err = 1, 'No ticket'
        elif args[0] == 'spctl':
            if self.notary_defect == 'Gatekeeper': code, err = 1, 'Assessment rejected'
        elif args[0].endswith('make_version.sh'):
            if self.defect == 'stale metadata':
                code, err = 1, 'Run ./make_version.sh and commit the synced metadata.'
        elif args[:2] == ['gh', 'api']:
            status, body = self.api_status, {'permissions': {'push': self.can_push}, 'archived': self.archived}
            if '/releases?' in args[-1]:
                body = [] if self.existing_release is None else [dict(self.existing_release, tag_name='v26.11.01')]
                if self.release_pages is not None:
                    body = self.release_pages[int(args[-1].rsplit('=', 1)[1]) - 1]
            elif '/assets?' in args[-1]:
                body = [{'name': name, 'state': 'uploaded', 'size': len(content),
                         'digest': 'sha256:' + hashlib.sha256(content).hexdigest()}
                        for name, content in self.uploaded_content.items()]
                if self.upload_defect == 'missing': body.pop()
                if self.upload_defect == 'extra': body.append(dict(body[0], name='unexpected.txt'))
                if self.upload_defect == 'duplicate': body[1] = dict(body[0])
                if self.upload_defect == 'size': body[0]['size'] += 1
                if self.upload_defect == 'state': body[0]['state'] = 'starter'
                if self.upload_defect == 'checksum': body[0]['digest'] = 'sha256:' + '0' * 64
                if self.upload_defect in ('no digest', 'download corrupt'):
                    for asset in body: asset['digest'] = None
            out = f'HTTP/2.0 {status} Status\r\nContent-Type: application/json\r\n\r\n' + json.dumps(body)
            code = 0 if status == 200 else 1
        elif args[0] == 'file':
            out = 'Mach-O 64-bit' if Path(args[-1]).name in ('AIGauge', 'ClaudeGauge', 'CodexGauge', 'MistralGauge') else 'text'
        elif args[0] == 'otool':
            out = 'segname __DWARF' if self.defect == 'DWARF' else 'segname __TEXT'
        elif args[0] == 'nm':
            out = '0000000100000000 T __mh_execute_header\n'
            if self.defect == 'symbols':
                out += '0000000100000042 t _debug_symbol\n'
        elif args[:2] == ['codesign', '--verify']:
            if self.defect == 'signature':
                code, err = 1, 'invalid signature'
        elif args[0] == 'codesign':
            if '--entitlements' in args:
                out = plistlib.dumps({'com.apple.security.get-task-allow': True}
                    if self.notary_defect == 'debug entitlement' else {}).decode()
            elif self.require_notarization and self.notary_defect != 'ad-hoc':
                err = ('Authority=Developer ID Application: Example (TEAMID1234)\n'
                       'CodeDirectory flags=0x10000(runtime)\n'
                       'Timestamp=Jan 1, 2026 at 12:00:00\nTeamIdentifier=TEAMID1234\n')
                if self.notary_defect == 'runtime': err = err.replace('(runtime)', '()')
                if self.notary_defect == 'timestamp': err = err.replace('Timestamp=', 'Signed Time=')
                if self.notary_defect == 'helper team' and Path(args[-1]).name == 'MistralGauge':
                    err = err.replace('TeamIdentifier=TEAMID1234', 'TeamIdentifier=OTHERT1234')
            else: err = 'Signature=adhoc\n'
        elif args[0] == 'lipo':
            out = 'arm64'
        elif args[0] == 'ditto':
            if '-x' in args:
                with zipfile.ZipFile(args[-2]) as archive:
                    archive.extractall(args[-1])
                if self.notary_defect == 'lost ZIP ticket':
                    (Path(args[-1]) / 'AIGauge.app/Contents/CodeResources').unlink()
                return subprocess.CompletedProcess(args, 0, '', '')
            app, target = Path(args[-2]), Path(args[-1])
            with zipfile.ZipFile(target, 'w') as zipped:
                for p in app.rglob('*'):
                    if p.is_file():
                        zipped.write(p, 'AIGauge.app/' + p.relative_to(app).as_posix())
                if self.defect == 'archive leak':
                    zipped.writestr('.private/notes.txt', 'must not ship')
        elif args[:3] == ['gh', 'release', 'create']:
            code = int(self.upload_failure)
            out = 'https://github.com/example/AIGauge/releases/tag/v26.11.01\n'
            self.uploaded_content = {Path(p).name: Path(p).read_bytes() for p in args[4:args.index('--repo')]}
            self.existing_release = {'id': 42, 'draft': True, 'target_commitish': self.head,
                                     'html_url': out.strip()}
            if self.upload_defect == 'target': self.existing_release['target_commitish'] = 'b' * 40
            if self.upload_defect == 'published early': self.existing_release['draft'] = False
            if self.upload_defect == 'missing release': self.existing_release = None
            if self.upload_defect == 'API': self.api_status = 503
            if self.upload_defect == 'branch moved': self.remote_sha = 'b' * 40
            if self.upload_defect == 'tag moved': self.remote_tag = 'b' * 40 + '\trefs/tags/v26.11.01\n'
        elif args[:3] == ['gh', 'release', 'download']:
            directory = Path(args[args.index('--dir') + 1])
            for name, content in self.uploaded_content.items():
                if name in args:
                    (directory / name).write_bytes(b'corrupt' if self.upload_defect == 'download corrupt' else content)
        elif args[:3] == ['gh', 'release', 'edit']:
            code, err = int(self.publish_failure), 'publish failed'
            if not code:
                self.existing_release['draft'] = False
                self.remote_tag = self.head + '\trefs/tags/v26.11.01\n'
                if self.upload_defect == 'published wrong tag':
                    self.remote_tag = 'b' * 40 + '\trefs/tags/v26.11.01\n'
                if self.upload_defect == 'published wrong ID': self.existing_release['id'] = 43
                if self.upload_defect == 'stays draft': self.existing_release['draft'] = True
        else:
            raise AssertionError(f'Unexpected command: {args}')
        result = subprocess.CompletedProcess(args, code, out, err)
        if check and code:
            raise ReleaseError(err)
        return result

    def logged(self, args, name):
        self.calls.append([name])
        if name == self.fail_stage:
            raise ReleaseError(name + ' failed')
        if name != 'build':
            return
        app = self.output / 'AIGauge.app'
        if app.exists():
            shutil.rmtree(app)
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources').mkdir()
        info = plistlib.loads((self.package / 'Info.plist').read_bytes())
        if self.defect == 'version':
            info['CFBundleVersion'] = '1'
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/MacOS/AIGauge').write_bytes(b'fake app binary')
        for helper in ('ClaudeGauge', 'CodexGauge', 'MistralGauge'):
            (app / 'Contents/Resources' / helper).write_bytes(b'fake helper binary')
        (app / 'Contents/Resources/ClaudeGauge-LICENSE').write_bytes((self.root / 'claude-gauge/LICENSE').read_bytes())
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.txt'):
            (app / 'Contents/Resources' / name).write_bytes((self.root / name).read_bytes())
        if self.defect == 'license':
            (app / 'Contents/Resources/LICENSE').write_text('wrong license')
        if self.defect == 'dSYM':
            (app / 'Bad.dSYM').mkdir()
        if self.defect == 'private file':
            (app / 'Contents/Resources/session.log').write_text('must not ship')
        if self.defect == 'helper missing':
            (app / 'Contents/Resources/MistralGauge').unlink()
        if self.defect == 'personal build path':
            (app / 'Contents/Resources/MistralGauge').write_bytes(b'/Users' + b'/someone/project/private.swift')
        if self.defect == 'symlink':
            (app / 'Contents/Resources/secret-link').symlink_to(self.root / 'LICENSE')
        if self.defect == 'changed source':
            self.status = ' M changed.swift'
        if self.defect == 'changed HEAD':
            self.head = 'b' * 40
        if self.defect == 'remote moved':
            self.remote_sha = 'b' * 40
        if self.defect == 'release race':
            self.existing_release = {'draft': False}


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        SCRATCH.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=SCRATCH)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'aigauge').mkdir()
        (self.root / 'aigauge/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '26.11.01', 'CFBundleVersion': '261101',
        }))
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.txt'):
            (self.root / name).write_text(name + '\n')
        (self.root / 'claude-gauge').mkdir()
        (self.root / 'claude-gauge/LICENSE').write_text('Claude MIT license\n')

    def run_flow(self, flow):
        with patch('release.sys.platform', 'darwin'), patch('release.shutil.which', return_value='/mock/tool'), \
                contextlib.redirect_stdout(io.StringIO()):
            flow.run()

    def uploads(self, flow):
        return [call for call in flow.calls if call[:3] == ['gh', 'release', 'create']]

    def test_default_draft_targets_exact_commit_and_uploads_only_verified_assets(self):
        flow = SimulatedWorkflow(self.root)
        self.run_flow(flow)
        call, = self.uploads(flow)
        self.assertIn('--draft', call)
        self.assertEqual(call[call.index('--target') + 1], 'a' * 40)
        self.assertEqual(call[call.index('--repo') + 1], 'example/AIGauge')
        self.assertNotIn('--clobber', call)
        self.assertEqual(len(call[4:call.index('--repo')]), 3)
        manifest, = (self.root / 'aigauge/release').glob('*.json')
        data = json.loads(manifest.read_text())
        archive = self.root / 'aigauge/release' / data['archive']
        self.assertEqual(data['sha256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertFalse(data['dirty'])
        self.assertIn(data['sha256'], archive.with_suffix('.zip.sha256').read_text())

    def test_publish_is_explicit(self):
        flow = SimulatedWorkflow(self.root, publish=True)
        self.run_flow(flow)
        self.assertIn('--draft', self.uploads(flow)[0])
        edits = [call for call in flow.calls if call[:3] == ['gh', 'release', 'edit']]
        self.assertEqual(len(edits), 1)
        self.assertIn('--draft=false', edits[0])
        asset_checks = [i for i, call in enumerate(flow.calls) if '/assets?' in call[-1]]
        self.assertLess(asset_checks[0], flow.calls.index(edits[0]))
        self.assertGreater(asset_checks[-1], flow.calls.index(edits[0]))

    def test_notarized_pipeline_staples_before_zip_and_verifies_extracted_ticket(self):
        flow = SimulatedWorkflow(self.root, publish=True, notary_profile='private-profile-name')
        self.run_flow(flow)
        submit = next(i for i, call in enumerate(flow.calls) if call[:3] == ['xcrun', 'notarytool', 'submit'])
        staple = next(i for i, call in enumerate(flow.calls) if call[:3] == ['xcrun', 'stapler', 'staple'])
        upload = next(i for i, call in enumerate(flow.calls) if call[:3] == ['gh', 'release', 'create'])
        extracts = [i for i, call in enumerate(flow.calls) if call[:3] == ['ditto', '-x', '-k']]
        self.assertLess(submit, staple)
        self.assertLess(staple, extracts[0])
        self.assertLess(extracts[0], upload)
        manifest, = flow.output.glob('*.json')
        data = json.loads(manifest.read_text())
        self.assertEqual(data['notarization']['status'], 'Accepted')
        self.assertTrue(data['notarization']['stapled'])
        self.assertEqual(data['notarization']['gatekeeper'], 'accepted')
        self.assertNotIn('private-profile-name', manifest.read_text())
        self.assertNotIn('Developer ID Application: Example', manifest.read_text())
        notes = (flow.work / 'notes.md').read_text()
        self.assertIn('Apple notarization: Accepted', notes)

    def test_notarization_or_gatekeeper_failures_never_upload_to_github(self):
        for defect in ('no Developer ID', 'credentials', 'ad-hoc', 'runtime', 'timestamp',
                       'debug entitlement', 'helper team', 'invalid JSON', 'rejected',
                       'timeout', 'nonzero accepted', 'wrong archive', 'invalid log JSON', 'wrong log type',
                       'log request', 'error issue', 'malformed issues', 'staple', 'Gatekeeper', 'lost ZIP ticket'):
            with self.subTest(defect=defect):
                flow = SimulatedWorkflow(self.root, publish=True)
                flow.notary_defect = defect
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))
                self.assertFalse(any(call[:3] == ['gh', 'release', 'edit'] for call in flow.calls))
                submissions = [call for call in flow.calls if call[:3] == ['xcrun', 'notarytool', 'submit']]
                self.assertLessEqual(len(submissions), 1)
                self.assertFalse(any('--force' in call for call in submissions))

    def test_no_automatic_signing_team_selection_when_multiple_identities_exist(self):
        flow = SimulatedWorkflow(self.root)
        flow.env.pop('SIGN_ID')
        flow.notary_defect = 'multiple identities'
        with self.assertRaisesRegex(ReleaseError, 'Multiple Developer ID'): self.run_flow(flow)
        self.assertNotIn(['build'], flow.calls)
        flow.env['SIGN_ID'] = 'D' * 40
        self.run_flow(flow)

    def test_local_notarization_is_explicit_and_never_calls_github(self):
        local = SimulatedWorkflow(self.root, local=True)
        self.run_flow(local)
        self.assertFalse(any(call[0] in ('security', 'xcrun', 'spctl') for call in local.calls))
        notarized = SimulatedWorkflow(self.root, local=True, notarize=True)
        self.run_flow(notarized)
        self.assertTrue(any(call[:3] == ['xcrun', 'notarytool', 'submit'] for call in notarized.calls))
        self.assertFalse(any(call[0] == 'gh' for call in notarized.calls))

    def test_direct_upload_cannot_claim_unperformed_notarization(self):
        flow = SimulatedWorkflow(self.root, local=True)
        with self.assertRaisesRegex(ReleaseError, 'Apple acceptance'): flow.upload([])
        self.assertFalse(flow.calls)

    def test_check_only_validates_remote_without_build_or_mutation(self):
        flow = SimulatedWorkflow(self.root, check_only=True)
        self.run_flow(flow)
        self.assertNotIn(['tests'], flow.calls)
        self.assertNotIn(['build'], flow.calls)
        self.assertFalse(any(call[:2] == ['gh', 'release'] for call in flow.calls))
        self.assertTrue(any(call[:2] == ['gh', 'api'] for call in flow.calls))
        self.assertFalse(flow.output.exists())

    def test_archived_repository_blocks_release(self):
        flow = SimulatedWorkflow(self.root)
        flow.archived = True
        with self.assertRaisesRegex(ReleaseError, 'archived'): self.run_flow(flow)
        self.assertNotIn(['tests'], flow.calls)

    def test_bad_uploaded_assets_or_release_never_publish(self):
        for defect in ('missing', 'extra', 'duplicate', 'size', 'state', 'checksum', 'target',
                       'published early', 'missing release', 'API', 'download corrupt',
                       'branch moved', 'tag moved'):
            with self.subTest(defect=defect):
                flow = SimulatedWorkflow(self.root, publish=True)
                flow.upload_defect = defect
                with self.assertRaisesRegex(ReleaseError, 'verification/publication'):
                    self.run_flow(flow)
                self.assertFalse(any(call[:3] == ['gh', 'release', 'edit'] for call in flow.calls))
                self.assertEqual(len(list(flow.output.glob('*.zip'))), 1)

    def test_missing_remote_digests_download_and_verify_actual_bytes(self):
        flow = SimulatedWorkflow(self.root, publish=True)
        flow.upload_defect = 'no digest'
        self.run_flow(flow)
        downloads = [call for call in flow.calls if call[:3] == ['gh', 'release', 'download']]
        self.assertEqual(len(downloads), 2)
        self.assertFalse(list(flow.work.glob('verify-*')))

    def test_publish_failure_retains_draft_and_assets(self):
        flow = SimulatedWorkflow(self.root, publish=True)
        flow.publish_failure = True
        with self.assertRaisesRegex(ReleaseError, 'verification/publication'):
            self.run_flow(flow)
        self.assertTrue(flow.existing_release['draft'])
        self.assertEqual(len(list(flow.output.glob('*.zip'))), 1)

    def test_published_release_state_id_and_real_tag_are_verified(self):
        for defect in ('stays draft', 'published wrong ID', 'published wrong tag'):
            with self.subTest(defect=defect):
                flow = SimulatedWorkflow(self.root, publish=True)
                flow.upload_defect = defect
                with self.assertRaisesRegex(ReleaseError, 'verification/publication'):
                    self.run_flow(flow)

    def test_local_accepts_dirty_source_and_never_invokes_github_release_tools(self):
        flow = SimulatedWorkflow(self.root, local=True)
        flow.status = ' M work-in-progress.swift'
        self.run_flow(flow)
        self.assertFalse(any(call[0] == 'gh' or call[:2] == ['git', 'ls-remote'] for call in flow.calls))
        manifest, = (self.root / 'aigauge/release').glob('*.json')
        self.assertTrue(json.loads(manifest.read_text())['dirty'])

    def test_dirty_or_unpushed_source_stops_before_tests(self):
        for kind in ('dirty', 'unpushed'):
            with self.subTest(kind=kind):
                flow = SimulatedWorkflow(self.root)
                if kind == 'dirty': flow.status = '?? new-file'
                else: flow.remote_sha = 'b' * 40
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertNotIn(['tests'], flow.calls)
                self.assertFalse(self.uploads(flow))

    def test_existing_draft_or_published_release_is_never_overwritten(self):
        for draft in (True, False):
            with self.subTest(draft=draft):
                flow = SimulatedWorkflow(self.root, publish=True)
                flow.existing_release = {'draft': draft}
                with self.assertRaisesRegex(ReleaseError, 'already has a release'): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))

    def test_auth_and_rate_limit_failures_are_not_treated_as_missing_release(self):
        for status in (401, 403, 404, 429, 500):
            with self.subTest(status=status):
                flow = SimulatedWorkflow(self.root)
                flow.api_status = status
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))

    def test_missing_push_permission_stops_before_listing_hidden_drafts(self):
        flow = SimulatedWorkflow(self.root)
        flow.can_push = False
        with self.assertRaisesRegex(ReleaseError, 'push access'): self.run_flow(flow)
        self.assertFalse(any('/releases?' in call[-1] for call in flow.calls))

    def test_existing_release_on_later_page_is_not_missed(self):
        flow = SimulatedWorkflow(self.root)
        flow.release_pages = [[{'tag_name': f'v{i}.0.0'} for i in range(100)],
                              [{'tag_name': 'v26.11.01', 'draft': True}]]
        with self.assertRaisesRegex(ReleaseError, 'already has a release'): self.run_flow(flow)
        self.assertFalse(self.uploads(flow))

    def test_tag_mismatch_is_rejected_but_matching_annotated_tag_is_accepted(self):
        flow = SimulatedWorkflow(self.root)
        flow.remote_tag = 'b' * 40 + '\trefs/tags/v26.11.01\n'
        with self.assertRaisesRegex(ReleaseError, 'another commit'): self.run_flow(flow)
        flow.remote_tag += 'a' * 40 + '\trefs/tags/v26.11.01^{}\n'
        self.run_flow(flow)
        self.assertEqual(len(self.uploads(flow)), 1)

    def test_failed_tests_or_build_never_reach_upload(self):
        for stage in ('privacy', 'tests', 'build'):
            with self.subTest(stage=stage):
                flow = SimulatedWorkflow(self.root)
                flow.fail_stage = stage
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))

    def test_bad_bundle_or_archive_never_reaches_upload(self):
        for defect in ('stale metadata', 'version', 'license', 'dSYM', 'DWARF', 'symbols', 'signature',
                       'archive leak', 'private file', 'helper missing', 'symlink', 'personal build path'):
            with self.subTest(defect=defect):
                flow = SimulatedWorkflow(self.root)
                flow.defect = defect
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))

    def test_source_or_remote_changes_during_build_prevent_upload(self):
        for defect in ('changed source', 'changed HEAD', 'remote moved', 'release race'):
            with self.subTest(defect=defect):
                flow = SimulatedWorkflow(self.root)
                flow.defect = defect
                with self.assertRaises(ReleaseError): self.run_flow(flow)
                self.assertFalse(self.uploads(flow))

    def test_upload_failure_retains_local_assets_and_never_deletes_release(self):
        flow = SimulatedWorkflow(self.root)
        flow.upload_failure = True
        with self.assertRaisesRegex(ReleaseError, 'partial draft'): self.run_flow(flow)
        self.assertEqual(len(list((self.root / 'aigauge/release').glob('*.zip'))), 1)
        self.assertFalse(any('delete' in call or '--clobber' in call for call in flow.calls))

    def test_lock_prevents_two_runs_from_sharing_build_outputs(self):
        flow = SimulatedWorkflow(self.root)
        flow.work.mkdir(parents=True)
        with (flow.work / 'run.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ReleaseError, 'already running'): self.run_flow(flow)
        self.assertFalse(flow.calls)

    def test_repository_resolution_rejects_wrong_host_and_embedded_credentials(self):
        for url in ('https://github.com/example/AIGauge.git', 'git@github.com:example/AIGauge.git',
                    'ssh://git@github.com/example/AIGauge.git'):
            self.assertEqual(github_repository(url), 'example/AIGauge')
        for url in ('https://github.com.evil.test/example/AIGauge', 'https://user:secret@github.com/a/b'):
            with self.assertRaises(ReleaseError): github_repository(url)

    def test_network_error_without_http_response_stops(self):
        with self.assertRaises(ReleaseError):
            parse_api_response(subprocess.CompletedProcess([], 1, '', 'timeout'))


if __name__ == '__main__':
    unittest.main()

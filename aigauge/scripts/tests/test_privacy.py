"""Synthetic credentials only; findings never expose their contents."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('privacy', Path(__file__).resolve().parents[1] / 'check-privacy.py')
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class PrivacyTests(unittest.TestCase):
    def test_real_looking_tokens_private_keys_and_machine_paths_are_blocked(self):
        samples = [
            'sk-' + 'a' * 32,
            'gho_' + 'B' * 36,
            'eyJ' + 'a' * 12 + '.' + 'b' * 15 + '.' + 'c' * 15,
            '-----BEGIN ' + 'PRIVATE KEY-----',
            'AKIA' + 'A' * 16,
            'api_key = "' + 'A' * 32 + '"',
            '/Users' + '/someone/build/file.swift',
        ]
        for sample in samples:
            with self.subTest(kind=sample[:3]):
                findings = privacy.inspect('Sources/example.swift', sample.encode())
                self.assertTrue(findings)
                self.assertNotIn(sample, repr(findings))

    def test_private_generated_files_are_blocked_even_with_innocent_contents(self):
        for path in ('.env', '.private/notes.md', 'cache/request.json', 'temp/log.txt',
                     'auth.json', 'Cookies', 'state.sqlite', 'app.log', 'release/build.json'):
            self.assertTrue(privacy.inspect(path, b'not a secret'))

    def test_descriptive_fixtures_and_runtime_lookups_are_allowed(self):
        for data in [b'let apiKey = environment["MISTRAL_API_KEY"]',
                     b'{"api_key":"synthetic-key-for-testing"}',
                     b'Bearer \\(key)', b'dev@vuba.one']:
            self.assertEqual(privacy.inspect('Tests/example.swift', data), [])


if __name__ == '__main__':
    unittest.main()

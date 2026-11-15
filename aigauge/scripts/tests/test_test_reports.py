import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('reports', Path(__file__).resolve().parents[1] / 'verify-test-logs.py')
reports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reports)


class ReportTests(unittest.TestCase):
    def test_xctest_counts_last_suite_while_empty_swift_testing_run_is_separate(self):
        output = ('Executed 2 tests, with 0 failures (0 unexpected)\n'
                  'Executed 15 tests, with 0 failures (0 unexpected)\n'
                  'Test run with 0 tests in 0 suites passed')
        self.assertEqual(reports.passed_count(output), 15)

    def test_empty_failed_or_skipped_suites_fail_release(self):
        for output in ['', 'Executed 0 tests, with 0 failures (0 unexpected)',
                       'Executed 2 tests, with 1 failure (0 unexpected)',
                       "Test Case 'example' skipped (0.1 seconds).\nExecuted 2 tests, with 0 failures (0 unexpected)"]:
            with self.assertRaises(ValueError): reports.passed_count(output)

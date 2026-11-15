"""Validate XCTest's actual output; SwiftPM's native runner may omit xUnit XML."""
from pathlib import Path
import re
import sys


def passed_count(output: str) -> int:
    summaries = re.findall(r'Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\)', output)
    if not summaries:
        raise ValueError('No XCTest result summary found.')
    count, failures, unexpected = map(int, summaries[-1])
    if not count or failures or unexpected or re.search(r'\bskipped \(', output):
        raise ValueError('Tests failed, were skipped, or matched no tests.')
    return count


def main():
    folder = Path(sys.argv[1])
    count = 0
    for package in ('claude-gauge', 'codex-gauge', 'mistral-gauge', 'aigauge'):
        try:
            count += passed_count((folder / f'{package}.log').read_text())
        except (ValueError, OSError) as error:
            sys.exit(f'{package}: {error}')
    print(f'All four unit suites passed: {count} tests; no desktop automation.')


if __name__ == '__main__':
    main()

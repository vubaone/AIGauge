#!/usr/bin/env python3
"""Check publishable Git files without displaying any matched secret values."""
from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys

SECRET_PATTERNS = {
    'provider or GitHub token': re.compile(r'\b(?:sk-(?:ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'JWT': re.compile(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'),
    'private key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'literal credential': re.compile(r'''(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|sessionKey|ory_session_\w*)["']?\s*[:=]\s*["']([A-Za-z0-9_./+=-]{20,})["']'''),
    'personal machine path': re.compile(r'/(?:Users/[A-Za-z0-9._-]+/|Volumes/Workspace/|private/var/folders/)'),
}
PRIVATE_NAMES = {'auth.json', 'settings.json', 'Cookies', 'Cookies-wal', 'Cookies-shm'}
PRIVATE_SUFFIXES = {'.log', '.sqlite', '.db', '.p12', '.pem', '.p8', '.key', '.mobileprovision'}
PRIVATE_DIRECTORIES = {'.private', '.config', '.claude', '.codex', '.aws', '.agents', 'temp', 'cache', '.build', 'release'}


def inspect(relative: str, data: bytes) -> list[tuple[int, str]]:
    path = Path(relative)
    if (path.name in PRIVATE_NAMES or path.suffix in PRIVATE_SUFFIXES
            or (path.name.startswith('.env') and path.name != '.env.example')
            or PRIVATE_DIRECTORIES.intersection(path.parts)):
        return [(0, 'private/generated file')]
    if b'\0' in data[:8192]:
        return []  # Binary assets are reviewed separately by the bundle allowlist.
    findings = []
    for number, line in enumerate(data.decode('utf-8', errors='replace').splitlines(), 1):
        for label, expression in SECRET_PATTERNS.items():
            match = expression.search(line)
            if match:
                if label == 'literal credential' and any(marker in match[1].lower()
                    for marker in ('fixture', 'synthetic', 'example', 'test-only')):
                    continue
                findings.append((number, label))
    return findings


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                            cwd=root, check=True, stdout=subprocess.PIPE)
    names = sorted(set(name.decode() for name in result.stdout.split(b'\0') if name))
    problems = 0
    for name in names:
        path = root / name
        if path.is_symlink():
            findings = [(0, 'source symlink requires manual review')]
        elif not path.exists():
            continue
        else:
            findings = inspect(name, path.read_bytes())
        for line, label in findings:
            print(f'{name}:{line}: {label}; value redacted', file=sys.stderr)
            problems += 1
    if problems:
        print(f'Privacy check blocked: {problems} findings. No secret values were printed.', file=sys.stderr)
        return 1
    print(f'Privacy source check passed: {len(names)} publishable Git files; no credential values or local data detected.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

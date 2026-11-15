#!/usr/bin/env bash
# Sync Swift version constants into SwiftPM and Xcode metadata.
# Usage: ./make_version.sh [--check]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=sync
case "${1:-}" in
    '') ;;
    --check) MODE=check ;;
    -h|--help) echo 'Usage: ./make_version.sh [--check]'; exit 0 ;;
    *) echo 'Usage: ./make_version.sh [--check]' >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then echo 'Too many arguments' >&2; exit 2; fi

python3 - "${SCRIPT_DIR}" "${MODE}" <<'PY'
from pathlib import Path
import plistlib
import re
import sys

root = Path(sys.argv[1])
check = sys.argv[2] == 'check'
package = root / 'aigauge'
source = package / 'Sources/AppVersion.swift'

def require_one(pattern, text, label):
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f'Expected one {label}, found {len(matches)}')
    return matches[0]

def plan():
    constants = require_one(r'enum AppVersion\s*\{([^}]+)\}', source.read_text(), 'AppVersion declaration')
    version = require_one(r'^\s*static let clientVersionString = "([0-9]+\.[0-9]+\.[0-9]+)"\s*$', constants, 'version string')
    build = require_one(r'^\s*static let clientVersionInt = ([1-9][0-9]*)\s*$', constants, 'build number')
    changes = {}

    plist_path = package / 'Info.plist'
    plist = plist_path.read_text()
    for key, value in [('CFBundleShortVersionString', version), ('CFBundleVersion', build)]:
        pattern = rf'(<key>{key}</key>\s*<string>)[^<]*(</string>)'
        plist, count = re.subn(pattern, lambda m: m[1] + value + m[2], plist)
        if count != 1:
            raise ValueError(f'Expected one string for {key} in Info.plist')
    plistlib.loads(plist.encode())
    changes[plist_path] = plist

    # project.yml is tracked; the generated .xcodeproj is intentionally not.
    spec_path = root / 'project.yml'
    spec = spec_path.read_text()
    block = re.search(r'(?ms)^  AIGauge:\n.*?(?=^  \S|\Z)', spec)
    if block is None:
        raise ValueError('AIGauge app target not found in project.yml')
    settings = block[0]
    for key, value in [('CURRENT_PROJECT_VERSION', build), ('MARKETING_VERSION', version)]:
        pattern = rf'(?m)^([ \t]+){key}:.*$'
        if re.search(pattern, settings):
            settings = re.sub(pattern, lambda m: m[1] + f'{key}: "{value}"', settings)
        else:
            settings, count = re.subn(r'(?m)^([ \t]+)GENERATE_INFOPLIST_FILE: NO[ \t]*$',
                lambda m: m[0] + '\n' + m[1] + f'{key}: "{value}"', settings)
            if count != 1:
                raise ValueError('Expected one manual Info.plist setting for the app target')
    changes[spec_path] = spec[:block.start()] + settings + spec[block.end():]

    project_path = root / 'AIGauge.xcodeproj/project.pbxproj'
    if project_path.exists():
        project = project_path.read_text()
        matched = 0
        def update_config(match):
            nonlocal matched
            body = match['body']
            if not re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?com\.aigauge\.app"?;', body):
                return match[0]
            matched += 1
            for key, value in [('CURRENT_PROJECT_VERSION', build), ('MARKETING_VERSION', version)]:
                pattern = rf'(?m)^([ \t]+){key} = [^;]+;'
                if re.search(pattern, body):
                    body = re.sub(pattern, lambda m: m[1] + f'{key} = {value};', body)
                else:
                    body = '\n\t\t\t\t' + f'{key} = {value};' + body
            return match['start'] + body + match['end']
        project = re.sub(r'(?P<start>buildSettings = \{)(?P<body>.*?)(?P<end>\n[ \t]+\};)',
                         update_config, project, flags=re.DOTALL)
        if matched == 0:
            raise ValueError('No AIGauge app build configurations found in project.pbxproj')
        changes[project_path] = project
    return version, build, changes

try:
    version, build, changes = plan()
    # Validate all inputs before changing any file. Checking never writes.
    stale = [path for path, content in changes.items() if path.read_text() != content]
    if check and stale:
        for path in stale:
            print(f'Out of sync: {path.relative_to(root)}', file=sys.stderr)
        sys.exit('Run ./make_version.sh and commit the synced metadata.')
    if not check:
        for path in stale:
            path.write_text(changes[path])
            print(f'Updated {path.relative_to(root)}')
    print(f'AIGauge {version} ({build}) — metadata in sync')
except (OSError, ValueError) as error:
    sys.exit(f'Version sync failed: {error}')
PY

#!/usr/bin/env bash
# One entry point for local packaging, GitHub release drafts, and publishing.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
exec python3 "${REPO_ROOT}/aigauge/scripts/release.py" "$@"

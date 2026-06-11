#!/bin/bash
#
# Wipe everything AIGauge has stored on this Mac so the next launch is a
# true first-run. Does NOT touch your actual Claude / Codex login sources
# (~/.codex/auth.json, Claude Desktop cookies, browser cookies, Keychain).
#
# Usage:
#   ./reset.sh           # do it (prints each removal)
#   ./reset.sh --dry-run # show what would be deleted, change nothing

set -e

DRY=0
[[ "$1" == "--dry-run" || "$1" == "-n" ]] && DRY=1

say() { echo " $*"; }
nuke_file() {
    local p="$1"
    if [ -e "$p" ] || [ -L "$p" ]; then
        if (( DRY )); then
            say "would remove: $p"
        else
            rm -rf "$p"
            say "removed     : $p"
        fi
    fi
}

echo "==> Stopping any running AIGauge"
if /usr/bin/pgrep -x AIGauge >/dev/null; then
    if (( DRY )); then
        say "would kill: AIGauge ($(/usr/bin/pgrep -x AIGauge | tr '\n' ' '))"
    else
        /usr/bin/pkill -x AIGauge || true
        sleep 1
        say "killed AIGauge"
    fi
else
    say "no AIGauge running"
fi

echo ""
echo "==> Clearing AIGauge preferences (com.aigauge.app)"
if /usr/bin/defaults read com.aigauge.app >/dev/null 2>&1; then
    if (( DRY )); then
        say "would defaults delete com.aigauge.app"
    else
        /usr/bin/defaults delete com.aigauge.app 2>/dev/null || true
        say "defaults deleted"
    fi
else
    say "no defaults present"
fi
nuke_file "$HOME/Library/Preferences/com.aigauge.app.plist"
nuke_file "$HOME/Library/Saved Application State/com.aigauge.app.savedState"
nuke_file "$HOME/Library/Caches/com.aigauge.app"
nuke_file "$HOME/Library/HTTPStorages/com.aigauge.app"

echo ""
echo "==> Clearing ClaudeGauge CLI state (logs + saved settings)"
nuke_file "$HOME/.config/claude-gauge"

echo ""
echo "==> Clearing CodexGauge CLI state (logs + saved settings)"
nuke_file "$HOME/.config/codex-gauge"

echo ""
echo "==> Preserved (NOT touched — these are your real logins):"
say "~/.codex/auth.json                                 (Codex OAuth)"
say "~/Library/HTTPStorages/com.openai.codex*           (Codex app cookies)"
say "~/Library/Application Support/Claude/Cookies       (Claude Desktop)"
say "Keychain entries (Codex Auth, Chrome/Brave Safe Storage, …)"
say "Browser cookies (Chrome / Brave / …)"

echo ""
if (( DRY )); then
    echo "Dry-run complete — nothing was changed. Re-run without --dry-run to apply."
else
    echo "Reset complete. Next launch will be a clean first-run."
    echo "  open ./release/AIGauge.app"
fi

# AIGauge

Two small Swift CLIs that report rolling-window usage and trigger quota refresh for **Claude** and **Codex (ChatGPT Plus)** subscriptions. Designed to be driven by `openclaw` (or any cron / launchd / shell scheduler) — pure stdout for results, stderr for logs, exit codes for branching.

| Subproject | Reads | Triggers | Source of truth |
|---|---|---|---|
| [`claude-gauge/`](claude-gauge/) — `ClaudeGauge` | claude.ai 5h / 7d / Opus windows | sends a 2-token prompt in a temporary conversation | sessionKey cookie from Claude Desktop / Brave / Chrome |
| [`codex-gauge/`](codex-gauge/) — `CodexGauge` | `/wham/usage` primary (5h) + secondary (7d) windows + credits | sends a `gpt-5.2` SSE completion to `/codex/responses` | `~/.codex/auth.json` (OAuth JWT, no cookies) |
| [`aigauge/`](aigauge/) — `AIGauge` | menu-bar GUI wrapper around the two CLIs | — | shells out to ClaudeGauge / CodexGauge |

Both CLIs expose the same two commands: `usage` and `refresh`.

---

## Build

macOS 13+ with Swift 5.9+ (Xcode CLT or swift.org toolchain).

```bash
# Claude
cd claude-gauge && swift build -c release
# binary at: claude-gauge/.build/release/ClaudeGauge

# Codex
cd codex-gauge  && swift build -c release
# binary at: codex/.build/release/CodexGauge
```

Or use the included `run.sh` in each folder for a build + smoke test.

---

## Commands (identical surface on both CLIs)

| Command | Behaviour |
|---|---|
| `usage` | Fetch current rolling-window usage. Prints human-readable by default, or JSON with `--json`. |
| `refresh` | Send a minimal private prompt to start/extend the 5-hour quota window. Costs ~2 tokens (Claude) or ~24 tokens (Codex). |
| `help` / `-h` | Print usage. |

### Common flags

| Flag | Effect |
|---|---|
| `--json` | Emit a single line of JSON on stdout (logs stay on stderr). Use for scripting. |
| `--verbose` / `-v` | Mirror internal logs to stderr (off by default). |
| `--help` / `-h` | Print help. |

### Exit codes (shared)

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Bad usage / unknown argument |
| `3` | Missing credentials |
| `4` | API or HTTP error |

---

## ClaudeGauge

```text
ClaudeGauge <usage|refresh|help> [flags]

Flags:
  --org-id <id>           Override organization ID
  --session-key <key>     Override session key (sessionKey cookie value)
  --auto-detect           Force cookie extraction from Claude Desktop / Brave / Chrome
  --json / --verbose / -v / --help
```

**Credential resolution** (first match wins):

1. `--org-id` + `--session-key` flags
2. `--auto-detect` (cookie extraction)
3. `~/.config/claude-gauge/settings.json` (created by the original GUI app, if present)
4. Fallback to cookie extraction

**Sample output:**

```bash
$ ClaudeGauge usage
5-hour :   8.0%  (resets in 4 hr 44 min)
7-day  :   0.0%  (resets in 54 hr 34 min)
Opus 7d: n/a

$ ClaudeGauge usage --json
{"fiveHour":{"resetsAt":"...","timeUntilReset":"4 hr 44 min","utilization":8},
 "sevenDay":{"resetsAt":"...","timeUntilReset":"54 hr 34 min","utilization":0},
 "sevenDayOpus":null,"sevenDayOauthApps":null}

$ ClaudeGauge refresh --json
{"resetsAt":1778420000,"resetsAtISO":"2026-05-16T...","status":"ok"}
```

---

## CodexGauge

```text
CodexGauge <usage|refresh|help> [flags]

Flags:
  --access-token <v>      Bearer JWT (overrides auto-resolution)
  --api-key <v>           OPENAI_API_KEY (for api.openai.com mode)
  --account-id <v>        chatgpt-account-id header value
  --endpoint <path>       Override usage/refresh path (e.g. /backend-api/...)
  --raw                   Include raw API body in output
  --json / --verbose / -v / --help
```

**Credential resolution** (first match wins):

1. `--access-token` / `--api-key` flags
2. `~/.codex/auth.json` (written by the npm `@openai/codex` CLI when you `codex login`)
3. macOS Keychain `svce="Codex Auth"` (written by the Codex desktop app)
4. `OPENAI_API_KEY` environment variable

**Sample output:**

```bash
$ CodexGauge usage
[~/.codex/auth.json] HTTP 200
Plan      : plus  (you@example.com)
Primary  (5h):   1.0%  (resets in 5 hr 0 min)
Secondary(7d):  70.0%  (resets in 61 hr 35 min)

$ CodexGauge usage --json
{"accountId":"...","credits":{"balance":"0","hasCredits":false,"unlimited":false},
 "email":"you@example.com","httpStatus":200,"planType":"plus",
 "rateLimit":{"allowed":true,"limitReached":false,
   "primaryWindow":{"limitWindowSeconds":18000,"resetAfterSeconds":18000,
     "resetAt":1778920915,"resetLabel":"5 hr 0 min","usedPercent":1,"window":"5h"},
   "secondaryWindow":{"limitWindowSeconds":604800,"resetAfterSeconds":223748,
     "resetAt":1779126663,"resetLabel":"62 hr 9 min","usedPercent":70,"window":"7d"}},
 "source":"~/.codex/auth.json","userId":"user-..."}

$ CodexGauge refresh --json
{"httpStatus":200,"responseBytes":2731,"status":"ok"}
```

**Endpoints in use:**

- Usage: `GET https://chatgpt.com/backend-api/wham/usage`
- Refresh: `POST https://chatgpt.com/backend-api/codex/responses` (streaming SSE, single `gpt-5.2` completion ≈ 24 tokens)

**If `refresh` starts returning `400 ... model is not supported`:** OpenAI rotated the default Codex model. Discover the new allowed slug and update the hardcoded value in [`codex/Sources/CodexAPIClient.swift`](codex/Sources/CodexAPIClient.swift):

```bash
CodexGauge usage --endpoint "/backend-api/codex/models?client_version=0.30.0" --raw --json \
  | jq -r '.raw | fromjson | .models[].slug'
```

---

## Running from openclaw (or any scheduler)

Both CLIs are designed for unattended invocation: stdout carries the result, stderr carries log noise (silent by default), and exit codes signal failure modes. A scheduler that captures stdout, parses JSON, and branches on exit code can drive both tools without further glue.

### Pattern 1 — poll usage every minute

```bash
ClaudeGauge usage --json   # parse .fiveHour.utilization
CodexGauge  usage --json   # parse .rateLimit.primaryWindow.usedPercent
```

If exit code is `0`, parse JSON. If `3`, credentials need re-bootstrapping (re-login in app/browser, then run `codex login` for the Codex side). If `4`, API is temporarily unavailable — retry later.

### Pattern 2 — keep the 5-hour window warm

Schedule `refresh` to run a few minutes before you expect to start a session:

```bash
# Cron-style: every weekday at 08:55, prime both windows for a 09:00 work session
55 8 * * 1-5  /path/to/ClaudeGauge refresh --json >> ~/claude-refresh.log 2>&1
55 8 * * 1-5  /path/to/CodexGauge  refresh --json >> ~/codex-refresh.log  2>&1
```

Cost per refresh: ~2 tokens (Claude), ~24 tokens (Codex). Both deduct from your weekly budget — don't loop more than once per ~5 hours or you waste quota.

### Pattern 3 — conditional refresh (only when window is idle)

```bash
# Refresh only if Claude's 5h window is over 80% reset (i.e. mostly idle)
if [ "$(ClaudeGauge usage --json | jq '.fiveHour.utilization < 5')" = "true" ]; then
  ClaudeGauge refresh --json
fi
```

### openclaw-specific tips

- Pin absolute paths to the built binaries; don't rely on `cwd`.
- Pass `--json` so openclaw can capture structured results.
- Don't pass `--verbose` in scheduled runs — logs always go to `~/.config/{claude,codex}-gauge/logs/*.log` regardless. Use `-v` only for ad-hoc debugging.
- Treat exit code `3` as "wake the human" (credentials expired); `4` as transient.

---

---

## AIGauge (menu-bar GUI)

A native macOS menu-bar app that wraps both CLIs. Stays in the tray, opens a tabbed settings window, runs `usage` / `refresh` on demand and on a timer.

### Build

```bash
cd aigauge && ./build.sh
```

Produces in `aigauge/release/`:

| File | What it is |
|---|---|
| **`AIGauge.app`** | Drag-to-`/Applications` macOS app bundle. Embeds both CLIs in `Contents/Resources/`. |
| `AIGauge.app.zip` | Same as above, zipped for distribution / sharing. |
| `ClaudeGauge`, `CodexGauge` | Standalone CLI binaries (only needed if you want to call them outside the app). |

Then to produce a styled drag-to-Applications installer DMG:

```bash
./make-dmg.sh    # writes release/AIGauge.dmg
open release/AIGauge.dmg
```

The DMG opens to a Finder window with `AIGauge.app` on the left and an `Applications` shortcut on the right — the standard macOS install flow: drag the app onto the folder.

Or skip the DMG and install directly:

```bash
open aigauge/release        # drag AIGauge.app to /Applications, then launch it
# — or —
open aigauge/release/AIGauge.app
```

The tray icon `gauge` appears with the configured backend's primary-window percent (e.g. `Claude 8%`).

### What's in the UI

- **General tab** — pick which backend's percent shows on the tray (Claude / Codex / none), auto-refresh interval (seconds), "close hides to tray" toggle, "launch at login" toggle, optional manual paths to the CLI binaries.
- **Claude tab** — progress bars for 5h / 7d / Opus 7d windows, `Check usage` button, `Refresh window (~2 tokens)` button.
- **Codex tab** — progress bars for Primary (5h) and Secondary (7d) windows, `Check usage` button, `Refresh window (~24 tokens)` button.

Tray menu also exposes `Refresh Usage Now`, the two `refresh` actions (with a confirmation dialog because they spend tokens), and `Quit`.

### Binary discovery

AIGauge looks for `ClaudeGauge` / `CodexGauge` in this order:

1. Path entered in **General → CLI paths** (if set)
2. **`AIGauge.app/Contents/Resources/`** — the embedded copies when running as a bundled app
3. Same directory as the running `AIGauge` binary (flat-folder layout)
4. Sibling project layout: `../claude-gauge/.build/release/ClaudeGauge`, `../codex/.build/release/CodexGauge` (dev `swift run`)
5. `$PATH`

So:

- **Distributed `.app`:** self-contained — the CLIs travel with it.
- **Dev `swift run AIGauge`** from `aigauge/`: finds sibling builds automatically.

### Caveats

- "Launch at login" toggle is wired but currently best-effort; it depends on macOS recognising the `.app` location. Drag the app into `/Applications` first, then toggle.
- The GUI shells out to the CLIs every `autoRefreshSeconds` (default 60). Don't set it below 30 to avoid hammering claude.ai / chatgpt.com.
- The `.app` is ad-hoc codesigned (no Developer ID). If you copy `AIGauge.app.zip` from another machine, macOS may quarantine it — first launch via right-click → Open, or strip the quarantine flag:
  ```bash
  xattr -dr com.apple.quarantine /Applications/AIGauge.app
  ```
- On Apple Silicon vs Intel: `swift build` defaults to your native architecture. For a universal binary that runs on both, edit `build.sh` to add `--arch arm64 --arch x86_64` to each `swift build` call (requires full Xcode, not just Command Line Tools).

---

## Logs

Both CLIs always write a per-invocation log file:

```
~/.config/claude-gauge/logs/claudegauge-<ISO timestamp>.log
~/.config/codex-gauge/logs/codexgauge-<ISO timestamp>.log
```

Set up a periodic cleanup if you call them frequently (one file per invocation can pile up).

---

## Security notes

- **Read-only auth sources.** Both CLIs only *read* cookie databases (Claude) or auth JSON / Keychain (Codex). They never write back.
- **Local only.** No telemetry. Only HTTPS calls to `claude.ai` and `chatgpt.com`.
- **Tokens live on disk / in Keychain.** Anything that can read `~/.codex/auth.json` or your browser cookies can impersonate you on those services — standard threat model for any session-based tool.

---

## Project layout

```
AIGauge/
├── README.md              # this file
├── claude-gauge/                # ClaudeGauge CLI (Swift package)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── main.swift
│   │   ├── CLI.swift
│   │   ├── ClaudeAPIClient.swift
│   │   ├── CredentialExtractor.swift
│   │   ├── Logger.swift
│   │   └── Models.swift
│   └── run.sh
├── codex-gauge/           # CodexGauge CLI (Swift package)
│   ├── Package.swift
│   ├── Sources/
│   │   ├── main.swift
│   │   ├── CLI.swift
│   │   ├── CodexAPIClient.swift
│   │   ├── CredentialExtractor.swift
│   │   ├── Logger.swift
│   │   └── Models.swift
│   └── run.sh
└── aigauge/              # menu-bar GUI wrapping both CLIs
    ├── Package.swift
    ├── Info.plist                      # .app bundle metadata (LSUIElement)
    ├── Sources/
    │   ├── main.swift
    │   ├── AppDelegate.swift
    │   ├── MenuBarController.swift
    │   ├── SettingsView.swift          # SwiftUI tabs
    │   ├── AppSettings.swift           # UserDefaults wrapper + Color hex helpers
    │   ├── UsageStore.swift            # ObservableObject + refresh timer
    │   ├── BackendRunner.swift         # subprocess driver
    │   └── BackendModels.swift
    ├── build.sh                        # builds all three, assembles .app, signs, zips
    ├── make-dmg.sh                     # styled drag-to-Applications installer DMG
    └── release/                        # produced by build.sh / make-dmg.sh
        ├── AIGauge.app/               # drag this to /Applications
        │   └── Contents/
        │       ├── Info.plist
        │       ├── MacOS/AIGauge
        │       └── Resources/{ClaudeGauge,CodexGauge}
        ├── AIGauge.app.zip            # zipped for distribution
        ├── AIGauge.dmg                # installer disk image (run make-dmg.sh)
        ├── ClaudeGauge                 # standalone CLI
        └── CodexGauge                  # standalone CLI
```

`claude-gauge/` was forked from [decryptu/claude-gauge](https://github.com/decryptu/claude-gauge) (MIT) and stripped down to its CLI core; `codex/` is built from scratch following the same conventions.

---

## About

Built by VUBA (dev@vuba.one) — [vuba.one](https://vuba.one).

Released under MIT. No telemetry, no third-party services beyond the official Claude and ChatGPT/Codex APIs.

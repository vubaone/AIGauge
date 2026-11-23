<p align="center">
  <img src="resources/icon.png" width="160" alt="AIGauge">
</p>

<h1 align="center">AIGauge</h1>

<p align="center">
  <em>How much of my Claude, Codex, and Mistral did I burn?</em><br>
  A tiny menu-bar gauge + three CLIs for the over-curious.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS_13+-lightgrey" alt="macOS 13+">
  <img src="https://img.shields.io/badge/swift-5.9+-orange" alt="Swift 5.9+">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
</p>

## Why

AIGauge puts Claude, Codex, and Mistral usage in the macOS menu bar so you can check your limits without opening each provider's dashboard.

Bonus trick: Claude has a `refresh` action that fires a tiny "ping" to *start* its 5-hour window early. Codex exposes the same action only when its live usage response reports the legacy 5-hour mechanism; with the newer weekly limit and banked full resets, AIGauge shows the reset count and expiration dates instead.

## Usage

### GUI

Click the tray gauge → menu shows each enabled provider's current usage. When Claude or Codex has available limit resets, it also shows how many remain and when they expire. Resets are redeemed in the provider's own app.

In **Settings → Tray** you choose:

- which providers' percentages show on the tray (Claude / Codex / Mistral / combinations / None) — colored numbers so you can tell them apart at a glance,
- which providers get a section in the dropdown menu,

Auto-refresh interval and launch-at-login are in **Settings → General**.

**OpenAI API balance:** in the Codex section of the dropdown, click
**OpenAI API balance · Connect…** and sign in to OpenAI Platform. Select the API
organization you want to check. AIGauge reads the balance when you open the
dropdown, with at least 10 seconds between checks.

**Mistral:** enable it in **Settings → Mistral** and click **Connect Mistral**.
**API key (Keychain)** remains the default: it reads Mistral Vibe's API key from
macOS Keychain and calls Mistral's public billing API, without accessing browser
cookies. You can also use **Use an API key → Save and connect**; the key is
verified before it is saved in AIGauge's own Keychain entry. Background checks
never show Keychain prompts, and API-key errors never trigger browser access.

For the closest match to the website, explicitly select
**Browser session (dashboard)** with an existing Edge/Chrome/Brave login. It calls the dashboard's
authenticated `billing.budget` tRPC JSON endpoint, not the `/subscription` HTML
page, with no HTML fallback. This internal endpoint may change. API-key mode
remains a suitable alternative when you prefer not to grant browser access.

A valid shared Vibe budget is shown alone as **Vibe & Studio**, with used / total /
remaining amounts and reset time; any legacy API budget is suppressed. API-key
mode can fall back to **API/Studio** for API-only accounts. Missing or zero-size
budgets are never synthesized, and budgets are never added together. The tray
uses the same selected budget. Enabling Mistral adds it to your tray/menu
selection; the Tray tab controls visibility and order.

Browser mode may need cookie-file access and the browser's Safe Storage Keychain
permission. **Grant cookie access…** opens the macOS permission page and shows a
draggable AIGauge app icon; the user must approve file access in System Settings.
Live checks covered Keychain/API usage and the dashboard tRPC/cookie path through
an existing Edge profile without new prompts or pasted cookies. This does not
mean every first-run or permission UI flow has been live-tested.

### CLI

All three CLIs support machine-readable usage. Claude and Codex also expose quota-refresh actions:

```bash
ClaudeGauge usage           # Usage windows and available limit resets
ClaudeGauge usage --json    # pipe me into jq
ClaudeGauge refresh         # ~2 tokens — primes the 5h window

CodexGauge  usage           # Plan, current window, and banked reset expirations
CodexGauge  refresh         # Legacy 5h only; refuses otherwise without spending

MistralGauge usage --json   # Mistral API key from Keychain
MistralGauge usage --allow-keychain-prompt --json  # First connection
# Explicit dashboard mode (requires browser cookie access):
MistralGauge usage --auth browser --source edge --profile "Profile 1" --json
```

Exit codes: `0` ok · `2` bad args · `3` missing credentials · `4` API error.

Drop them into `cron` / `launchd` / your fav scheduler. See [FULL_README.md](FULL_README.md) for the openclaw patterns and every flag.

## First run — what those popups are

macOS may show **Keychain access prompts** when AIGauge first reads your credentials. Here are common Claude/Codex examples; Mistral's separate permissions are described above:

| Prompt | What it really means | Safe to allow? |
|---|---|---|
| `"ClaudeGauge" wants to use "Claude Safe Storage" in your keychain` | Claude Desktop encrypts its session cookie with a key stored here. We read the key once to decrypt the cookie, then call claude.ai. | **Yes — click "Always Allow".** |
| `"CodexGauge" wants to access key "Codex Auth"` | Only shown if `~/.codex/auth.json` is missing. The Codex desktop app stored your ChatGPT OAuth token in the keychain — we read it to call `/wham/usage`. | **Yes — click "Always Allow".** |
| `"…" wants to use "Chrome/Brave Safe Storage"` | Same as the Claude one, but only fires if you're logged into Claude in a browser instead of the desktop app. | **Yes — "Always Allow".** |
| macOS asks for **Full Disk Access** | Only triggers if reading browser cookie DBs. Toggle on in System Settings → Privacy → Full Disk Access. | **Yes** — or skip it and stay logged into Claude Desktop instead. |

> [!IMPORTANT]
> **Click the "Always Allow" button**, not just "Allow". "Allow" is one-shot — you'd see the same dialog every 60 seconds when the GUI refreshes. "Always Allow" persists the permission.

For Claude, after the first successful extraction, credentials are cached in `~/.config/claude-gauge/settings.json` so even *that* one prompt only happens once per install (or until you run `reset.sh`). Subsequent Claude refreshes use that cache. Mistral does not save browser cookies in a credential cache; its Keychain and browser-file permissions still apply.

What AIGauge actually does with those credentials:

- **Usage checks are read-only.** Existing credentials are read without changing provider accounts. Mistral's explicit **Save and connect** action saves your provided key in AIGauge's own Keychain entry; it never changes Vibe's credentials.
- **Mistral:** **API key (Keychain)** sends an API key only to `https://api.mistral.ai/v1/billing/budget`. Explicit **Browser session (dashboard)** sends cookies only to `https://admin.mistral.ai/api/local-trpc/billing.budget`. Both use transient HTTP sessions and block redirects. No Sentry/analytics headers are copied from the browser; no cookies are hardcoded or printed. See [MistralGauge](mistral-gauge/README.md).
- **Provider endpoints only.** Requests go to `claude.ai`, `chatgpt.com`, `api.mistral.ai`, and (browser alternative) `admin.mistral.ai`. Codex API-key mode uses `api.openai.com`. The optional API balance connects to `platform.openai.com` in AIGauge's web view.
- **No telemetry, no analytics, no phone-home.** The full source is in this repo; `grep` it.
- **Local storage:** Claude/Codex logs and settings live in `~/.config/claude-gauge/` and `~/.config/codex-gauge/`. A manually saved Mistral key lives in Keychain under service `com.aigauge.mistral`. [`aigauge/reset.sh`](aigauge/reset.sh) clears preferences and CLI files; it preserves Keychain entries.

If you ever want to start over and watch the first-run flow again:

```bash
cd aigauge && ./reset.sh   # wipes our cache, leaves your real logins alone
open release/AIGauge.app
```

## Build

```bash
cd aigauge
./build.sh        # builds three CLIs + GUI, assembles AIGauge.app, ad-hoc signs
./make-dmg.sh     # styled drag-to-Applications installer DMG
open release/AIGauge.dmg
```

Requires **macOS 13+** and Swift 5.9 (Xcode CLT or swift.org toolchain). Everything else is built-in: no Homebrew, no npm, no `create-dmg`.

Want just one CLI? Each of `claude-gauge`, `codex-gauge`, and `mistral-gauge` has a `run.sh` build helper.

## Release

After reviewing, committing and pushing the chosen version, run:

```sh
./release.sh --publish --notes docs/releases/26.11.01.md
```

The SmallGit-style pipeline tests, builds, checks privacy, packages a versioned
ZIP/checksum/manifest, verifies uploaded GitHub assets, then publishes. Use
`./release.sh` for a draft or `./release.sh --local` to check packaging locally.
No manual asset upload is needed. See [Release workflow](docs/releasing.md) and
[Privacy](PRIVACY.md). GitHub uploads require Developer ID signing, Apple
notarization, a stapled ticket and Gatekeeper verification. Set up the signing
certificate and `AIGauge` notarytool profile as described in the release guide.
Local-only builds may use ad-hoc signing.

## License & credits

MIT.

- `claude/` is a CLI-only fork of [Decryptu/claude-gauge](https://github.com/Decryptu/claude-gauge) (MIT). All the cookie-decrypt cleverness is theirs.
- `codex/` was reverse-engineered fresh against `/backend-api/wham/usage` and the public Codex CLI source.
- `mistral-gauge/` reads Mistral's monthly shared Vibe & Studio budget (API/Studio fallback for API-only accounts), using a billing API key by default or an explicit dashboard browser session.
- `aigauge/` ties them together in a tiny Swift/SwiftUI menu-bar wrapper.

## About

Built by VUBA (dev@vuba.one) — [vuba.one](https://vuba.one). No telemetry; requests go to provider endpoints only.

Full docs · openclaw automation patterns · endpoint catalog · file layout → [FULL_README.md](FULL_README.md)

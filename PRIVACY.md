# AIGauge privacy

AIGauge has no telemetry, advertising, analytics, or usage-data upload service.
Usage checks contact the provider selected for the check. Opening links or
login sources happens only through the corresponding user action.

| Provider | Credential read locally | Usage destination |
| --- | --- | --- |
| Claude | Existing app/browser cookies or configured account credentials | `claude.ai` |
| Codex | `~/.codex/auth.json` or Codex Auth in Keychain | `chatgpt.com` (API-key mode: `api.openai.com`) |
| OpenAI API balance | OpenAI Platform sign-in in AIGauge's WebKit session | `platform.openai.com` |
| Mistral, default | API key from environment, Vibe Keychain, or AIGauge Keychain | `api.mistral.ai/v1/billing/budget` |
| Mistral, browser alternative | Cookies for the selected Mistral browser profile | `admin.mistral.ai/subscription` |

## Mistral

Mistral uses its public billing API by default. It reads an existing API key
without modifying Vibe's stored credential. **Save and connect** verifies the
provided key before saving it under Keychain service `com.aigauge.mistral`,
account `api-key`. The key goes to the helper over stdin, not command arguments,
and is never saved in UserDefaults or a plaintext app cache.

The browser method is explicit. Only unexpired cookies applicable to Mistral
Admin are read; the browser database is not modified. Its Safe Storage key and
macOS file access are separate permissions. The default API-key connection does
not need access to browser cookie databases.

Both Mistral HTTP paths refuse redirects, use transient sessions without cookie
storage/response caches, and never send model prompts. Errors do not expose raw
response bodies or secrets. CLI JSON includes quota amounts, currency, reset
time and credential-source labels, which should be treated as account data.

## Local state and explicit actions

The OpenAI API balance uses the website session stored by WebKit for AIGauge.
Once connected, opening the dropdown loads the Billing Overview and reads the
displayed balance. AIGauge keeps the amount in memory. Sign out in the billing
window to end the Platform session.

GUI preferences live in the app's macOS preferences. ClaudeGauge and CodexGauge
keep settings/logs under their respective `~/.config/*-gauge/` directories; those
files may contain account information and credentials. They are not release
assets. Mistral does not create credential/log files of its own. A manually
saved Mistral key remains in Keychain when resetting GUI preferences.

Claude/Codex quota-refresh actions can send a small prompt when explicitly
requested or when a user-enabled schedule runs. Ordinary usage checks only
read usage. Mistral has no token-spending refresh action.

Source publication and release packaging exclude local settings, browser data,
keys, logs, caches and build intermediates. The release workflow checks a fixed
bundle allowlist and uploads only the app ZIP, checksum and build manifest.
Release checks and their limits are described in [releasing.md](docs/releasing.md).

Public release notarization sends the verified app ZIP to Apple's notary service.
Apple credentials remain in a named Keychain profile. Notary logs stay local;
the public manifest includes acceptance/submission/ticket verification metadata.
Developer ID signing includes the publisher's public certificate identity in
the signature. No user account data, model prompts, cookies, API keys, or local
workspace files are included in the notarization submission.

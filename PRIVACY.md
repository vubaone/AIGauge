# AIGauge privacy

AIGauge has no telemetry, advertising, analytics, or usage-data upload service.
Usage checks contact the provider selected for the check. Opening links or
login sources happens only through the corresponding user action.

| Provider | Credential read locally | Usage destination |
| --- | --- | --- |
| Claude | Existing app/browser cookies or configured account credentials | `claude.ai` |
| Codex | `~/.codex/auth.json` or Codex Auth in Keychain | `chatgpt.com` (API-key mode: `api.openai.com`) |
| OpenAI API balance | OpenAI Platform sign-in in AIGauge's WebKit session | `platform.openai.com` |
| Mistral, API key (Keychain), default | API key from explicit input, environment, Vibe Keychain, or AIGauge Keychain | `https://api.mistral.ai/v1/billing/budget` |
| Mistral, Browser session (dashboard), explicit | Cookies for the selected Mistral browser profile, or explicit manual cookie input | `https://admin.mistral.ai/api/local-trpc/billing.budget` |

## Mistral

**API key (Keychain)** remains the default and uses Mistral's public billing API.
It reads an existing API key without modifying Vibe's stored credential.
**Save and connect** verifies the provided key before saving it under Keychain
service `com.aigauge.mistral`, account `api-key`. The key goes to the helper over
stdin, not command arguments, and is never saved in UserDefaults or a plaintext
app cache. API-key mode never accesses browser cookies or automatically switches
to a browser session, including after an authentication or permission error.
Background checks never show Keychain prompts; an explicit first connection may
still require approval.

**Browser session (dashboard)** is explicitly selected and best matches the
website's displayed budget. It reads unexpired cookies applicable to Mistral
Admin from the selected browser profile without modifying the browser database
or saving cookies. Manual cookie input is optional; no cookies are hardcoded.
The browser's Safe Storage Keychain permission and macOS cookie-file access are
separate permissions and still apply even if an existing installation needs no
new prompts. **Grant cookie access…** opens the relevant settings; only the user
can approve access. The default API-key connection needs neither browser-cookie
access nor browser Safe Storage permission.

Browser mode makes an authenticated GET to the internal `billing.budget` tRPC
endpoint listed above, with the `input` query parameter set to
`{"json":null,"meta":{"values":["undefined"],"v":1}}`, and reads only
`result.data.json.vibe_budget`. It does not parse `/subscription` HTML or fall
back to HTML. This internal endpoint may change; the public API remains a
suitable API-key alternative.

Both Mistral HTTP paths refuse redirects, use transient sessions without cookie
storage/response caches, and never send model prompts. Browser requests do not
copy Sentry or analytics headers. Errors do not expose raw response bodies or
secrets. CLI JSON includes quota amounts, currency, reset time and
credential-source labels, which should be treated as account data.

A valid shared Vibe budget (`initial_budget > 0`) is shown alone as **Vibe & Studio**;
a legacy API budget returned alongside it is suppressed, never added to it.
Native API-key mode can fall back to **API/Studio** for API-only accounts; browser
mode uses only the shared budget. Missing or zero-size budgets are not synthesized.
CLI JSON retains the optional `api` / `vibe` keys, with normalized `api` omitted
when a valid `vibe` budget exists.

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

# MistralGauge

Swift CLI for Mistral's included monthly **API/Studio** and **Vibe Code**
allowances. It follows CodexGauge's CLI/client/extractor/models structure and
exit codes. The default connection reads an API key from macOS Keychain and
GETs `https://api.mistral.ai/v1/billing/budget`, as the official Vibe CLI does.

```sh
swift build -c release --build-system native
.build/release/MistralGauge usage --json
# First connection, if Keychain needs approval:
.build/release/MistralGauge usage --allow-keychain-prompt --json
```

In AIGauge, enable **Settings → Mistral**, leave **Keychain (recommended)**
selected, and click **Connect Mistral**. This method does not open browser cookie
databases or require Full Disk Access.

API-key resolution: explicit stdin/file, `MISTRAL_API_KEY`, AIGauge's own
Keychain entry (`com.aigauge.mistral` / `api-key`), then Vibe's Keychain entries
(`ai.mistral.vibe`, legacy `vibe`; account `MISTRAL_API_KEY`). An unreadable
Keychain produces a connection error rather than silently switching to cookies
or another account. Background checks never show Keychain prompts.

If you have no Vibe API key stored, use **Use an API key → Save and connect**.
The helper receives it over stdin, verifies quota access, and only then stores
it in AIGauge's own Keychain entry. No key is put in process arguments,
UserDefaults, logs, or a plaintext credential cache. Vibe's original entry is
never modified. For CLI use, supply `--api-key-file <path>` or
`--api-key-stdin`; `connect` with one of these inputs verifies and saves it.
The ordinary `usage` command never saves credentials.

The billing endpoint requires `see_org_inference_usage`. HTTP 403 means the key
cannot read organization usage and does not trigger a browser fallback.
OIDC/SSO marker credentials are rejected with instructions to provide an API key;
this implementation does not refresh Vibe SSO sessions.

## Explicit browser alternative

Choose **Browser session (advanced)** to use an existing browser login. Edge is
the default for this method; Chrome and Brave are also supported.

```sh
.build/release/MistralGauge usage --auth browser --source edge --json
.build/release/MistralGauge usage --source edge --profile "Profile 1" --json
```

For compatibility, `--source`, `--profile`, or `--cookie-file` selects browser
mode when `--auth` is omitted. API-key and browser options cannot be mixed.
The selected profile must be signed in to Mistral Admin. Find its directory
name in `edge://version` (Profile path), e.g. `Default` or `Profile 1`.
Manual browser credentials use `--cookie-file` or `MISTRAL_COOKIE`, with an
`ory_session_*` cookie; an optional `Cookie:` prefix is accepted.

The browser extractor reads SQLite in read-only mode, supports Chromium v10
AES-CBC and v24 host digests, and filters by domain, path, and expiry. It does not
write browser databases or save cookies. Browser requests only GET
`https://admin.mistral.ai/subscription`. Both connection methods block redirects
and use an ephemeral HTTP session without cookie storage or response caching.
No requests send model prompts or change the provider account.

If macOS denies cookie file access, click **Grant cookie access…**. It opens
Full Disk Access settings and shows the actual running app as a draggable icon.
Drag that app into the settings list, enable it, then quit and reopen AIGauge.
macOS requires the user to approve this setting; the button cannot enable it.
Full Disk Access covers protected files from other apps and is separate from
the browser's Safe Storage Keychain permission. For a standalone CLI, authorize
the terminal app. See [Apple's privacy settings guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac).

## Quota data and output

Both sources preserve the reported percentage, total, currency, and reset, and
derive used/remaining amounts. Missing, malformed, or zero-size allowances are
unavailable; a valid sibling allowance still appears. Usage can exceed 100%;
remaining bottoms out at zero. Prepaid credits and request/token rate limits
are separate from these monthly allowances.

The public API returns `api_budget` / `vibe_budget` objects. The browser parser
reads their counterparts in structured Next.js Flight props, skips byte-counted
text/binary records, and rejects conflicting allowance records.

JSON contains `httpStatus`, `source`, `observedAt`, and optional `api` / `vibe`
objects with `usedPercent`, `total`, `used`, `remaining`, `currency`, `resetsAt`,
and `resetLabel`. No raw response bodies, keys, or cookie values are printed.
Exit codes: `0` success, `2` bad arguments, `3` credentials, `4` HTTP/parse/save
error. There is no token-spending `refresh` command.

References: official Vibe [billing implementation](https://github.com/mistralai/mistral-vibe/blob/main/vibe/app_server/_billing.py)
and [Keychain implementation](https://github.com/mistralai/mistral-vibe/blob/main/vibe/utils/keyring.py),
[Mistral subscription documentation](https://docs.mistral.ai/admin/billing-usage/subscriptions).
The independent browser parser's schema investigation used the
[CodexBar Mistral integration](https://github.com/steipete/CodexBar/blob/main/docs/mistral.md).
Tests use synthetic keys, cookies, and HTTP responses. The Keychain/API path has
also been verified with a live Mistral Vibe key and billing response. The browser
alternative and permission UI still need live validation. A first connection on
another installation may require the user to approve Keychain access.

```sh
swift test --build-system native
```

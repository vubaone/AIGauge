# MistralGauge

Swift CLI for Mistral's monthly shared **Vibe & Studio** budget, with an
**API/Studio** fallback for API-only accounts. It follows CodexGauge's
CLI/client/extractor/models structure and exit codes. **API key (Keychain)**
remains the default: it reads an API key from macOS Keychain and GETs
`https://api.mistral.ai/v1/billing/budget`, as the official Vibe CLI does.
Explicit **Browser session (dashboard)** mode uses the website's JSON endpoint
for the closest match to its displayed budget; API-key mode remains a suitable
alternative without browser cookie access.

```sh
swift build -c release --build-system native
.build/release/MistralGauge usage --json
# First connection, if Keychain needs approval:
.build/release/MistralGauge usage --allow-keychain-prompt --json
```

In AIGauge, enable **Settings → Mistral**, leave **API key (Keychain)** selected,
and click **Connect Mistral**. This method does not open browser cookie databases,
need browser Safe Storage permission, or require Full Disk Access.

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

## Explicit Browser session (dashboard) mode

Choose **Browser session (dashboard)** to use an existing browser login and the
same budget source as the dashboard. Edge is the default for this method; Chrome
and Brave are also supported. This is opt-in, never an automatic fallback from
API-key mode.

```sh
.build/release/MistralGauge usage --auth browser --source edge --json
.build/release/MistralGauge usage --source edge --profile "Profile 1" --json
```

For compatibility, `--source`, `--profile`, or `--cookie-file` selects browser
mode when `--auth` is omitted. API-key and browser options cannot be mixed.
The selected profile must be signed in to Mistral Admin. Find its directory
name in `edge://version` (Profile path), e.g. `Default` or `Profile 1`.
The selected browser's cookie database can be read directly; pasted cookies are
not required. Optional manual browser credentials use `--cookie-file` or
`MISTRAL_COOKIE`, with an `ory_session_*` cookie; an optional `Cookie:` prefix is
accepted.

The browser extractor reads SQLite in read-only mode, supports Chromium v10
AES-CBC and v24 host digests, and filters by domain, path, and expiry. It does not
write browser databases or save cookies. Browser mode makes an authenticated GET
to `https://admin.mistral.ai/api/local-trpc/billing.budget`, with this JSON in the
`input` query parameter:

```json
{"json":null,"meta":{"values":["undefined"],"v":1}}
```

Only `result.data.json.vibe_budget` is used. The dashboard renders this shared
budget when it is valid and `initial_budget > 0`; browser mode does not use an
`api_budget` sibling. There is no `/subscription` HTML parsing, Next.js Flight
parsing, or HTML fallback. This internal tRPC endpoint may change.

Both connection methods block redirects and use an ephemeral HTTP session
without cookie storage or response caching. No Sentry/analytics headers are
copied from the browser, and no cookies are hardcoded. No requests send model
prompts or change the provider account.

If macOS denies cookie file access, click **Grant cookie access…**. It opens
Full Disk Access settings and shows the actual running app as a draggable icon.
Drag that app into the settings list, enable it, then quit and reopen AIGauge.
macOS requires the user to approve this setting; the button cannot enable it.
Full Disk Access covers protected files from other apps and is separate from
the browser's Safe Storage Keychain permission. For a standalone CLI, authorize
the terminal app. See [Apple's privacy settings guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac).

## Quota data and output

Both sources preserve the reported percentage, total, currency, and reset, and
derive used/remaining amounts. Missing, null, malformed, or zero-size budgets are
omitted, never synthesized from a default plan amount. A valid budget with 0%
usage is still shown. Usage can exceed 100%; remaining bottoms out at zero.
Prepaid credits and request/token rate limits are separate from these monthly
allowances.

Mistral's [subscription docs](https://docs.mistral.ai/admin/billing-usage/subscriptions)
describe shared monthly usage across Studio, API, and Vibe Code. The public API
may still return a legacy `api_budget` alongside `vibe_budget`. When a valid
`vibe_budget` with `initial_budget > 0` exists, AIGauge shows **only Vibe & Studio**
and suppresses `api_budget`, even if the server includes it. These budgets are
never summed. Native API-key mode can fall back to a valid `api_budget` as
**API/Studio** for API-only accounts without a valid shared Vibe budget. Browser
mode reads only `result.data.json.vibe_budget`; a missing or zero-size shared
budget does not trigger an API or HTML fallback.

JSON contains `httpStatus`, `source`, `observedAt`, and the compatible optional
`api` / `vibe` objects with `usedPercent`, `total`, `used`, `remaining`, `currency`,
`resetsAt`, and `resetLabel`. In normalized output, `api` is omitted whenever a
valid `vibe` budget is present; `api` remains available for the API-only fallback.
No raw response bodies, keys, or cookie values are printed.
Exit codes: `0` success, `2` bad arguments, `3` credentials, `4` HTTP/parse/save
error. There is no token-spending `refresh` command.

References: official Vibe [billing implementation](https://github.com/mistralai/mistral-vibe/blob/main/vibe/app_server/_billing.py)
and [Keychain implementation](https://github.com/mistralai/mistral-vibe/blob/main/vibe/utils/keyring.py),
[Mistral subscription documentation](https://docs.mistral.ai/admin/billing-usage/subscriptions).
Tests use synthetic keys, cookies, and HTTP responses. Live checks have also
verified the Keychain/API path, the dashboard's tRPC budget source, and direct
cookie extraction from an existing Edge profile without new prompts or pasted
cookies. This does not mean every first-run or permission UI flow has been
live-tested. Another installation may still require browser cookie-file access
and/or Keychain approval.

```sh
swift test --build-system native
```

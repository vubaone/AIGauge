# Release AIGauge with one command

The workflow follows SmallGit's local release tooling. It runs tests, builds and
verifies the bundle, creates versioned assets, uploads a GitHub draft, and checks
the remote assets. It never opens the desktop or starts a simulator.

```sh
./release.sh             # verified draft GitHub Release
./release.sh --publish   # publish a new release after draft/asset verification
./release.sh --local     # run checks and package locally, no GitHub changes
./release.sh --local --notarize  # local notarized package; submits app to Apple
./release.sh --check     # readiness checks only; no build/upload
```

For each release:

1. Edit `clientVersionString` and `clientVersionInt` in
   `aigauge/Sources/AppVersion.swift`, using the explicitly chosen version.
2. Run `./make_version.sh`. It synchronizes the concrete `Info.plist` values,
   `project.yml`, and any generated Xcode project. `--check` only verifies.
3. Test/review, commit, and push the intended source normally. Upload modes
   require a clean checkout and HEAD equal to the branch on `origin`.
4. Run `./release.sh --publish --notes docs/releases/26.11.01.md` (substitute the
   release's notes path). Without `--publish`, the verified release stays a draft.

Requirements: macOS, the Swift/Xcode command-line toolchain, Python 3.9+, Git,
and authenticated GitHub CLI for upload modes. GitHub uploads also require a
Developer ID Application signing identity and stored notarytool credentials.
Local mode accepts uncommitted changes and marks its manifest `dirty: true`.
Without `--notarize`, local mode makes no requests to Apple's notary service.
No command automatically commits,
pushes source, changes repository visibility, moves tags, or overwrites releases.

## Verification and privacy

- Source scan rejects known token/key patterns, private credential files,
  generated logs/caches, and personal machine paths. It redacts findings and
  complements a manual code review; it is not a guarantee against every leak.
- Release tooling tests run with fake GitHub responses. All four Swift unit
  suites run without opening apps or using real credentials.
- Version/build, MIT notices, all four Mach-O executables, architecture,
  stripped symbols, no DWARF/dSYM, no personal build paths, and code signatures
  must pass before packaging.
- The bundle file allowlist rejects unexpected resources or symlinks. ZIPs
  contain only that verified app, with no extended attributes or resource forks.
  Every archived file is compared with the verified bundle.
- Public uploads require all four executables to have Developer ID Application
  signatures from the selected team, Hardened Runtime, secure timestamps, and
  no debug `get-task-allow` entitlement. The app-only submission is sent to Apple
  using the chosen Keychain profile. Apple must return `Accepted`; its log must
  match the submission ID and SHA-256 of that exact ZIP.
- The pipeline staples and validates Apple's ticket, rechecks the bundle, and
  requires Gatekeeper approval. It then repackages, extracts the final ZIP into
  a local temp directory, and verifies its ticket, signature and Gatekeeper
  assessment again before any GitHub upload.
- Upload modes recheck source/branch/tag state, create a draft pinned to the
  exact commit, then verify asset names, upload states, sizes and SHA-256. If the
  API omits a digest, the asset is downloaded into project temp and compared.
- `--publish` publishes only after draft verification, then verifies the public
  release, assets and actual tag commit again. An interrupted upload can leave a
  partial draft; inspect it before retrying. Nothing is clobbered or deleted.

Only these assets are uploaded:

| Path in `aigauge/release/` | Contents |
| --- | --- |
| `AIGauge-<version>-macos-<arch>.zip` | App plus three bundled CLIs and licenses |
| Same ZIP filename plus `.sha256` | SHA-256 checksum |
| `AIGauge-<version>-macos-<arch>.json` | Commit/version/build/architecture/signing type |

Logs and temporary notes stay under `aigauge/.build/release-workflow/`; caches
and test outputs stay inside the project. No workspace, cookies, API keys,
Keychain items, personal usage responses, or test logs are uploaded.

## Signing

GitHub draft/public release uploads always require notarization; there is no
ad-hoc fallback. `build.sh` alone and `release.sh --local` remain available for
local development with ad-hoc signing.

One-time setup:

1. Create/import a **Developer ID Application** certificate with its private key
   in Keychain. Apple Development and Apple Distribution are different certificate
   types and cannot replace it. Developer ID certificate creation requires the
   appropriate Apple Developer account role.
2. Store notarization credentials interactively in Keychain:

   ```sh
   xcrun notarytool store-credentials AIGauge
   ```

   Enter the Apple account / app-specific password or API-key information in
   Terminal. Never paste passwords or private keys into source, shell command
   arguments, release notes, or chat.
3. If there is exactly one valid Developer ID Application identity, the workflow
   selects it. With multiple identities, set `SIGN_ID` to the intended certificate
   name or public SHA-1 fingerprint. This value is not a private key.
4. The profile defaults to `AIGauge`; `--notary-profile NAME` or
   `NOTARY_KEYCHAIN_PROFILE` selects a different stored profile.

Notary submission/log files stay under `aigauge/.build/release-workflow/notary/`.
The manifest exposes only the accepted status, submission ID, staple/Gatekeeper
results and warning count. It does not include credential/profile names or Apple
account information. A Developer ID signature itself carries the publisher's
public certificate identity, as required by macOS.

Rejection, timeout, signing, log, staple or Gatekeeper failure stops before upload.
An in-progress Apple submission may continue after a timeout; inspect its saved
ID and use `xcrun notarytool wait ID --keychain-profile AIGauge` instead of blindly
submitting a duplicate. Existing release assets are unchanged by a failed run.
No DMG or desktop styling runs as part of this pipeline.

Apple documentation: [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
and [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).

For a version that already has a release, stop and inspect it; do not overwrite
assets or move its tag. Publishing an existing reviewed draft can be done
separately with `gh release edit TAG --repo OWNER/REPO --draft=false`.

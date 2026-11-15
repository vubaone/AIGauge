# AIGauge release workflow

When asked to release AIGauge, use the repository entry point:

```sh
./release.sh            # tests/build/package and verified GitHub draft
./release.sh --publish  # publish a new release after asset verification
./release.sh --local    # all local checks; no upload or GitHub changes
./release.sh --local --notarize  # local notarized package; uploads only to Apple
./release.sh --check    # readiness checks only
```

- Read `docs/releasing.md`. Follow the user's requested version; do not choose
  today's date automatically. Version comes from `aigauge/Sources/AppVersion.swift`.
  Run `./make_version.sh`, commit metadata, and normally push before uploading.
- Scan privacy before push and release: `python3 -B aigauge/scripts/check-privacy.py`.
  Review intended source and artifact contents. Do not publish credentials,
  personal account responses, local paths, logs, caches, or private notes.
- Default to a draft unless publication is requested. A request to change the
  workflow itself only authorizes `--local`, not a real release.
- Upload modes require clean source and HEAD equal to the pushed origin branch.
  Never force-push, move a tag, overwrite an existing release, or bypass checks.
  New releases are uploaded as drafts, verified, then optionally published.
- GitHub upload modes require a Developer ID Application identity, a stored
  notarytool profile, Apple Accepted status, a stapled ticket and Gatekeeper
  approval. Never fall back to ad-hoc signing for public releases. Keep Apple
  credentials in Keychain; never put passwords/private keys into source or chat.
- Report version/build, commit, tests, privacy check, release URL and draft/public
  state, plus actual Apple notarization/staple results. Local-only builds may use
  ad-hoc signing; do not describe them as notarized.
- Do not open or control the main Mac desktop for build/test/release work. Do
  not create a VM, simulator or clone. Use the included desktop-free tests and
  keep temporary artifacts and logs inside this project.

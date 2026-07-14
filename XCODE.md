# Building & notarizing AIGauge in Xcode

The `.xcodeproj` isn't committed — it's generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so there's no giant
`project.pbxproj` to hand-edit or merge. Generate it once, then use Xcode's
normal Archive → Distribute flow to sign and notarize a release you can hand to
anyone.

## 1. One-time setup

Install XcodeGen and generate the project (run from the repo root):

```sh
brew install xcodegen
xcodegen generate
open AIGauge.xcodeproj
```

You also need a **Developer ID Application** certificate (a paid Apple Developer
account). If you don't have one yet: Xcode → Settings → Accounts → your team →
Manage Certificates → **+** → *Developer ID Application*.

## 2. Set your team

In Xcode, select the **AIGauge** target → **Signing & Capabilities** →
choose your **Team**. Do the same for the **ClaudeGauge** and **CodexGauge**
targets (or set `DEVELOPMENT_TEAM` in `project.yml` and re-run `xcodegen
generate` to bake it in for all three).

Signing is already configured for release: Automatic signing, Hardened Runtime
on, and the two CLIs are embedded into the app's `Contents/Resources` with
*Code Sign On Copy* — so Xcode signs the whole bundle as one unit.

## 3. Archive & notarize

1. Set the scheme to **AIGauge** and the destination to **Any Mac**.
2. **Product → Archive.**
3. In the Organizer that opens: **Distribute App → Developer ID → Upload**.
   Xcode sends the archive to Apple's notary service, and when it comes back it
   staples the ticket automatically.
4. **Export** the notarized `AIGauge.app`.

The exported app opens on any Mac with no Gatekeeper warning, even offline.

## 4. (Optional) Wrap it in a DMG

To ship the styled drag-to-Applications disk image, drop the exported
`AIGauge.app` into `aigauge/release/` and run:

```sh
cd aigauge
./make-dmg.sh
```

Because the app is already stapled, the DMG's contents pass Gatekeeper. If you
want the DMG itself notarized too, submit it with `notarytool` and staple it:

```sh
xcrun notarytool submit release/AIGauge.dmg --keychain-profile AIGauge --wait
xcrun stapler staple release/AIGauge.dmg
```

## Verifying

```sh
spctl -a -vvv -t exec /path/to/AIGauge.app   # → accepted, source=Notarized Developer ID
xcrun stapler validate /path/to/AIGauge.app
```

## Notes

- `build.sh` still exists for quick **local** (ad-hoc) command-line builds — it
  does *not* notarize. Use the Xcode flow above for anything you distribute.
- After changing source files, targets, or settings in `project.yml`, re-run
  `xcodegen generate`. Adding or removing `.swift` files under the existing
  `Sources` folders needs a regenerate too.

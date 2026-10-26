# Mac distribution

`make share` builds the universal app and produces both `dist/satz-mac.dmg`
and the existing `dist/satz.zip`. The DMG contains `satz.app` and a shortcut to
Applications. Drag the app into Applications, eject the image, then open the
installed app. The Finder icon positions and window settings are checked-in
metadata; no Finder scripting or global security changes are used.

These default artifacts are ad-hoc signed for local development. A DMG changes
the installation experience; it does not establish Developer ID trust. Do not
describe `make share` output as notarized or promise a warning-free first launch.
Keep the legacy release filename `satz-mac.zip` when publishing `dist/satz.zip`.

## Trusted public release

The release machine needs an existing Apple Developer Program membership, a
valid **Developer ID Application** signing identity in its Keychain, and an
existing `notarytool` Keychain profile. Creating membership, accepting Apple's
contracts, installing a certificate/private key, or storing credentials is a
separate account-owner step. This repository does none of those automatically.

Inspect public identity names with:

```sh
security find-identity -v -p codesigning
```

Then use the exact installed identity and the name of an already configured
Keychain profile. The strings below are examples, not credentials shipped with
the project:

```sh
make release-check \
  SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
  NOTARY_PROFILE='your-existing-notary-profile'

make release \
  SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
  NOTARY_PROFILE='your-existing-notary-profile'
```

`release-check` checks configuration and the installed certificate without
submitting anything. `make release` builds outside the synced source folder
and leaves the user's `dist/satz.app` alone. It signs every nested Mach-O and
helper bundle inside-out with a secure timestamp and Hardened Runtime, then
signs the host app. It submits an app archive to Apple, requires an explicit
`Accepted` status, staples and validates the app's ticket, creates a ZIP of that
stapled app, creates/signs the DMG, and submits/staples/validates the DMG too.
Both Gatekeeper assessments must pass before the output artifacts are replaced.
Nothing is uploaded to GitHub or the CDN. Apple's notarization submissions are
the only uploads in this command.

The notarization result JSON and rejection logs are retained under
`$SCRATCH/notary-logs/`. If Apple's service times out, use the saved submission
ID with `xcrun notarytool info` / `log` and the same Keychain profile. A timeout
is not proof of acceptance; rerun the release after resolving the submission.
The standalone `notarize.sh` defaults its logs to `notary-logs/` next to the DMG,
or accepts `NOTARY_LOG_DIR`.

The production host entitlement is only
`com.apple.security.device.audio-input`: dictation records microphone input.
The app is not sandboxed. No JIT, unsigned-memory, library-validation, DYLD,
debugger, or Apple Events exception is added. Libraries are signed with the
same identity. Sparkle's Downloader XPC helper keeps its upstream entitlements
if present, with `get-task-allow` removed; those entitlements are never applied
to the host or another helper. The other nested helpers are signed without
extra entitlements. Ad-hoc builds keep their existing identifier-based local
requirement so local Accessibility and Microphone grants survive rebuilds.

## Updater integration

`make bundle` invokes `scripts/macos/embed-updater.sh APP BIN_DIRECTORY` when
that executable hook exists, before signing. Copy the full Sparkle framework
with its version symlinks and helpers preserved. The signing script discovers
real nested Mach-O files and `.xpc`, `.app`, `.appex`, and `.framework` bundles,
then seals them from the deepest paths outward. `--deep` is used only for
verification. Updater feed/archive signatures and their public-key setup are
separate from Developer ID signing and notarization.

## Packaging checks without replacing the running app

`make dmg` and `make zip` package an already signed staging bundle; they do not
compile, launch, or replace an app. For an isolated existing stage:

```sh
make dmg zip \
  STAGE='/tmp/satz-package-check/satz.app' \
  MAC_DMG='/tmp/satz-package-check/satz-mac.dmg' \
  MAC_ZIP='/tmp/satz-package-check/satz.zip'

hdiutil verify /tmp/satz-package-check/satz-mac.dmg
hdiutil attach -readonly -nobrowse \
  -mountpoint /tmp/satz-package-check/mount \
  /tmp/satz-package-check/satz-mac.dmg
codesign --verify --deep --strict /tmp/satz-package-check/mount/satz.app
readlink /tmp/satz-package-check/mount/Applications
hdiutil detach /tmp/satz-package-check/mount
```

For an isolated build, override both `STAGE` and `APP`; `SCRATCH`, `UNIVERSAL`,
`BIN`, `MAC_DMG`, and `MAC_ZIP` are also configurable. Before a public release,
test the final downloaded DMG on a Mac with Gatekeeper enabled: drag into
Applications, launch, grant microphone/Accessibility permissions, dictate,
exercise optional local engines and the media helper, then install/restart a
real signed Sparkle update. Packaging verification alone does not prove those
runtime flows work under Hardened Runtime.

## Changing the Finder layout

Normal packaging uses `dmg-layout.dsstore` and needs only macOS tools. To
regenerate that template after editing `dmg-layout.py`, install development-only
`ds-store==1.3.1` and `mac-alias==2.2.3` in a temporary venv, then run the script.
No Python package is bundled in the app or required for ordinary DMG creation.

References: [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime),
[Sparkle manual signing](https://sparkle-project.github.io/documentation/sandboxing/).

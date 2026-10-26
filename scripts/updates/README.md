# Signed Mac updates

Sparkle 2.10.1 is pinned in SwiftPM and embedded by `scripts/macos/embed-updater.sh`.
The app requires Ed25519 signatures on both the appcast and downloaded archive,
and verifies the archive before extraction. It keeps only a version notice after
a passive check, so “Later” does not block discovery of future releases. Clicking
“Update and restart” starts a fresh check, downloads the current valid release,
and waits for an idle Session before relaunching. Failed/retryable dictations
must be completed or discarded first. No automatic background installation is
allowed. Test copies disable updates unless explicitly given a loopback feed.

## Preparing a release

1. Increment both the Mac short version and numeric `CFBundleVersion`, and the
   desktop version. A numeric build must increase on every Mac release.
2. Build and validate the packages. `make share` produces locally signed ZIP and
   DMG files; `make release` is the separate Developer ID/notarization path. Keep
   the release ZIP named `satz-mac.zip` for updater compatibility.
3. Create the appcast using the staged app and its exact final ZIP. The signing
   account `plus.dpa.satz` keeps the private update key in the local Keychain;
   only its public key is in Info.plist. Keychain may ask the operator to allow
   the official `sign_update` tool. Never export or commit this private key.

```sh
python3 scripts/updates/appcast.py \
  --app /absolute/path/to/stage/satz.app \
  --archive /absolute/path/to/satz-mac.zip \
  --sparkle-bin /absolute/path/to/Sparkle/bin \
  --base-url https://cdn.prozesshub.eu/assets/clients/dpa/downloads/satz/vVERSION \
  --output /absolute/path/to/appcast.xml
```

The script checks that the signing key matches the staged app, signs the exact
archive, writes a feed with the numeric build and display version, then signs
and verifies the feed. The version folder URL is immutable, so an update in
progress never changes underneath a reader. Do not modify a signed feed.

4. Include `appcast.xml`, `satz-mac.dmg`, `satz-mac.zip`, all desktop packages and
   their SHA256 entries in the GitHub release. Preserve the corresponding source
   archive and license notices. The CDN workflow checks hashes, copies the
   version folder first, and then publishes `latest/` and the release manifest.
5. Test the final public feed and packages before announcing availability.

The updater key and Apple's Developer ID certificate are separate. Creating the
updater key does not provide Apple signing or notarization. Those require the
account owner's installed certificate and configured notary profile.

## Verification

```sh
python3 -m unittest discover -s scripts/updates -p 'test_*.py'
```

Native lifecycle tests cover no installation on discovery, explicit user
approval, Later, stale observation, failed dictations, a new dictation during
download, cancellation, and blocking new/restored work before restart. A safe
runtime check uses a unique bundle ID, file audio, a scratch models folder and
`--dev-control ... --test-update-feed http://127.0.0.1:PORT/appcast.xml`. The
replacement test executable should only write a marker and exit, so relaunch
cannot enable a real microphone or global shortcut.

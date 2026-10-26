# Feedback fixes and updates, 26 October 2026

Implemented on the development branch, based on release 0.4.5. No new public
release was published and the user's running app was neither rebuilt in place
nor restarted. The existing release needs one manual update to gain the updater.

## Verified

- Native Mac tests: 218 passed in the full app suite. The core runner then hit
  an NSURLSession completion SIGTRAP, with no failed assertion; a separate
  core rerun passed all 518 tests. After the final cancellation changes, all
  12 focused updater/Session tests passed. Appcast generator: 4 Python tests.
- Desktop: typecheck and all 775 tests passed. A packaged ARM64 Ubuntu app in a
  disposable VM passed newer/current/offline notices, Download, Later/reopen,
  language switching and preserved field focus. The VM was stopped and removed.
- Native first run: DE/EN permission snapshots fit. The actual model picker
  scrolls from the first to final model, Continue stays visible, and the visible
  scrollbar is hidden. No model weights or permissions were requested in QA.
- Universal Mac ZIP and DMG built with embedded Sparkle and its helpers. Both
  the host and framework contain arm64 and x86_64. DMG checksum verification
  passed; a read-only mount had the app and Applications link, with a valid
  nested signature, and was detached.
- Actual Mac update test used a unique bundle ID, separate settings, file audio,
  scratch models, a loopback server and an ephemeral test signing key. The
  host required signed feed/archive and verification before extraction. A
  timestamp-modified ZIP still extracted identical files but failed update
  verification; the original host stayed at build 11. A valid signed archive
  then installed build 999 and relaunched a minimal marker-writing replacement.
  External preserved data remained unchanged and the installed signature passed.
  The test key was deleted. No real audio, paste or paid transcription occurred.
- Independent source review findings were addressed: discovery finishes its
  Sparkle session so Later cannot pin a stale release; restoring/resuming work
  shares the restart lock; cancellation clears queued install approval; a fresh
  install waits for the previous Sparkle session to finish.

## Limits

- AirPods hardware timing remains unmeasured. Direct UID lookup removes a full
  device enumeration only for an explicitly selected input. Following macOS
  already skipped that enumeration. Stage timings now distinguish lookup,
  engine open and first nonempty converted PCM buffer. No always-on mic added.
- The host has no valid Developer ID Application identity. Apple notarization
  remains unexecuted. Local ad-hoc signature integrity is not Gatekeeper trust.
- Windows and x64 Linux runtime were not exercised; Ubuntu ARM64 was. Desktop
  packages open downloads rather than replace/restart themselves.
- Full frontend verifier ran on deterministic preview fixtures at 560/1280/1440.
  Overflow, clipping, overlap, contrast, console/HTTP errors, layout shift and
  scope checks passed. Its overall report remains non-green: inherited spacing,
  fixed-width desktop-preview geometry, inherited radius/type/animation/copy
  heuristics, same-result recheck buttons and history-control coverage. Native
  CUA and packaged Ubuntu behavior were checked separately; no claim of a clean
  whole-product UI audit is made.

Temporary runtime evidence is stored under /tmp/satz-updater-e2e-20261026,
/tmp/satz-feedback-ui-20261026, /tmp/satz-update-runtime and
/tmp/satz-final-build-20261026 on the verification machine.

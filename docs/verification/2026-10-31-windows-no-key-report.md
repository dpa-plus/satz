# Windows report: "No key" after restart, 31 October 2026

A report from satz 0.4.5 on Windows 11 Home (build 26300, x64), OpenRouter with
MAI-Transcribe 2, right Ctrl plus an AutoHotkey script that runs
`satz.exe --toggle` from a mouse button. Each point was checked against the
code; what is real is fixed in 0.4.6 (Windows and Linux).

## Issue 1: "No key" after restart, with the key file there

**What the code did.** `readKey` caught every error and returned nothing, so
"No key" meant a missing file, an empty one *or* one that could not be read.
A dictation refused for it wrote no log line, and the logger dropped any line
it could not write. A `preferences.json` that could not be read was taken for
none and written over with the standard settings at the next change. So the
report's observations are all explained by the code; the cause on that
computer is not proven.

**The most likely cause** fits every observation: the failing satz ran with a
*different data folder* from the one that holds the key. That explains "No key"
with the key file present and readable, no startup lines in the existing log
(they went to the other folder's log), and a manual restart that works. One
way this happens: the mouse script runs elevated (as administrator), and on
newer Windows builds with *Administrator protection* an elevated program runs
under a separate system-managed account with its own profile. If satz was not
running yet, `satz.exe --toggle` from that script started satz under that
account, which has no key. 0.4.6 logs the account and the data folder on every
start, so the next occurrence settles it.

**Fixed in 0.4.6:**

- "No key" (none saved, or an empty file) and "Key unreadable" (a file there
  that could not be read) are told apart, on the card, in the tray and in
  Settings, which shows the system's error code under the key field. A file
  locked for a moment (a virus scanner, the sign-in) is read three times
  before it counts as unreadable, and again at every dictation.
- The log says once per change what is wrong with a key file, with its path
  and never the key, and logs every dictation refused for it.
- Every start logs how satz was started (at login, `--toggle`, by hand), the
  account and the data folder. The login entry now passes `--login`.
- A log line satz's folder refuses goes to `satz.log` in the temp folder,
  whose first line says why. Settings has a new **Status** section: version,
  how satz started, what is wrong (only when something is), *Open log* and
  *Open folder*.
- An unreadable `preferences.json` is left as it is: standard settings in
  memory, nothing saved, read again every 5 s for 5 minutes. A broken one is
  moved aside and kept.
- A `satz --toggle` that arrives while satz is still starting is carried out
  once it is ready; before, it was lost.
- The tray's tooltip and first menu line say whether satz is ready
  ("satz 0.4.6: ready (right Ctrl twice)") or what is missing.
- Start at login: Electron switched satz's entry back on in Windows' Startup
  apps at every start, over the user's own choice there. Now satz leaves that
  switch alone, and Status says when Windows will not start satz.

**Suggested for that computer:** remove the separate delayed startup shortcut
and the restart heuristic, switch "Start at login" in satz off and on once, and
make sure the mouse script does *not* run as administrator. If "No key" comes
back, Settings › Status and the log's `started … as <account>, data in
<folder>` line show which account and folder that satz used.

## Issue 2: local models and Arabic

Not a bug, but a real limit: in satz the Whisper models only ever write German
or English. satz lets Whisper choose between those two only, so Arabic speech
comes out translated or garbled. Locally only **Qwen3-ASR 0.6B** (detects the
language itself) and **Cohere Transcribe** (choose Arabic under its own
"Spoken in"; 2.9 GB and slow) write Arabic. Neither has been tested on Egyptian
Arabic. For Arabic mixed with English, stay with OpenRouter and MAI-Transcribe 2.

## Feature requests

- **Start at login with a readiness indicator:** done (tray tooltip, menu
  line, Status, the Windows Startup check).
- **Configurable shortcuts, mouse buttons:** not built. `satz --toggle` is the
  supported way and is now documented in `desktop/README.md`; the early-toggle
  fix makes it reliable at login.
- **Versions and updates:** the version is in the tray tooltip and Status.
  0.4.5 has no update check: 0.4.6 has to be downloaded once by hand
  (`satz-windows-x64.zip`, unzip over or beside the old folder; start at
  login follows the new folder). From then on satz shows a notice under the
  tabs when a newer release exists, and the tray has "Check for updates…".
- **Theme selector:** there is none; the window has one dark look.
- **Text editing after transcription:** that is *Aufräumen / Cleanup* in
  Settings, between Replacements and General. It is in 0.4.5 and is off until
  switched on.
- **Encrypting stored keys:** not changed. Keys are plain files in the user's
  own profile folder, which only that user, SYSTEM and administrators can read.
  Windows' DPAPI would bind them to the account, so the account mix-up above
  would also make the key unreadable. Worth revisiting once that is settled.

## Caps Lock notice on the mouse side buttons

Not satz: satz never sends Caps Lock (it only sends Ctrl+V to paste, and
listens for Escape while recording). Logi Options+ shows its own Caps Lock
on-screen notice, and the AutoHotkey script's screenshot shortcuts on the back
button are the other candidate.

## Verified

- Desktop: typecheck and all 785 tests passed (10 new ones in
  `test/keyAndSettingsRead.test.ts`), `npm run build` passed.
- The Electron app was started in test mode on Linux under Xvfb with a missing
  key, with a key file, preferences file and log that could not be read (each
  replaced by a folder), and with a working key. The card said "No key" and then
  "Key unreadable". The settings file was left alone, and the log moved to the
  temp folder with its reason. A `--toggle` sent 0.3 s after the start was
  carried out once satz was ready, and a dictation started with the key present.
- The Settings page was checked in the browser preview in German and English,
  with and without problems.

## Limits

- Not run on Windows: the Run-key `--login` argument, the
  `executableWillLaunchAtLogin` check and the Startup-apps switch were not
  exercised on a real Windows, and the root cause on the reporter's computer
  is not proven.
- The Mac app reads its keys the same way (`Secrets.read` returns nil for
  every error). It was not changed here because it could not be built or
  tested on this machine; the report concerns Windows.

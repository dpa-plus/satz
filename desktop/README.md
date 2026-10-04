# satz for Windows and Linux

The Mac app's dictation for Windows and Linux, on Electron: tap **right Ctrl twice**, talk, tap it twice again, and the text lands where you were typing. Same card (pause, eye, discard with Undo, click in the text to move where speech goes), same transcription (MAI-Transcribe 2 through OpenRouter, clean mode, word list, Ersetzungen).

## Install

| System | File | How |
|---|---|---|
| Windows 11 (ARM or Intel/AMD) | `satz-0.1.0-windows-arm64.zip` / `-x64.zip` | Unzip anywhere, run `satz.exe`. Not signed yet, so SmartScreen may ask once ("More info", "Run anyway"). |
| Ubuntu / Debian | `satz-0.1.0-linux-arm64.deb` / `-amd64.deb` | `sudo apt install ./satz-…deb`, then start "satz" from the app menu. |
| Other Linux | `satz-0.1.0-linux-…tar.gz` | Unpack, run `./satz`. |

On first start satz opens its settings for the API key, and switches on start at login (it can be switched off there).

## Linux and Wayland

Wayland (Ubuntu's default) lets no app watch the keyboard or type into other apps. satz handles it like this:

- **Shortcut:** right Ctrl twice works when the user may read the keyboard devices: `sudo usermod -aG input $USER`, then sign out and in. Without that, make a keyboard shortcut in the system settings that runs `satz --toggle`.
- **Paste:** with [ydotool](https://github.com/ReimuNotMoe/ydotool) running (`ydotoold`), satz pastes by itself. Without it the text goes to the clipboard and the card says "On the clipboard · Ctrl+V".
- The card runs through XWayland, the only way a window can stay on top and choose where it sits. The `satz` start script takes care of that and of Chromium's sandbox (see `build/after-pack.cjs`).

## Build

```bash
npm install
npm test               # 48 tests: the shared core, ported from the Mac app
npm run dist:win       # release/*.zip
npm run dist:linux     # release/*.deb, *.tar.gz
```

Everything builds on a Mac. `npm start` runs it locally.

## Test mode

`satz --dev-control 48700 --test-audio a.wav:b.wav` plays WAV files instead of the microphone and takes commands on `http://127.0.0.1:48700/<command>`: `press`, `release`, `mic`, `discard`, `undo`, `restore`, `eye`, `caret?at=N`, `state`, `picture`, `js?code=…`. Texts are recorded instead of pasted unless `--test-paste` is given. Windows takes `;` between the files.

## What was verified (04.10.2026)

In a Windows 11 ARM VM and an Ubuntu 26.04 ARM VM (GNOME on Wayland), with real key presses and clicks sent into the VMs and real MAI-Transcribe calls:

- **Shortcut:** real right-Ctrl taps start and finish a dictation. Escape discards while recording. Ctrl+C with the right Ctrl does not trigger.
- **Card:** the mic button pauses and continues, the eye hides and shows the text, × discards and Undo brings it back. The card stops at the screen edge and remembers where it was put.
- **Paste:** the text goes into Notepad (Windows) and into GNOME Text Editor through ydotool. Without ydotool it falls back to the clipboard. The clipboard is handed back afterwards.
- **Start at login:** satz starts by itself after signing in, on both. Settings save. "No microphone" is said plainly.

Not verified: a real microphone (the VMs have none; test mode feeds files into the same path), and the x64 builds, which have no VM. On ARM Linux under X11 the keyboard library's prebuilt binary is actually x86-64 (an upstream packaging error); satz then starts without the hook and uses `satz --toggle`.

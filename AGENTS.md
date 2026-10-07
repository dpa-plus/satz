# satz: notes for coding agents

Read by Codex (`AGENTS.md`) and Claude Code (`CLAUDE.md` imports this file).

satz is a dictation app: tap a shortcut twice, talk, tap again, and the text is pasted where the cursor is. The audio goes straight to a transcription API the user picks. There is no satz server.

## Where things are

| Path | What |
|---|---|
| `Sources/SatzKit` | Mac core: audio, WAV, transcription client, replacements, key files. Tests in `Tests/SatzKitTests`. |
| `Sources/SatzMac` | The Mac app: shortcut, card, paste, menu bar, settings, setup, test mode (`Develop/`). |
| `desktop/` | Windows and Linux: Electron + TypeScript. `src/core` is the same logic as SatzKit, ported; `src/main` and `src/renderer` are the app. Read `desktop/README.md`. |
| `scripts/e2e` | Test mode helpers: spoken clips, a command sender, the test copy. |
| `assets/` | README pictures, rendered by the app itself (`make hero`, `make showcase`). |

## Build and test

```bash
make app          # dist/satz.app (Swift 6, release build, ad-hoc signed)
make test         # Swift tests, offline
make share        # universal build zipped as dist/satz.zip
cd desktop && npm install && npm test     # 48 tests of the shared core
npm run dist:win / npm run dist:linux     # zip / deb + tar.gz, built on the Mac
```

The user's own satz usually runs from `dist/satz.app`. Rebuilding replaces the bundle, but the running copy keeps the old code until it restarts. **Tell the user before restarting their satz**, and never while they are dictating.

## Trying a change without touching the user's satz

```bash
scripts/e2e/test-copy.sh --build     # "satz test.app": own name, bundle id and settings
source scripts/e2e/e2e.sh
launch "a.wav:b.wav"                 # plays the clips instead of the microphone
cmd press; sleep 6; cmd press; st    # dictate, finish, print phase and text
stop                                 # always stop it: a second menu bar icon confuses the user
```

- Test mode (`--test-audio … --dev-control state.json`) never pastes: the text goes to the state file. Commands: `press`, `release`, `mic`, `discard`, `undo`, `eye`, `caret:<n>`, `dump`, `picture`, `film`, `clipboard`, `strand`, `settings`, `setup`, `history`, `menu`, `close`.
- The test copy shares the key files in `~/Library/Application Support/satz` with the real satz. In test mode the history lives next to the state file, so the user's is never touched.
- Windows only come forward when the app is opened for real: `open "$HOME/Applications/satz test.app"`. A test-mode command cannot make satz the active app.
- `satz --snapshot <dir>` renders every surface to PNGs without a window or permissions. Use it to look at UI.
- Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "plus.dpa.satz"' --info` (in zsh, plain `log` is a builtin).

Windows and Linux are tested in QEMU VMs on the user's Mac; see `desktop/README.md` for the test mode there (HTTP on 127.0.0.1).

## Rules

- **No local models, and no second model rewriting what was said**, unless the user turns such an option on. Accuracy comes from the transcription model, the word list and replacements.
- **Never cut the audio.** One recording per insertion spot; cut pieces came back garbled or in the wrong language.
- **Never lose the user's words or clipboard.** Failed requests keep the audio; the clipboard is put back after pasting unless the user chose to keep the text there.
- Every user-facing string exists in German and English: `de("…", en: "…")` on the Mac, `t('…', '…')` on Windows and Linux. No em dashes in UI text.
- Keys are never printed, logged or committed. They live in files readable only by the user.
- Comments say why, not what. Match the code around you.
- A feature lands on the Mac and on Windows/Linux, or says why not.
- Small commits on `main`, pushed. Commit by path (`git commit -- <files>`); other sessions may have staged work.
- Releases: `make share`, `npm run dist:win`, `npm run dist:linux`, then a GitHub release with the stable file names the README links to (`satz-mac.zip`, `satz-windows-x64.zip`, `satz-linux-amd64.deb`, …).

# satz for Windows and Linux

The Mac app's dictation for Windows and Linux, on Electron: tap **right Ctrl twice**, talk, tap it twice again, and the text lands where you were typing. Same card (pause, eye, discard with Undo, click in the text to move where speech goes), same transcription (MAI-Transcribe 2 through OpenRouter, clean mode, word list, Ersetzungen).

## Install

| System | File | How |
|---|---|---|
| Windows (ARM or Intel/AMD) | `satz-windows-arm64.zip` / `satz-windows-x64.zip` | Unzip anywhere, run `satz.exe`. Not signed yet, so SmartScreen may ask once ("More info", "Run anyway"). |
| Ubuntu / Debian | `satz-linux-arm64.deb` / `satz-linux-amd64.deb` | `sudo apt install ./satz-linux-…deb`, then start "satz" from the app menu. |
| Other Linux | `satz-linux-arm64.tar.gz` / `satz-linux-x64.tar.gz` | Unpack, run `./satz`. |

On first start satz opens its settings for the API key, and switches on start at login (it can be switched off there).

## Without the internet

Provider **Local** runs speech recognition on the computer itself, on the CPU, through two engines: Whisper on transformers.js and ONNX Runtime, and [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) for the models [Handy](https://github.com/cjpais/Handy) offers. Settings shows them the way Handy does: **Your models** (on this computer, the one in use first) and **Available models**, one card each with a sentence on what it is good at, an accuracy bar and a speed bar, its languages and its size. Click an available card to download it (one at a time, with progress and Cancel); click one of yours to use it; *Delete* moves it to the Trash. The catalog is `src/core/localModels.ts`:

| Model | Engine | Size | Languages |
|---|---|---|---|
| Whisper Large v3 Turbo (the default) | Whisper | 981 MB | German and English |
| Whisper Large v3 | Whisper | 1.4 GB | German and English |
| Parakeet V3 | sherpa-onnx | 670 MB | 25 European languages, found by itself |
| Whisper Medium | Whisper | 786 MB | German and English |
| Canary 180M Flash | sherpa-onnx | 207 MB | English, German, Spanish, French: told which under its own "Spoken in", apart from the app's German or English |
| Whisper Small, Base, Tiny | Whisper | 328, 149, 99 MB | German and English |
| Whisper Large v3 Turbo German (primeLine) | Whisper | 983 MB | German only |
| Parakeet V2 | sherpa-onnx | 661 MB | English only |
| Distil-Whisper Large v3.5 | Whisper | 950 MB | English only |
| Moonshine Base, Moonshine Tiny | sherpa-onnx | 287, 124 MB | English only |
| SenseVoice | sherpa-onnx | 240 MB | Chinese, English, Japanese, Korean, Cantonese |

The accuracy bar is Handy's score for the model; its help gives the German error rate on FLEURS where one is published (the Open ASR Leaderboard's file, fetched once a day, or the shipped numbers). The speed bar comes from satz's own speed test once the model was measured on this computer (seconds per 10 s of speech on a log scale: 0.2 s fills it, 1 s is 70 %, 3 s 40 %, 10 s 10 %), and from Handy's score until then. The test runs on a bundled 10 s clip (`assets/speedtest.wav`) right after a download, twice through the dictation path, the second run counts, and only once no dictation is under way (`src/main/speedTests.ts`); the result is kept as `<id>.speed.json`.

Models are downloaded once from Hugging Face into satz's own folder, beside the model in use, which stays loaded: Whisper's from the onnx-community repos, sherpa-onnx's file by file from [csukuangfj](https://huggingface.co/csukuangfj)'s repos at a fixed commit, each file checked against its SHA-256 and named only once complete (one left from an earlier try is kept only if its checksum is right), into `<models>/sherpa/<name>/`. A marker beside the folder is written only when the model has also loaded once. A download becomes Local's model by itself only when the model in use is not on the computer, and never switches the provider. Choosing a provider in the menu only shows it: dictations keep going to the one marked "(in use)" until *Use …* in the row under the menu, or a click on one of your models while Local is shown.

Whisper finds the language itself per recording, between German and English; the two single-language models always decode in theirs. The word list goes in as Whisper's prompt only where it costs no words (satz decodes with and without it and keeps the prompted text only if it is as long). The sherpa-onnx models take no prompt (the replacements still apply). Canary cannot tell the language: while it is the model in use, a "Spoken in" row under the cards offers its four, kept apart from the app's own German or English (Whisper and the replacements go by that one). Parakeet takes a whole dictation; Moonshine, SenseVoice and Canary get it in pieces of at most 30 s, cut at the quietest moment (`src/core/windows.ts`), as Whisper does. Silence is never sent to any of them. On Windows on ARM there is no sherpa-onnx build, so its six models are not offered there.

Each engine runs in a helper process of its own (`local-worker.js`, `sherpa-worker.js`): ONNX Runtime blocks the thread it runs on, and sherpa-onnx brings its own ONNX Runtime (1.28.2, beside onnxruntime-node's 1.30.0). On Windows both are `onnxruntime.dll`, and Windows hands a DLL that is already loaded to whoever asks for that name next, so in one process one engine would run on the other's runtime. A helper ends when Local's model moves to the other engine or another provider is chosen, which gives all its memory back. The Windows packages carry Microsoft's C++ runtime DLLs next to onnxruntime-node (`build/vcruntime.py` fetches them from Microsoft's redistributable); a fresh Windows has none. sherpa-onnx's Windows build needs none.

Licences of the models satz downloads (none ship with satz): Parakeet TDT 0.6B [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and [Canary 180M Flash](https://huggingface.co/nvidia/canary-180m-flash) by NVIDIA, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); Moonshine [Base](https://huggingface.co/UsefulSensors/moonshine-base) and [Tiny](https://huggingface.co/UsefulSensors/moonshine-tiny) by Useful Sensors, MIT; [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) by FunAudioLLM (Alibaba), [FunASR model licence](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE), in its [sherpa-onnx export](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17); Whisper by OpenAI, MIT.

## Linux and Wayland

Wayland (Ubuntu's default) lets no app watch the keyboard or type into other apps. satz handles it like this:

- **Shortcut:** right Ctrl twice works when the user may read the keyboard devices: `sudo usermod -aG input $USER`, then sign out and in. Without that, make a keyboard shortcut in the system settings that runs `satz --toggle`.
- **Paste:** with [ydotool](https://github.com/ReimuNotMoe/ydotool) running (`ydotoold`), satz pastes by itself. Without it the text goes to the clipboard and the card says "On the clipboard · Ctrl+V".
- The card runs through XWayland, the only way a window can stay on top and choose where it sits. The `satz` start script takes care of that and of Chromium's sandbox (see `build/after-pack.cjs`).

## Build

```bash
npm install
npm test               # 147 tests: the shared core, ported from the Mac app, and the local engines
npm run dist:win       # release/*.zip
npm run dist:linux     # release/*.deb, *.tar.gz
```

Everything builds on a Mac. `npm start` runs it locally. npm installs sherpa-onnx's native code only for the Mac that builds (`sherpa-onnx-darwin-arm64`, kept out of the packages); `build/after-pack.cjs` puts each package's own, `sherpa-onnx-linux-x64`, `-linux-arm64` or `-win-x64`, at the version and checksum `package-lock.json` names (cached in `build/sherpa/`), beside `app.asar` in `resources/app.asar.unpacked/node_modules/`, where `src/main/sherpaEngine.ts` loads it. That adds 8 to 13 MB to a download (23 to 40 MB unpacked); the Windows ARM zip gets nothing.

## Test mode

`satz --dev-control 48700 --test-audio a.wav:b.wav` plays WAV files instead of the microphone and takes commands on `http://127.0.0.1:48700/<command>`: `press`, `release`, `mic`, `discard`, `undo`, `restore`, `eye`, `caret?at=N`, `state`, `picture`, `js?code=…`, `local`, `local-download`, `local-cancel` and `local-measure` (a local model's state, its Download, its Cancel and its speed test; `?id=…` names the model, e.g. `sherpa/moonshine-tiny`, else the one in use; set `"provider": "local"` in preferences.json to dictate with it). `--models-dir <folder>` keeps the models of a test elsewhere, never in the user's folder. Texts are recorded instead of pasted unless `--test-paste` is given. Windows takes `;` between the files.

## What was verified (09.10.2026): Handy's models

- **On the Mac, through the engine's own code in plain Node** (`dist/sherpa-worker.js`, scratch folder): each of the six models downloaded file by file and checked, then timed on `assets/speedtest.wav` (seconds per 10 s of speech on an M5 Pro, four threads): Moonshine Tiny 0.08, SenseVoice 0.10 (the original export; the 2025-09-09 one, a Cantonese fine-tune, wrote English in garbled capitals), Moonshine Base 0.14, Parakeet V2 0.22, Parakeet V3 0.25, Canary 0.38. Parakeet V3 wrote a 41 s German clip (`say -v Anna`) almost word for word; Canary nearly so, after the spaces before its punctuation are taken out. Silence gave nothing. Cancel left no file.
- **In the Ubuntu VM, the packaged arm64 tar.gz:** Moonshine Tiny downloaded through `local-download`, its speed test ran (0.24 s per 10 s on 4 VM cores), and a 28 s English dictation from `--test-audio` came back in 1.3 s. Cancel through `local-cancel` removed the half-downloaded folder.
- Not verified: Windows x64 and Linux x64 with sherpa-onnx (no VM; the packages were checked to carry the right native files).

## What was verified (04.10.2026)

In a Windows 11 ARM VM and an Ubuntu 26.04 ARM VM (GNOME on Wayland), with real key presses and clicks sent into the VMs and real MAI-Transcribe calls:

- **Shortcut:** real right-Ctrl taps start and finish a dictation. Escape discards while recording. Ctrl+C with the right Ctrl does not trigger.
- **Card:** the mic button pauses and continues, the eye hides and shows the text, × discards and Undo brings it back. The card stops at the screen edge and remembers where it was put.
- **Paste:** the text goes into Notepad (Windows) and into GNOME Text Editor through ydotool. Without ydotool it falls back to the clipboard. The clipboard is handed back afterwards, or keeps the text when "Keep text on the clipboard" is on (checked both ways in the Ubuntu VM, 05.10.).
- **Start at login:** satz starts by itself after signing in, on both. Settings save. "No microphone" is said plainly.

Not verified: a real microphone (the VMs have none; test mode feeds files into the same path), and the x64 builds, which have no VM. On ARM Linux under X11 the keyboard library's prebuilt binary is actually x86-64 (an upstream packaging error); satz then starts without the hook and uses `satz --toggle`.

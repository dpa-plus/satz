# satz for Windows and Linux

The Mac app's dictation for Windows and Linux, on Electron: tap **right Ctrl twice**, talk, tap it twice again, and the text lands where you were typing. Same card (pause, eye, discard with Undo, click in the text to move where speech goes), same transcription (MAI-Transcribe 2 through OpenRouter or straight from Microsoft, clean mode, word list, Ersetzungen).

## Install

| System | File | How |
|---|---|---|
| Windows (ARM or Intel/AMD) | `satz-windows-arm64.zip` / `satz-windows-x64.zip` | Unzip anywhere, run `satz.exe`. Not signed yet, so SmartScreen may ask once ("More info", "Run anyway"). |
| Ubuntu / Debian | `satz-linux-arm64.deb` / `satz-linux-amd64.deb` | `sudo apt install ./satz-linux-…deb`, then start "satz" from the app menu. |
| Other Linux | `satz-linux-arm64.tar.gz` / `satz-linux-x64.tar.gz` | Unpack, run `./satz`. |

On first start satz opens its settings for the API key, and switches on start at login (it can be switched off there).

## Providers

Settings has one menu for them. Choosing one in it only shows it (key, models, fields); dictations keep going to the one marked "(in use)" until *… benutzen* in the row under the menu, which appears once the provider has what it needs: a key, for Microsoft a region (or an address of its own), for Custom also an address and a model, for Local a model on the computer (`src/core/browse.ts`, the same rule as the Mac's `ProviderReadiness`). Each provider keeps its own key (a file in `keys/` readable only by the user, never printed or logged) and its own model.

| Provider | Request | Models (price per hour of speech) |
|---|---|---|
| OpenRouter | `POST /api/v1/audio/transcriptions`, JSON | the provider's list: MAI-Transcribe 2 (0.10 $, the default) and others |
| OpenAI, Groq | `POST /audio/transcriptions`, multipart | their transcription models |
| Microsoft | `POST https://{region}.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15`, multipart with `audio` (the WAV) and `definition` (JSON), key in `Ocp-Apim-Subscription-Key` | **MAI-Transcribe 2** (0.10 $ until 31.12.2026, then 0.36 $; `enhancedMode` with the model named) and **Azure Speech** (0.36 $; the same request without `enhancedMode`) |
| Google | `POST https://generativelanguage.googleapis.com/v1beta/interactions`, JSON with the WAV inline as base64, key in `x-goog-api-key` | **Gemini 3.5 Transcribe** (about 0.30 $) |
| Custom | `POST {address}/audio/transcriptions`, multipart | the model typed in |
| Local | none: runs on this computer | see below |

**Microsoft** needs the key of an Azure *Speech* resource (Standard, S0) and its region, which Settings offers as a menu of the six that run MAI-Transcribe: North Europe (the default, in the EU), East US, West US, West US 2, Central India, Southeast Asia. A key only works in the region of its own resource, so a 401 reads "Schlüssel oder Region falsch". *Own address* (`https://<name>.cognitiveservices.azure.com`) wins over the region when it is filled in; it follows the rule for addresses below. "Füllwörter weglassen" is `transcribeStyle` `clean` (on) or `verbatim` (off) for MAI-Transcribe 2. The word list and the replacements' trigger phrases go into `definition.phraseList`. No `locales`: German and English are told apart by Microsoft itself.

**Google** needs a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey). "Füllwörter weglassen" is `mode: "smart"`; without it the text is verbatim. The word list is `custom_vocabulary` (at most 1000). The audio travels inline, and a request may be 20 MB in all: a recording of more than about 7.8 minutes fails at once as "too long" and is never sent. With a free-tier key Google may use the audio to improve its products; the model's facts line says so, and that switching billing on avoids it.

**Addresses, redirects and time.** The key travels with the audio, so Custom's address and Microsoft's own address must be https, or http on the user's own network: this computer (`localhost`, `127.0.0.0/8`, `[::1]`), a private or link-local address (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `fc00::/7`, `fe80::/10`), a name without a dot (`nas`), or a name ending in `.local`, `.lan`, `.home.arpa` or `.internal`. Anything else is refused, and Settings says so ("Diese Adresse geht nicht: https, oder http nur im eigenen Netz.") instead of asking for an address that is already there. The table is `src/core/address.ts`, the same as the Mac's `ProviderAddress`. A redirect is followed when it stays on the origin the request began at (three at most, with the same headers and audio), and refused when it leaves it ("Adresse leitet um"), so a key never goes to a second address. Electron's `net.fetch` cannot be asked for that (with `redirect: 'manual'` it cancels the request, left alone it forwards `Authorization` to the other origin), so requests that carry a key go through `net.request` (`src/main/manualFetch.ts`; `src/core/redirect.ts` decides). A request may take the base timeout (30 s) plus a second for every two seconds of audio, upload and answer together, so five minutes of speech get 180 s; the Mac allows the same.

Both requests, their answers and their errors were written from the documentation and tested against a stand-in server on this computer (`test/providers.test.ts`: exact address, headers and body; the documented answers; 401, 429, 413 and the rest). **The real services were not called: there was no key.** The Google answer parser takes every shape the documentation shows (`steps[].content[]` text, `output_text`, `candidates[].content.parts[]`) because the documentation disagrees with itself about which one the endpoint returns.

## Without the internet

Provider **Local** runs speech recognition on the computer itself, on the CPU, through two engines: Whisper on transformers.js and ONNX Runtime, and [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (Apache-2.0) for the models [Handy](https://github.com/cjpais/Handy) offers and four newer ones. Settings shows them the way Handy does: **Your models** (on this computer, the one in use first) and **Available models**, one card each with a sentence on what it is good at, an accuracy bar and a speed bar, its languages and its size. Click an available card to download it (one at a time, with progress and Cancel); click one of yours to use it; *Delete* moves it to the Trash. The catalog is `src/core/localModels.ts`:

| Model | Engine | Size | Languages |
|---|---|---|---|
| Whisper Large v3 Turbo (the default) | Whisper | 981 MB | German and English |
| **Cohere Transcribe** | sherpa-onnx | 2.9 GB | 14 languages, told which like Canary (German and English first) |
| Whisper Large v3 | Whisper | 1.4 GB | German and English |
| **Canary 1B v2** | sherpa-onnx | 1.4 GB | English, German, Spanish, French: told which like the small Canary |
| Parakeet V3 | sherpa-onnx | 670 MB | 25 European languages, found by itself |
| Whisper Medium | Whisper | 786 MB | German and English |
| Canary 180M Flash | sherpa-onnx | 207 MB | English, German, Spanish, French: told which under its own "Spoken in", apart from the app's German or English |
| **Qwen3-ASR 0.6B** | sherpa-onnx | 987 MB | 30 languages, found by itself |
| Whisper Small, Base, Tiny | Whisper | 328, 149, 99 MB | German and English |
| **Parakeet V3 German** (primeLine) | sherpa-onnx | 671 MB | German only |
| Whisper Large v3 Turbo German (primeLine) | Whisper | 983 MB | German only |
| Parakeet V2 | sherpa-onnx | 661 MB | English only |
| Distil-Whisper Large v3.5 | Whisper | 950 MB | English only |
| Moonshine Base, Moonshine Tiny | sherpa-onnx | 287, 124 MB | English only |
| SenseVoice | sherpa-onnx | 240 MB | Chinese, English, Japanese, Korean, Cantonese |

The four in bold came on 10.10.2026 and are only offered, never downloaded for the user. **Cohere Transcribe** is the most accurate model in German on the Open ASR Leaderboard (3.3 % errors on FLEURS, 2.9 % on Common Voice), 2 billion parameters, Apache-2.0. The three others are Canary 1B v2 (3.4 % on FLEURS, a community export), Qwen3-ASR 0.6B (5.4 %, small, takes the word list as hints) and a German fine-tune of Parakeet V3 (it writes "ss" where German has "ß", as its Swiss-leaning training data does). Their repos are not csukuangfj's: `csukuangfj2` (sherpa-onnx's newer builds), `Sarphix` and `x-ian` (community exports), so the catalog names the Hugging Face owner per model (`owner` in `SherpaSource`).

The accuracy bar is Handy's score for the model (an estimate, for the German fine-tune); its help gives the German error rate on FLEURS where one is published, with the source named: the Open ASR Leaderboard's file (fetched once a day, or the shipped numbers) or the Whisper paper. The speed bar comes from satz's own speed test once the model was measured on this computer (seconds per 10 s of speech on a log scale: 0.2 s fills it, 1 s is 70 %, 3 s 40 %, 10 s 10 %), and from Handy's score until then. The test runs on a bundled 10 s clip (`assets/speedtest.wav`) right after a download, twice through the dictation path, the second run counts, and only once no dictation is under way (`src/main/speedTests.ts`); the result is kept as `<id>.speed.json`.

Models are downloaded once from Hugging Face into satz's own folder, beside the model in use, which stays loaded: Whisper's from the onnx-community repos, sherpa-onnx's file by file from the owner's repo named in the catalog ([csukuangfj](https://huggingface.co/csukuangfj) for Handy's models) at a fixed commit, each file checked against its SHA-256 and named only once complete (one left from an earlier try is kept only if its checksum is right), into `<models>/sherpa/<name>/`. A marker beside the folder is written only when the model has also loaded once. A download becomes Local's model by itself only when the model in use is not on the computer, and never switches the provider. Choosing a provider in the menu only shows it: dictations keep going to the one marked "(in use)" until *Use …* in the row under the menu, or a click on one of your models while Local is shown.

Whisper finds the language itself per recording, between German and English; the two single-language models always decode in theirs. The word list goes in as Whisper's prompt only where it costs no words (satz decodes with and without it and keeps the prompted text only if it is as long). The sherpa-onnx models take no prompt (the replacements still apply), except Qwen3-ASR: it takes the word list as hotwords (a comma-separated string in front of the audio, at most 24 words), decoded the same way, with and without, and kept only if no words were lost. Canary and Cohere Transcribe cannot tell the language: while one is the model in use, a "Spoken in" row under the cards offers the languages it writes (Canary four, Cohere fourteen), kept apart from the app's own German or English (Whisper and the replacements go by that one). Canary is configured with the language; Cohere is told it for every piece through a stream option (`stream.setOption('language', …)`), so changing it reloads nothing. Parakeet takes a whole dictation; Moonshine, SenseVoice, Canary and Cohere get it in pieces of at most 30 s (Cohere's limit is 35 s), cut at the quietest moment (`src/core/windows.ts`), as Whisper does. Qwen3-ASR's decoder holds 512 tokens for the prompt, 13 a second of audio and the text, so its pieces are 15 s: a 40 s piece came back as the single word "language". Silence is never sent to any of them, and every piece must have speech in it by its own level (`src/core/speech.ts`). Cohere Transcribe also makes text up for noise: 12 s of steady hiss, louder than the -45 dBFS that counts as speech, came back as whole German sentences, repeated. So its pieces must also not be one steady level (`isSteady`: the louder frames of speech are 18 to 1500 times the quieter ones, a fan's 1.1 times; the others wrote nothing for the same hiss). On Windows on ARM there is no sherpa-onnx build, so its ten models are not offered there.

Each engine runs in a helper process of its own (`local-worker.js`, `sherpa-worker.js`): ONNX Runtime blocks the thread it runs on, and sherpa-onnx brings its own ONNX Runtime (1.28.2, beside onnxruntime-node's 1.30.0). On Windows both are `onnxruntime.dll`, and Windows hands a DLL that is already loaded to whoever asks for that name next, so in one process one engine would run on the other's runtime. A helper ends when Local's model moves to the other engine or another provider is chosen, which gives all its memory back. The Windows packages carry Microsoft's C++ runtime DLLs next to onnxruntime-node (`build/vcruntime.py` fetches them from Microsoft's redistributable); a fresh Windows has none. sherpa-onnx's Windows build needs none.

Licences of the models satz downloads (none ship with satz): Parakeet TDT 0.6B [v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and [Canary 180M Flash](https://huggingface.co/nvidia/canary-180m-flash) by NVIDIA, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); Moonshine [Base](https://huggingface.co/UsefulSensors/moonshine-base) and [Tiny](https://huggingface.co/UsefulSensors/moonshine-tiny) by Useful Sensors, MIT; [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) by FunAudioLLM (Alibaba), [FunASR model licence](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE), in its [sherpa-onnx export](https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17); Whisper by OpenAI, MIT; [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) by Cohere, Apache-2.0, in sherpa-onnx's [int8 export](https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01); [Qwen3-ASR 0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) by Alibaba's Qwen team, Apache-2.0, in sherpa-onnx's [int8 export](https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25); [Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2) by NVIDIA, CC BY 4.0, in [Sarphix's community int8 export](https://huggingface.co/Sarphix/canary-1b-v2-sherpa-onnx-int8) (CC BY 4.0, not an official release); [Parakeet primeLine](https://huggingface.co/primeline/parakeet-primeline) by primeLine, CC BY 4.0, in [x-ian's community int8 export](https://huggingface.co/x-ian/sherpa-onnx-parakeet-primeline-de-int8) (the repo's own licence field is empty).

## Paste and the clipboard

The text goes on the clipboard, Ctrl+V is sent to the window the dictation started in (brought back first if you went elsewhere meanwhile), and a second later the clipboard is handed back in every form it held, but only while it still holds just the transcript: something you copied meanwhile stays. A second, not less: a busy app (Word, a remote desktop, a VM) took Ctrl+V after the old clipboard was back and pasted that instead. Pastes that follow each other give back the clipboard from before all of them, unless you copied something in between: that is then the one that comes back (`src/main/clipboardHandback.ts`). Where no keystroke can be sent, or the window is gone, the text stays on the clipboard.

## Linux and Wayland

Wayland (Ubuntu's default) lets no app watch the keyboard or type into other apps. satz handles it like this:

- **Shortcut:** right Ctrl twice works when the user may read the keyboard devices: `sudo usermod -aG input $USER`, then sign out and in. Without that, make a keyboard shortcut in the system settings that runs `satz --toggle`.
- **Paste:** with [ydotool](https://github.com/ReimuNotMoe/ydotool) running (`ydotoold`), satz pastes by itself. Without it the text goes to the clipboard and the card says "On the clipboard · Ctrl+V".
- **Terminals:** Wayland shows satz no window at all, so it cannot tell a terminal from any other app and sends Ctrl+V, which GNOME Terminal, Console and the like do not take as paste. Nothing is lost: every dictation is in the history, and with *Keep text on the clipboard* switched on the text stays on the clipboard for Ctrl+Shift+V by hand. Under X11 satz knows the terminal and sends Ctrl+Shift+V itself.
- The card runs through XWayland, the only way a window can stay on top and choose where it sits. The `satz` start script takes care of that and of Chromium's sandbox (see `build/after-pack.cjs`).

### Tools satz calls on Linux

Besides the libraries the `.deb` depends on, satz runs a few small programs. Each is optional; without it one thing is missing, never the dictation.

| Program | Package (Debian, Ubuntu) | What it is for |
|---|---|---|
| `xprop` | `x11-utils` | X11 only. The window a dictation started in, and whether it is a terminal (Ctrl+Shift+V). Without it every window gets Ctrl+V, and terminals take nothing. |
| `xdotool` or `wmctrl` | `xdotool`, `wmctrl` | X11 only. Brings that window back when you clicked into another one while talking. Without either, the text goes to the clipboard ("the window is gone") instead of being pasted. |
| `gdbus` | `libglib2.0-bin` | Pauses music and videos while you dictate (MPRIS over D-Bus). Without it the setting does nothing. |
| `ydotool` and `ydotoold` | `ydotool` | Wayland only. Sends Ctrl+V. See above. |

The `.deb` recommends `x11-utils` and `xdotool`, so `apt install` brings them unless recommends are switched off; `xprop` and `gdbus` usually are on a desktop install already. The tar.gz brings nothing: install them yourself.

### When the shortcut is missing

On ARM Linux under X11 the keyboard library's prebuilt binary is x86-64, so satz starts without the hook (and a blocked native module on Windows does the same). Settings then says so under *Shortcut*, in the language of the app, and names the way out: a keyboard shortcut that runs `satz --toggle` (system settings on Linux, a shortcut with a shortcut key on Windows).

## Build

```bash
npm install
npm test               # the shared core, ported from the Mac app, the local engines and the app's own parts
npm run dist:win       # release/*.zip
npm run dist:linux     # release/*.deb, *.tar.gz
```

Everything builds on a Mac. The helper processes and the main process are esbuild bundles (transformers.js is inside `local-worker.js`), so a package carries only what is loaded from beside them: `onnxruntime-node`, `uiohook-napi` and sherpa-onnx. `package.json`'s `files` leaves out the rest of transformers.js' dependencies (`onnxruntime-web`, `sharp` with its macOS libraries and the like, tens of MB in a package), and `build/after-pack.cjs` keeps one ONNX Runtime and one keyboard-hook library per package. `test/appFix.test.ts` checks that the Whisper bundle still asks for nothing else. On Windows `signExecutable: false` only skips signing: electron-builder still writes satz's name, version, company and icon into `satz.exe`. `npm start` runs it locally. npm installs sherpa-onnx's native code only for the Mac that builds (`sherpa-onnx-darwin-arm64`, kept out of the packages); `build/after-pack.cjs` puts each package's own, `sherpa-onnx-linux-x64`, `-linux-arm64` or `-win-x64`, at the version and checksum `package-lock.json` names (cached in `build/sherpa/`), beside `app.asar` in `resources/app.asar.unpacked/node_modules/`, where `src/main/sherpaEngine.ts` loads it. That adds 8 to 13 MB to a download (23 to 40 MB unpacked); the Windows ARM zip gets nothing.

## Test mode

`satz --dev-control 48700 --test-audio a.wav:b.wav` plays WAV files instead of the microphone and takes commands on `http://127.0.0.1:48700/<command>`: `press`, `release`, `mic`, `discard`, `undo`, `restore`, `eye`, `caret?at=N`, `state`, `picture`, `js?code=…`, `local`, `local-download`, `local-cancel` and `local-measure` (a local model's state, its Download, its Cancel and its speed test; `?id=…` names the model, e.g. `sherpa/moonshine-tiny`, else the one in use; set `"provider": "local"` in preferences.json to dictate with it). `--models-dir <folder>` keeps the models of a test elsewhere, never in the user's folder; it needs `--dev-control` (alone, satz exits at once rather than run as a normal satz on a folder of its own). Without it a test copy uses the user's models but never downloads into or deletes from that folder; the dev-control commands `local-download` and the Settings buttons log that and do nothing. Texts are recorded instead of pasted unless `--test-paste` is given, and a test never pauses the music unless `--test-media` is given. A test writes its history to the profile it runs in, so run it with Electron's `--user-data-dir <folder>` on a computer where that matters. Windows takes `;` between the files.

## What was verified (10.10.2026): Microsoft, Google and four more local models

- **Microsoft and Google, against a stand-in server only.** `test/providers.test.ts` runs the real request code against a server on 127.0.0.1 that checks the exact address, headers and body (Microsoft's multipart `audio` and `definition` parts parsed back from the wire, Google's JSON and base64 audio), answers with the documented shapes, and answers 401, 403, 413, 429, 400 "too long" and 500 to see how each is named. **The real services were not called: there was no Microsoft or Google key.** What is untested is whether they accept these requests and what they really answer.
- **The four local models, through the engine's own code in plain Node** (`dist/sherpa-worker.js`, a scratch models folder, never satz's own): each downloaded file by file at its pinned commit with every SHA-256 checked, loaded in sherpa-onnx-node 1.13.8, timed on `assets/speedtest.wav` (seconds per 10 s of speech on an M5 Pro, four threads) and run on German clips made with `say -v Anna` (9.8 s, 6.3 s with word list, 40 s in pieces, 0.8 s), on silence and on 12 s of steady noise at -45 and -32 dBFS.

| Model | Speed test | German clips | Noise |
|---|---|---|---|
| Parakeet V3 German | 0.21 s | word for word, numbers as digits; writes "ss" for "ß" ("Lindenstrasse") | nothing |
| Qwen3-ASR 0.6B | 1.51 s | right, numbers as words; a few wrong words in the 40 s clip ("beantragt" for "beantwortet"); "Immofanten" came out right in the clip with the word list (not compared without it) | nothing |
| Canary 1B v2 | 1.01 s | all but one word ("schickt" for "schick"), "4.500 Euro" | nothing |
| Cohere Transcribe | 0.58 s | word for word, the best of the four; "Emophanten" for a made-up name (no word list) | whole made-up sentences, until `isSteady` (below) |

- **Cohere Transcribe makes text up for steady noise** that is louder than the -45 dBFS `hasSpeech` takes for speech ("Ich bin jetzt nicht mehr so gut." seven times for a 12 s fan). The three others wrote nothing for the same noise. Cohere's pieces must now also not be one steady level (`isSteady`): speech was 18 to 1500 times, the noise 1.1 times, with the threshold at 2. After that it sent nothing for the same clips (1 ms), and the German clips were unchanged. Noise that is not steady (a door, a cough) can still get a made-up sentence from it.
- **Qwen3-ASR's decoder holds 512 tokens** for the prompt, 13 per second of audio and the text. A 40 s piece came back as the single word "language" (sherpa-onnx logged the truncation and carried on); 30 s leaves about 100 tokens for the text, too little for German at a normal pace; so its pieces are 15 s.
- **Cohere's encoder weights** (`encoder.int8.onnx.data`, 2.7 GB) are a second file named in the encoder: they are downloaded and checked like the rest, and the model loaded with them beside the encoder.
- Not verified: the Windows x64 and Linux x64 packages with these models (no VM; the code is the same engine that ran Handy's models there), the packaged app with the new IPC channel `settings:open-key-page` (`main.ts` is out of the unit tests: start the packaged app once in the Ubuntu VM), memory on a small computer (the four took 2.5 to 5.4 GB of resident memory in the harness, Cohere the most), and the models' speed on slower processors.

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

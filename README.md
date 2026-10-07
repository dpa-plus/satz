<div align="center">

<img src="assets/hero.png" alt="satz: a sound wave flowing into a text field, where the dictated sentence appears." width="100%">

### Tap a key twice, talk, and your words appear where you were typing.<br>In every app, on Mac, Windows and Linux.

[![Download for Mac](https://img.shields.io/badge/Download-macOS-16303c?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/dpa-plus/satz/releases/latest/download/satz-mac.zip)
[![Download for Windows](https://img.shields.io/badge/Download-Windows-16303c?style=for-the-badge&logo=windows&logoColor=white)](#download)
[![Download for Linux](https://img.shields.io/badge/Download-Linux-16303c?style=for-the-badge&logo=linux&logoColor=white)](#download)

[![Latest release](https://img.shields.io/github/v/release/dpa-plus/satz?color=ff6100&label=release)](https://github.com/dpa-plus/satz/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-ff6100)](LICENSE)

</div>

<br>

<p align="center">
  <img src="assets/showcase.png" alt="The satz card while talking, with the sentence so far and a live waveform, and the menu with the last dictations." width="90%">
</p>

## Why satz

Most dictation apps want something from you first: an account, a subscription, or a second AI that rewrites what you said. satz does one thing. It records you, turns the audio into text with the model you pick, and types the result where your cursor is. The model runs at a transcription service, or, if you prefer, on your own computer.

- **Works everywhere you type.** Mail, Slack, your editor, a chat with an AI. If it has a text cursor, satz can fill it.
- **Very accurate, very cheap.** By default it uses Microsoft's MAI-Transcribe 2 through OpenRouter: 2.0% word errors on Artificial Analysis (September 2026), against 3.3% for OpenAI's GPT Transcribe, at a third of the price. You pay the provider directly, for what you use.
- **Your words, not a rewrite.** No second model polishes your sentences. Clean mode only drops the "uhm"s and stutters.
- **See it while you talk.** A small card shows your text as you go. Click into it to change where the next words land, pause to think, or throw it away and undo.
- **Nothing to set up on a server.** No account, no telemetry. Your key stays on your computer.
- **Offline if you want.** Provider *Local* runs Whisper on your own computer: a one-time download, then free, and nothing leaves the machine.

## Download

| System | File | |
|---|---|---|
| **macOS 14 or newer** (Apple chip and Intel) | [satz-mac.zip](https://github.com/dpa-plus/satz/releases/latest/download/satz-mac.zip) | Unzip, drag satz into Applications |
| **Windows** (Intel and AMD) | [satz-windows-x64.zip](https://github.com/dpa-plus/satz/releases/latest/download/satz-windows-x64.zip) | Unzip anywhere, run `satz.exe` |
| **Windows 11 on ARM** | [satz-windows-arm64.zip](https://github.com/dpa-plus/satz/releases/latest/download/satz-windows-arm64.zip) | Unzip anywhere, run `satz.exe` |
| **Ubuntu, Debian** (x64) | [satz-linux-amd64.deb](https://github.com/dpa-plus/satz/releases/latest/download/satz-linux-amd64.deb) | `sudo apt install ./satz-linux-amd64.deb` |
| **Ubuntu, Debian** (ARM) | [satz-linux-arm64.deb](https://github.com/dpa-plus/satz/releases/latest/download/satz-linux-arm64.deb) | `sudo apt install ./satz-linux-arm64.deb` |
| **Other Linux** | [x64](https://github.com/dpa-plus/satz/releases/latest/download/satz-linux-x64.tar.gz) · [ARM](https://github.com/dpa-plus/satz/releases/latest/download/satz-linux-arm64.tar.gz) | Unpack, run `./satz` |

All files are on the [releases page](https://github.com/dpa-plus/satz/releases/latest).

**The first start asks once.** satz is not yet signed with a paid Apple or Microsoft certificate, so your computer asks before opening it the first time:

- **Mac:** open satz and close the warning, then go to *System Settings → Privacy & Security* and click *Open Anyway*.
- **Windows:** SmartScreen says it protected your PC. Click *More info*, then *Run anyway*.

## Get started

1. **Get a key.** Create one at [openrouter.ai/keys](https://openrouter.ai/keys) and add a few dollars of credit. With MAI-Transcribe 2 an hour of talking costs about 10 cents, so five dollars lasts a long time. OpenAI and Groq keys work too.
2. **Open satz.** Setup asks for the key, the microphone, and on the Mac for permission to paste. It ends with a test sentence.
3. **Dictate.** Click into any text field and tap the shortcut twice:

| | Start and finish | Throw away |
|---|---|---|
| Mac | right **⌘** twice | **Esc** |
| Windows, Linux | right **Ctrl** twice | **Esc** |

Talk, tap twice again, and the text is pasted. satz starts by itself when you log in; you can switch that off in Settings.

## What you can do

**While you talk**
- **Pause** with the microphone button to think. Your text appears at each pause.
- **Click anywhere in the text** and what you say next goes there. You can also type by hand.
- **Hide the text** with the eye if you only want the small waveform.
- **Throw it away** with ×, then *Undo* for a few seconds, or *Restore* from the menu bar after that.
- **Move the card** anywhere. It stays where you put it and never leaves the screen.
- **Music pauses by itself** while you talk (Spotify, Apple Music, YouTube in the browser, anything the system lists as playing) and plays on when you are done. Only what was playing, and only what satz paused.

**Find it again**
- **Open satz** from Applications, Spotlight or the Start menu and you get its window: **History** and **Settings**, one click (or ⌘1 / ⌘2) apart. History has everything you dictated, by day, with search. A click copies, × forgets one.
- **Keep** the last 10, 50, 200 or all of them, or none. The menu bar shows the last four.
- **Insert** (Mac): the button next to *Copy* in the menu bar puts your latest text into the text field you are in. It only works while a text field has the cursor.

**In Settings**
- **Vocabulary:** names and terms the model should spell your way ("Kubernetes", your colleague's name).
- **Replacements:** say "open bracket" and get `(`, say "new line" for a line break. Add your own trigger words.
- **Spoken in:** German or English, separately from the app's language.
- **Shortcut:** tap to start and stop, or hold while you talk. On the Mac also your own key combination or a mouse button.
- **Keep text on the clipboard:** off by default, so whatever you had copied comes back after pasting. On, the dictated text stays there to paste again.
- **Look:** four colours, light and dark, Liquid Glass on macOS 26.

## Built not to lose your words

| What goes wrong in other apps | What satz does |
|---|---|
| The last word gets clipped | The microphone stays open 400 ms after you stop |
| Cut-up audio garbles words | satz never cuts your recording; the model always hears the whole thing |
| It spins forever | Every request has a time limit; a failure stays on the card with *Retry* |
| A dropped connection loses your speech | The audio is kept until it has been sent |
| The paste silently fails | It says so and leaves the text on the clipboard |
| It pastes into the wrong app | The text goes back to the app you started in |
| It eats your clipboard | What you had copied is put back after pasting |

## Providers and models

| Provider | Default model | Notes |
|---|---|---|
| **OpenRouter** (recommended) | Microsoft MAI-Transcribe 2 | One key, every speech model OpenRouter has |
| OpenAI | GPT Transcribe | Also GPT-4o (mini) Transcribe, Whisper |
| Groq | Whisper Large v3 Turbo | Very fast |
| Custom | your URL and model | Any OpenAI-compatible endpoint |
| Local | Whisper Large v3 Turbo | On your own computer, no key, see below |

The model menu is the provider's **live list**, so new models show up without a new satz. Next to each: how many words it gets wrong, from [Artificial Analysis](https://artificialanalysis.ai/speech-to-text)' word error rate (the same ~8 hours of speech for every model, lower is better), and what an hour of talking costs. The best come first. Prices as satz measured them in October 2026:

| Model | Wrong words | per hour |
|---|---|---|
| Microsoft MAI-Transcribe 2 (default, clean mode, uses your vocabulary) | 2.0 % | $0.10 |
| Microsoft MAI-Transcribe 1.5 | 2.4 % | $0.36 |
| Mistral Voxtral Small | 2.8 % | $0.18 |
| OpenAI GPT Transcribe | 3.3 % | $0.28 |
| Mistral Voxtral Mini 3B | 3.8 % | $0.06 |
| OpenAI GPT-4o Transcribe | 4.0 % | $0.23 |
| xAI Grok STT | 4.0 % | $0.10 |
| OpenAI Whisper | 4.1 % | $0.37 |
| Google Chirp 3 | 4.3 % | $1.00 |
| OpenAI GPT-4o mini Transcribe | 4.5 % | $0.12 |
| OpenAI Whisper Large v3 Turbo | 4.6 % | $0.01 |
| Qwen3 ASR, Voxtral Mini Transcribe, Universal-3.5 Pro, Whisper Large v3, Fish Audio | not measured | $0.01 to $0.44 |

A few models OpenRouter lists are left out because they fail with dictation (no German, speaker tags in the text, refused requests). "Other model" takes any model id by hand. Each provider keeps its own key and model, so you can switch back and forth.

**On your own computer.** Choose *Local* and press *Download* once:

| | Mac | Windows and Linux |
|---|---|---|
| Whisper Large v3 Turbo | 632 MB, via WhisperKit on the Neural Engine. About 1 s for a short dictation. | 980 MB, on the processor. About 1 to 4 s, depending on the computer. |
| Apple's speech recognition | Built into macOS 26, nothing to download. Instant, but hears only the language set in *Spoken in* and barely uses your vocabulary. | |

Whisper tells German from English by itself. The first time after the download, the Mac prepares the model for its chip, which takes a few minutes, once. Your vocabulary is given to Whisper as a hint, but only when it costs no words: with one, Whisper sometimes left out a sentence in another language, so satz checks against the text without it. *Remove* puts the model in the Trash.

**Speed.** MAI-Transcribe usually answers in one or two seconds, but now and then a request hangs for ten. When no answer has come after 2.5 seconds, satz asks a second time and takes whichever answer comes first, for a fraction of a cent.

## Your key and your data

- Your audio goes straight from your computer to the provider you chose. There is no satz server. With *Local*, it never leaves your computer.
- The key is stored on your computer only: on the Mac in `~/Library/Application Support/satz/keys`, readable only by your user. satz never shows it again after you save it.
- The history keeps the last few dictations, in a file only you can read. *Clear* in Settings deletes it.

## Questions

**Is it free?** satz is free and open source (MIT). You pay the transcription provider for what you use: about 10 cents per hour of talking with MAI-Transcribe 2 on OpenRouter. With *Local* it costs nothing at all.

**Does it work offline?** With the provider *Local*, yes: Whisper runs on your computer after a one-time download. The other providers need the internet.

**Which languages?** Whatever the model understands. MAI-Transcribe 2 and Whisper handle dozens. The app itself is in English and German.

**Linux with Wayland?** Wayland does not let apps watch the keyboard or type into other apps. satz still works: see [the notes for Linux](desktop/README.md#linux-and-wayland).

<details>
<summary><b>Build it yourself</b></summary>

<br>

**Mac** (Swift 6, Xcode command line tools):

    make app                     build dist/satz.app
    make run                     build and launch
    make share                   universal build zipped as dist/satz.zip
    make test                    run the tests, offline

**Windows and Linux** (Electron, builds on a Mac too): see [desktop/README.md](desktop/README.md).

    cd desktop && npm install
    npm test
    npm run dist:win             release/*.zip
    npm run dist:linux           release/*.deb, *.tar.gz

**Layout**

    Sources/SatzKit    audio, WAV, transcription client, replacements, keys
    Sources/SatzMac    the Mac app: shortcut, card, paste, menu, settings, setup
    Tests/             tests for SatzKit
    desktop/           the Windows and Linux app, sharing the same core in TypeScript

**Test mode** drives a real dictation without a microphone or keyboard, and never pastes into the app you are using:

    satz --test-audio a.wav:b.wav --dev-control /tmp/state.json

Commands arrive as distributed notifications named `plus.dpa.satz.dev` (`press`, `mic`, `caret:<index>`, `discard`, `undo`, `dump`, `picture`, `settings`, `close`). The finished text goes to the state file.

    satz --snapshot <dir>        every surface as PNGs, light and dark
    make hero / make showcase    the pictures in this README

Live tests talk to a real endpoint and are skipped without a key:

    SATZ_TEST_API_KEY=... SATZ_TEST_BASE_URL=https://openrouter.ai/api/v1 make test

</details>

## Licence

MIT. See [LICENSE](LICENSE). Made by [DPA Plus](https://dpa.plus).

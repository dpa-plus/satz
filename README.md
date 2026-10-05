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

Most dictation apps want something from you first: a big local model to download, an account, or a second AI that rewrites what you said. satz does one thing. It records you, sends the audio to a transcription service you pick, and types the result where your cursor is.

- **Works everywhere you type.** Mail, Slack, your editor, a chat with an AI. If it has a text cursor, satz can fill it.
- **Very accurate, very cheap.** By default it uses Microsoft's MAI-Transcribe 2 through OpenRouter: 2.0% word errors on Artificial Analysis (September 2026), against 3.3% for OpenAI's GPT Transcribe, at a third of the price. You pay the provider directly, for what you use.
- **Your words, not a rewrite.** No second model polishes your sentences. Clean mode only drops the "uhm"s and stutters.
- **See it while you talk.** A small card shows your text as you go. Click into it to change where the next words land, pause to think, or throw it away and undo.
- **Nothing to set up on a server.** No account, no telemetry. Your key stays on your computer.

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

1. **Get a key.** Create one at [openrouter.ai/keys](https://openrouter.ai/keys) and add a few dollars of credit. Five dollars lasts a long time. OpenAI and Groq keys work too.
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

**In Settings**
- **Vocabulary:** names and terms the model should spell your way ("Kubernetes", your colleague's name).
- **Replacements:** say "open bracket" and get `(`, say "new line" for a line break. Add your own trigger words.
- **Spoken in:** German or English, separately from the app's language.
- **Shortcut:** tap to start and stop, or hold while you talk. On the Mac also your own key combination or a mouse button.
- **Keep text on the clipboard:** off by default, so whatever you had copied comes back after pasting. On, the dictated text stays there to paste again.
- **History:** the last dictations in the menu bar, one click to copy.
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

## Providers

| Provider | Default model | Notes |
|---|---|---|
| **OpenRouter** (recommended) | `microsoft/mai-transcribe-2` | Clean mode, uses your vocabulary as a phrase list |
| OpenAI | `gpt-transcribe` | |
| Groq | `whisper-large-v3-turbo` | Very fast |
| Custom | your URL and model | Any OpenAI-compatible endpoint |

Each provider keeps its own key and model, so you can switch back and forth.

## Your key and your data

- Your audio goes straight from your computer to the provider you chose. There is no satz server.
- The key is stored on your computer only: on the Mac in `~/Library/Application Support/satz/keys`, readable only by your user. satz never shows it again after you save it.
- The history keeps the last few dictations, in a file only you can read. *Clear* in Settings deletes it.

## Questions

**Is it free?** satz is free and open source (MIT). You pay the transcription provider for what you use; an hour of talking costs well under a dollar.

**Does it work offline?** No. Transcription happens at the provider.

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

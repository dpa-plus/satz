<div align="center">

<img src="assets/hero.png" alt="satz, dictation for macOS: a sound wave flowing into the satz card, which shows the dictated text." width="100%">

[![License](https://img.shields.io/badge/license-MIT-ff6100)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-ff6100)](#requirements)
[![Swift](https://img.shields.io/badge/swift-6-ff6100)](Package.swift)

</div>

Dictation apps keep asking for things you did not want. One will only run a
local model and refuses to use an API at all. Another will not finish its setup
until you have configured a second language model to rewrite what you said.

satz does the one thing. Tap the right ⌘ key twice anywhere, talk, tap it
again. The recording goes to a transcription API of your choice, and the text
appears where your cursor was. Nothing is downloaded, nothing runs locally,
and no second model gets to reword you.

---

## Quick start

    make app
    open dist/satz.app

Setup walks you through five steps: your API key, the microphone, the
shortcut, permission to paste, and a test sentence. Steps already in place are
skipped.

## Dictating

A card appears at the bottom of the screen: your text on top, the controls
below. The controls never move while the text grows.

- **Your shortcut** starts, and pressed again finishes and pastes.
- **The microphone button** pauses so you can think. Your text appears at
  each pause.
- **Click anywhere in the text**, even while talking, and what you say next
  goes there. You can also type by hand.
- **The eye** hides the text if you only want the waveform.
- **×** throws it away, with *Rückgängig* for five seconds and *Zurückholen*
  in the menu bar after that.

satz never cuts your audio by itself. A sentence cut in half comes back with
wrong words, and short pieces lose their language: in tests one came back as
Dutch. Everything said into one spot is one recording; continuing at the same
spot sends the whole recording again, so the model always hears the full
context.

## Providers

| Provider | Default model | Request |
|---|---|---|
| OpenRouter | `microsoft/mai-transcribe-2` | JSON, audio inline |
| OpenAI | `gpt-transcribe` | multipart upload |
| Groq | `whisper-large-v3-turbo` | multipart upload |
| Eigener (custom) | your base URL and model | multipart upload |

MAI-Transcribe 2 had 2.0% word errors on Artificial Analysis in September
2026, against 3.3% for GPT Transcribe, at a third of the price. Through
OpenRouter it gets clean mode (no "ähm", no stutters; tested to keep every word
that carries meaning) and your Wortschatz as its phrase list. OpenRouter
ignores the `prompt` field, which is why it gets its own request format.

Each provider keeps its own key and model. Throttled requests are retried, as
long as the provider asks, up to five seconds.

## Ersetzungen

Transcription models write spoken punctuation out as words. satz turns them
into symbols after transcription: "Klammer auf" becomes `(`, "neue Zeile" a
line break, and the commas the model put around them are tidied away. Add your
own trigger words in Settings. Made-up words like "XX" work best: they never
come up in normal speech, and satz adds them to the model's phrase list so it
spells them the same way every time.

## What it does not do

- No local models. No downloads, no model manager.
- No cleanup pass by a second model. What you said is what you get.
- No account and no telemetry.

## Things it gets right

| Failure | What satz does |
|---|---|
| The last word gets clipped | The microphone stays open 400 ms after you stop |
| Cut audio garbles words | It never cuts on its own; see above |
| It spins forever | Every request is bounded; failures stay in the card with *Nochmal* |
| A dropped connection loses your speech | The audio is kept until it is sent |
| The paste silently fails | Without permission or under Secure Input it says so and leaves the text on the clipboard |
| It pastes into the wrong app | The text goes back to the app you started in |
| It eats your clipboard | The clipboard is put back after pasting |

## Your key

On the Mac, API keys live in `~/Library/Application Support/satz/keys`, one
file per provider, readable only by your user (0600 in a 0700 folder). Not the
Keychain, for now: without a signing certificate every new build looks like a
different app to the Keychain, which then asks for your password before satz
can read its own key. With a real certificate the Keychain is the better home.

## Layout

    Sources/SatzKit    audio capture, WAV, transcription client, Ersetzungen, keys
    Sources/SatzMac    the macOS app: shortcut, card, paste, menu, settings, setup
    Tests/             tests for SatzKit

`SatzKit` is separate so an iOS keyboard extension is additive rather than a
rewrite.

## Development

    make app                     build dist/satz.app
    make run                     build and launch
    make test                    run the tests, offline
    make hero                    regenerate assets/hero.png

    satz --snapshot <dir>        render every surface to PNGs, light and dark
    satz --import-key openrouter <file>
                                 store a key from a file without showing it

`--snapshot` never puts a window on screen and needs no permissions.

**Test mode** drives a real dictation without a microphone or keyboard:

    satz --test-audio a.wav:b.wav --dev-control /tmp/state.json

Each recording plays the next file in real time. Commands arrive as
distributed notifications named `plus.dpa.satz.dev` (`press`, `mic`,
`caret:<index>`, `discard`, `undo`, `dump`, `picture`). The finished text is
written to the state file instead of being pasted, so a test can never type
into the app you are using.

The live tests talk to a real endpoint and are skipped unless you supply a key:

    SATZ_TEST_API_KEY=... SATZ_TEST_BASE_URL=https://openrouter.ai/api/v1 make test

## Requirements

macOS 14 or newer, and an API key from one of the providers above. Xcode's
Swift 6 toolchain to build.

## Licence

MIT. See [LICENSE](LICENSE).

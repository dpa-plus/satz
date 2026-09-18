<div align="center">

<img src="assets/hero.png" alt="satz. Sprechen statt Tippen. Press a key, talk, let go. The text is where your cursor was." width="100%">

[![CI](https://github.com/dpa-plus/satz/actions/workflows/ci.yml/badge.svg)](https://github.com/dpa-plus/satz/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-ff6100)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-ff6100)](#requirements)
[![Swift](https://img.shields.io/badge/swift-6-ff6100)](Package.swift)

</div>

Dictation apps keep asking for things you did not want. One will only run a
local model and refuses to use an API at all. Another will not finish its setup
screen until you have configured a second language model to rewrite what you
said. Both download gigabytes before they will type a word.

satz does the one thing. Press Option+Space anywhere, talk, press it again. The
recording goes to OpenAI's `gpt-transcribe`, and the text appears where your
cursor already was. Nothing is downloaded, nothing runs locally, and no second
model gets to reword you.

---

## Quick start

    make app
    open dist/satz.app

Then, from the menu bar icon:

1. **OpenAI-Schlüssel …** and paste your key. It goes to the Keychain.
2. **Einfügen erlauben …** and grant Accessibility, which is what lets satz
   paste into other applications.

Press **Option+Space** to start, again to stop, **Escape** to throw it away.

## How it works

    microphone ──▶ 16 kHz mono WAV ──▶ gpt-transcribe ──▶ Command+V

That is the whole pipeline. One network request per dictation, bounded by a
timeout, with no second model in the path.

## What it does not do

- No local models. No downloads, no model manager, no gigabytes.
- No cleanup pass. What you said is what you get.
- No account. Your own API key, in your own Keychain.
- No telemetry.

## Things it gets right

These are the failures that make dictation tools annoying, and what satz does
about each:

| Failure | What satz does |
|---|---|
| The last word gets clipped | The microphone stays open 400 ms after you release |
| It spins forever | Every request is bounded and every failure shows on the pill |
| The paste silently fails | Secure Input and missing permissions fall back to the clipboard, and say so |
| Cancel still types | Cancel stops the upload; cancelled audio is never sent |
| It steals your focus | The pill can never become the key window |
| It pastes into the wrong app | The transcript returns to the app you were typing in |
| It eats your clipboard | The clipboard is put back after pasting |

## Layout

    Sources/SatzKit    audio capture, WAV, the transcription client, Keychain
    Sources/SatzMac    the macOS app: shortcut, pill, paste
    Tests/             tests for SatzKit

`SatzKit` is separate from day one so the planned iOS keyboard extension is
additive rather than a rewrite. On iOS there is no global shortcut and no way
to paste into another app, so a keyboard is the only shape that works, but the
recording and transcription halves are the same.

## Development

    make app                        build dist/satz.app
    make run                        build and launch
    make test                       run the tests, offline
    make hero                       regenerate assets/hero.png

    satz --snapshot out.png         render every pill state to a PNG and exit
    satz --demo                     show the pill driven by synthetic loudness

`--snapshot` is how the pill gets looked at. It never puts a window on screen,
needs no microphone and no screen recording permission, and captures all states
in one sheet rather than whichever one happens to be live.

The live tests talk to a real endpoint and are skipped unless you supply a key:

    SATZ_TEST_API_KEY=sk-... make test

## Requirements

macOS 14 or newer, and an OpenAI API key. Xcode's Swift 6 toolchain to build.

## Licence

MIT. See [LICENSE](LICENSE).

# satz

Speak, and the words land where your cursor is.

A macOS dictation app. Hold a hotkey, talk, release. The text appears in
whatever application you were already typing in. Transcription runs on
OpenAI's `gpt-transcribe` over the API. Nothing is downloaded, nothing runs
locally, and there is no second AI model rewriting what you said.

## Why this exists

The open source dictation apps either refuse to use an API model at all, or
they insist on a local model plus an LLM cleanup pass before they will let you
finish setup. This one does the single thing: voice in, text out.

## Plan

1. Repo skeleton: shared package plus the macOS target
2. The pill: floats above everything, bars move with your voice, never steals focus
3. Hotkey starts and stops it from any application
4. Upload, stream the text back, paste at the cursor
5. The safety net: tail buffer, timeouts, clipboard fallback, escape to cancel

## What to verify

- The pill appears on the hotkey and vanishes when you stop
- Focus never leaves the app you were typing in
- Text lands at the cursor, in that same app
- **The last sentence is never cut.** The microphone stays open briefly after
  you release, so trailing words survive
- **It never hangs.** Every request has a timeout, every failure shows on the pill
- **Paste has a fallback.** If macOS Secure Input blocks the paste, the text
  goes to the clipboard and the pill says so
- Escape cancels: nothing uploaded, nothing pasted
- The API key lives in the Keychain, never in a file and never in this repo
- Offline fails visibly

## Layout

    Sources/SatzKit    audio capture and the transcription client, shared with a future iOS keyboard
    Sources/SatzMac    the macOS app: hotkey, pill, paste
    Tests/             tests for SatzKit

The shared package exists from day one so the planned iOS keyboard extension is
additive rather than a rewrite.

## Language

Code, comments and this README are English. User-facing strings are German,
because the customers are.

## Build

    make app      build satz.app into dist/
    make run      build and launch it
    make test     run the tests

## Looking at the pill

    satz --snapshot out.png   render every pill state to a PNG and exit
    satz --demo               show the pill driven by synthetic loudness

`--snapshot` is the one to reach for. It never puts a window on screen, needs
no microphone and no screen recording permission, and it captures all three
states in one sheet instead of only whichever one happens to be live. It is
also where a visual check in CI would hook in.

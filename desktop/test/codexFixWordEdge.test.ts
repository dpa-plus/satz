import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { Doc } from '../src/core/doc'
import { Session, type AudioSource } from '../src/core/session'
import { settle } from './sessionHarness'

/**
 * Codex's bug hunt of 14 October 2026: F12, speech resumed between an accent
 * written as its own mark (NFD) and the next letter split the word, which the
 * same word written as one character (NFC) did not; and a transcript of about
 * 125,000 characters threw in Doc.replace and left the dictation "finishing"
 * for good. Each test fails on the code before the fix.
 */
const sessions: Session[] = []
afterEach(() => { for (const session of sessions.splice(0)) session.dispose() })

class Source implements AudioSource {
  sampleCount = 16
  async start() {}
  samples(from: number, to: number) { return new Float32Array(Math.max(0, to - from)).fill(0.1) }
  async finishSamples() { return this.samples(0, this.sampleCount) }
  cancel() {}
}

/** Each recording is answered with the next text. */
function session(transcripts: string[]) {
  const delivered: string[] = []
  const made = new Session({
    makeSource: () => new Source(),
    transcribe: async () => transcripts.shift() ?? '',
    replacements: () => [], missing: () => null, endpointMissing: () => false, triggerMode: () => 'tap',
    deliver: async text => { delivered.push(text); return { pasted: true } },
    hasSpeech: samples => samples.length > 0,
  })
  sessions.push(made)
  return { session: made, delivered }
}

/** Pause on `text`, click at `at`, resume and say "Neu.", finish. */
async function insertAt(text: string, at: number) {
  const { session: s, delivered } = session([text, 'Neu.'])
  s.press(); await settle()
  s.toggleMicrophone(); await settle()
  s.userMovedCaret(at)
  s.toggleMicrophone(); await settle()
  s.press(); await settle()
  return delivered[0]
}

test('F12: speech resumed after "é" written as e + U+0301 goes after the whole word, as with the composed é', async () => {
  const composed = 'Die Cafés sind offen.'
  const decomposed = composed.normalize('NFD')
  assert.notEqual(decomposed, composed)
  assert.equal(await insertAt(composed, composed.indexOf('s ')), 'Die Cafés Neu sind offen.')
  assert.equal((await insertAt(decomposed, decomposed.indexOf('s '))).normalize('NFC'), 'Die Cafés Neu sind offen.')
})

test('F12: a click between a letter and its combining accent also keeps the word whole', async () => {
  const decomposed = 'Die Cafés sind offen.'.normalize('NFD')
  const output = await insertAt(decomposed, decomposed.indexOf('́'))
  assert.equal(output.normalize('NFC'), 'Die Cafés Neu sind offen.')
})

test('F12: letters beyond U+FFFF count as letters, also their second half', async () => {
  const text = 'Die 𐐀𐐁𐐂 sind offen.'
  assert.equal(await insertAt(text, 'Die 𐐀𐐁'.length), 'Die 𐐀𐐁𐐂 Neu sind offen.')
})

test('F12: between two words nothing moves', async () => {
  const text = 'Die Cafés sind offen.'.normalize('NFD')
  assert.equal((await insertAt(text, text.indexOf(' sind') + 1)).normalize('NFC'), 'Die Cafés Neu sind offen.')
})

test('a transcript of 250,000 characters goes into the text, and a dictation of 150,000 is pasted', async () => {
  const doc = new Doc()
  doc.insert(0, 'x'.repeat(250_000), { seg: 1 })
  assert.equal(doc.length, 250_000)
  assert.deepEqual(doc.rangeOf('seg', 1), { location: 0, length: 250_000 })
  doc.replace({ location: 10, length: 249_980 }, 'abc', { mark: 2 })
  assert.equal(doc.text(), 'xxxxxxxxxxabcxxxxxxxxxx')
  assert.deepEqual(doc.rangeOf('mark', 2), { location: 10, length: 3 })
  assert.deepEqual(doc.rangeOf('seg', 1), { location: 0, length: 23 })

  const { session: s, delivered } = session(['word '.repeat(30_000)])
  s.press(); await settle()
  s.press(); await settle()
  assert.equal(s.phase.kind, 'idle')
  assert.equal(delivered[0], 'word '.repeat(30_000).trim())
})

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Session, type AudioSource } from '../src/core/session'
import { TranscriptionFailure } from '../src/core/transcriber'
import { setLanguage } from '../src/core/language'

setLanguage('en')

/**
 * Speech as numbers: every character of a script becomes K samples carrying
 * its character code, so a transcript can be read straight back out of the
 * audio. Doubled audio shows up as doubled letters, lost audio as missing ones.
 */
const K = 10
class FakeSource implements AudioSource {
  onLevel?: (level: number) => void
  revealed = 0
  cancelled = false
  private tail: (() => void) | null = null
  holdTail = false
  constructor(readonly script: string) {}
  async start() {}
  get sampleCount() { return this.revealed * K }
  /** The speaker says the next `chars` characters. */
  say(chars = this.script.length - this.revealed) { this.revealed = Math.min(this.script.length, this.revealed + chars) }
  samples(from: number, to: number) {
    const out = new Float32Array(Math.max(0, Math.min(to, this.sampleCount) - from))
    for (let i = 0; i < out.length; i++) out[i] = this.script.charCodeAt(Math.floor((from + i) / K)) / 1000
    return out
  }
  async finishSamples() {
    if (this.holdTail) await new Promise<void>(resolve => { this.tail = resolve })
    return this.cancelled ? null : this.samples(0, this.sampleCount)
  }
  endTail() { this.tail?.() }
  cancel() { this.cancelled = true }
}

const decode = (samples: Float32Array) => {
  let out = ''
  for (let i = Math.floor(K / 2); i < samples.length; i += K) out += String.fromCharCode(Math.round(samples[i] * 1000))
  return out.trim()
}

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function settle() { for (let i = 0; i < 8; i++) await tick() }

function setup(scripts: string[], options: { mode?: 'tap' | 'hold'; transcribe?: (s: Float32Array) => Promise<string> } = {}) {
  const sources: FakeSource[] = []
  const delivered: string[] = []
  let mode = options.mode ?? 'tap'
  const session = new Session({
    makeSource: () => { const s = new FakeSource(scripts[sources.length] ?? ''); sources.push(s); return s },
    transcribe: options.transcribe ?? (async samples => decode(samples)),
    replacements: () => [],
    hasKey: () => true,
    endpointMissing: () => false,
    triggerMode: () => mode,
    deliver: async text => { delivered.push(text); return { pasted: true } },
  })
  return { session, sources, delivered, setMode: (m: 'tap' | 'hold') => { mode = m } }
}

test('talk, finish, and the transcript is delivered', async () => {
  const { session, sources, delivered } = setup(['Hallo Welt'])
  session.press(); await settle()
  assert.equal(session.phase.kind, 'listening')
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(delivered, ['Hallo Welt'])
  assert.equal(session.phase.kind, 'idle')
  session.dispose()
})

test('a pause sends what was said, the second stretch follows it', async () => {
  // Going on at the same spot continues the same recording, sent whole at the end,
  // as on the Mac; real speech has the pause in it, the fake gets a space.
  const { session, sources, delivered } = setup(['eins ', 'zwei'])
  session.press(); await settle()
  sources[0].say()
  session.toggleMicrophone(); await settle()
  assert.equal(session.phase.kind, 'paused')
  assert.equal(session.plainText(), 'eins')
  session.toggleMicrophone(); await settle()
  sources[1].say()
  session.press(); await settle()
  assert.deepEqual(delivered, ['eins zwei'])
  session.dispose()
})

test('discarding while talking keeps the speech for Undo', async () => {
  const { session, sources, delivered } = setup(['nicht verlieren'])
  session.press(); await settle()
  sources[0].say()
  session.discard()
  assert.equal(session.phase.kind, 'discarded')
  session.undoDiscard(); await settle()
  assert.equal(session.phase.kind, 'paused')
  assert.equal(session.plainText(), 'nicht verlieren')
  session.press(); await settle()
  assert.deepEqual(delivered, ['nicht verlieren'])
  session.dispose()
})

test('discarding during the tail of a pause keeps that audio too', async () => {
  const { session, sources } = setup(['letzte Worte'])
  session.press(); await settle()
  sources[0].say()
  sources[0].holdTail = true
  session.toggleMicrophone()
  session.discard()
  assert.equal(session.phase.kind, 'discarded')
  session.undoDiscard(); await settle()
  assert.equal(session.plainText(), 'letzte Worte')
  session.dispose()
})

test('a click inside a word while talking goes to the nearer end of the word', async () => {
  const { session, sources, delivered } = setup(['Schreib mir', ' neu'])
  session.press(); await settle()
  sources[0].say()
  session.toggleMicrophone(); await settle()
  session.toggleMicrophone(); await settle()
  session.userMovedCaret(6) // Schrei|b
  sources[1].say()
  session.press(); await settle()
  assert.deepEqual(delivered, ['Schreib neu mir'])
  session.dispose()
})

test('a click right after a pause, before the words arrived, stays at the end', async () => {
  let release!: () => void
  const gate = new Promise<void>(resolve => { release = resolve })
  let calls = 0
  const { session, sources, delivered } = setup(['eins zwei drei ', 'vier'], {
    transcribe: async samples => { if (calls++ === 0) await gate; return decode(samples) },
  })
  session.press(); await settle()
  sources[0].say()
  session.toggleMicrophone(); await settle()
  session.userMovedCaret(session.doc.length) // the end, while only the placeholder is there
  release(); await settle()
  session.toggleMicrophone(); await settle()
  sources[1].say()
  session.press(); await settle()
  assert.deepEqual(delivered, ['eins zwei drei vier'])
  session.dispose()
})

test('going on during the tail of a pause does not record that moment twice', async () => {
  const { session, sources, delivered } = setup(['abcdef', 'xyz'])
  session.press(); await settle()
  sources[0].say(3) // "abc"
  sources[0].holdTail = true
  session.toggleMicrophone()
  session.toggleMicrophone(); await settle() // a new microphone is open: the old one stops counting
  sources[0].say(3) // "def" lands in the old microphone's tail, after the takeover
  sources[0].endTail(); await settle()
  sources[1].say()
  session.press(); await settle()
  // Same recording, so the letters join; what matters is that "def" is not in it.
  assert.deepEqual(delivered, ['abcxyz'])
  session.dispose()
})

test('nothing said is "Nothing heard", not an empty paste', async () => {
  const { session, delivered } = setup([''])
  session.press(); await settle()
  session.press(); await settle()
  assert.equal(session.phase.kind, 'failed')
  assert.deepEqual(delivered, [])
  session.dispose()
})

test('a failed send can be retried and then delivers', async () => {
  let fail = true
  const { session, sources, delivered } = setup(['wieder da'], {
    transcribe: async samples => { if (fail) throw new TranscriptionFailure('offline'); return decode(samples) },
  })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(session.phase, { kind: 'failed', message: 'No connection', canRetry: true })
  fail = false
  session.retry(); await settle()
  assert.deepEqual(delivered, ['wieder da'])
  session.dispose()
})

test('hold mode: a quick tap after a pause keeps the text', async () => {
  const { session, sources } = setup(['bleibt'], { mode: 'hold' })
  session.press(); await settle()
  sources[0].say()
  session.toggleMicrophone(); await settle()
  session.press() // resume: starting
  session.release() // let go before the microphone opened
  await settle()
  assert.equal(session.phase.kind, 'paused')
  assert.equal(session.plainText(), 'bleibt')
  session.dispose()
})

test('restoring from the tray while dictating keeps the discarded text', async () => {
  const { session, sources } = setup(['alt', 'neu'])
  session.press(); await settle()
  sources[0].say()
  session.discard()
  session.press(); await settle() // a new dictation
  session.restoreLast()
  assert.ok(session.discarded, 'still there to restore later')
  assert.equal(session.phase.kind, 'listening')
  session.dispose()
})

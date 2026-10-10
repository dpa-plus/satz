import { afterEach, mock, test } from 'node:test'
import assert from 'node:assert/strict'
import type { AudioSource } from '../src/core/session'
import { TranscriptionFailure } from '../src/core/transcriber'
import { decode, deferred, disposeAll, flush, phase, setup, settle, tick } from './sessionHarness'

// A failing test must not leave a session's timers running: the run would never end.
afterEach(() => disposeAll())

/** A source that makes real sound (not letters), for the speech gate. */
class Recorded implements AudioSource {
  onLevel?: (level: number) => void
  constructor(private data: Float32Array) {}
  async start() {}
  get sampleCount() { return this.data.length }
  samples(from: number, to: number) { return this.data.slice(from, to) }
  async finishSamples() { return this.data }
  cancel() {}
}
const RATE = 16_000
const silence = (seconds: number) => new Float32Array(seconds * RATE)
const talking = (seconds: number) => Float32Array.from({ length: seconds * RATE }, (_, i) => 0.3 * Math.sin(i * 0.3))

// MARK: - A queued start belongs to its own delivery

test('a start queued while writing does not cancel a dictation begun while the text was pasted', async () => {
  const gate = deferred(), pasting = deferred<{ pasted: boolean }>()
  const { session, sources, delivered } = setup(['erster satz', 'wichtige worte'], {
    transcribe: async samples => { await gate.promise; return decode(samples) },
    deliver: async text => { delivered.push(text); return pasting.promise },
  })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle() // finish: "Writing"
  session.press(); await settle() // queued: the next one begins once this is out
  assert.equal(phase(session), 'finishing')
  gate.resolve(); await settle()
  // The card is gone and the paste is under way: the user starts the next one by hand.
  assert.equal(phase(session), 'idle')
  session.press(); await settle()
  sources[1].say()
  pasting.resolve({ pasted: true }); await settle()
  // The queued start came after: it must not wipe what is being said.
  assert.equal(sources.length, 2)
  assert.equal(sources[1].cancelled, false)
  assert.equal(phase(session), 'listening')
  session.press(); await settle()
  assert.deepEqual(delivered, ['erster satz', 'wichtige worte'])
})

test('a start queued while writing still begins once the text is out', async () => {
  const gate = deferred(), pasting = deferred<{ pasted: boolean }>()
  const { session, sources } = setup(['erster satz', 'zweiter'], {
    transcribe: async samples => { await gate.promise; return decode(samples) },
    deliver: async () => pasting.promise,
  })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  session.press(); await settle()
  gate.resolve(); await settle()
  assert.equal(sources.length, 1, 'not before the paste is done')
  pasting.resolve({ pasted: true }); await settle()
  assert.equal(sources.length, 2)
  assert.equal(phase(session), 'listening')
})

test('a start queued while writing does not wipe a dictation restored from the tray while the text was pasted', async () => {
  const gate = deferred(), pasting = deferred<{ pasted: boolean }>()
  const { session, sources, delivered } = setup(['gerettet', 'neuer satz'], {
    transcribe: async samples => { await gate.promise; return decode(samples) },
    deliver: async text => { delivered.push(text); return pasting.promise },
  })
  // A dictation thrown away earlier waits in the tray.
  session.press(); await settle()
  sources[0].say()
  session.discard()
  session.press(); await settle() // the next dictation begins
  sources[1].say()
  session.press(); await settle() // finish it: "Writing"
  session.press(); await settle() // queue yet another
  gate.resolve(); await settle()
  assert.equal(phase(session), 'idle', 'the card is gone, the paste is under way')
  session.restoreLast(); await settle()
  assert.equal(phase(session), 'paused')
  assert.equal(session.plainText(), 'gerettet')
  pasting.resolve({ pasted: true }); await settle()
  assert.equal(phase(session), 'paused', 'the queued start left it alone')
  assert.equal(session.plainText(), 'gerettet')
  assert.equal(sources.length, 2)
  assert.deepEqual(delivered, ['neuer satz'])
})

// MARK: - Hold to talk, pressed again while the last dictation is written

test('hold mode: holding the key again while the text is written starts the next dictation once it is out', async () => {
  const gate = deferred()
  const { session, sources, delivered } = setup(['eins', 'zwei'], { mode: 'hold', transcribe: async samples => { await gate.promise; return decode(samples) } })
  session.press(); await settle()
  sources[0].say()
  session.release(); await settle()
  assert.equal(phase(session), 'finishing')
  session.press(); await settle() // held again, the words are coming
  gate.resolve(); await settle()
  assert.deepEqual(delivered, ['eins'])
  assert.equal(sources.length, 2, 'the second microphone opened')
  assert.equal(phase(session), 'listening')
  sources[1].say()
  session.release(); await settle()
  assert.deepEqual(delivered, ['eins', 'zwei'])
})

test('hold mode: letting go again before the text is out cancels the queued start', async () => {
  const gate = deferred()
  const { session, sources, delivered } = setup(['eins', 'zwei'], { mode: 'hold', transcribe: async samples => { await gate.promise; return decode(samples) } })
  session.press(); await settle()
  sources[0].say()
  session.release(); await settle()
  session.press(); await settle()
  session.release(); await settle() // a quick tap: nothing to hold for any more
  gate.resolve(); await settle()
  assert.deepEqual(delivered, ['eins'])
  assert.equal(sources.length, 1, 'no recording runs on with the key up')
  assert.equal(phase(session), 'idle')
})

test('hold mode: letting go while the text is being pasted (card already closed) starts nothing', async () => {
  const gate = deferred()
  const pasting = deferred()
  const { session, sources, delivered } = setup(['eins', 'zwei'], {
    mode: 'hold',
    transcribe: async samples => { await gate.promise; return decode(samples) },
    deliver: async text => { await pasting.promise; delivered.push(text); return { pasted: true } },
  })
  session.press(); await settle()
  sources[0].say()
  session.release(); await settle()
  session.press(); await settle() // held again while the text is written
  gate.resolve(); await settle() // the text is out of the model, now being pasted
  session.release(); await settle() // let go during the paste: release() cannot take it back any more
  pasting.resolve(); await settle()
  assert.deepEqual(delivered, ['eins'])
  assert.equal(sources.length, 1, 'no recording runs on with the key up')
})

// MARK: - A delivery that threw

test('a delivery that threw offers the text back on the card itself, and the card closes like any failure', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  try {
    const { session, sources } = setup(['rettet mein wort'], { deliver: async () => { throw new Error('clipboard write failed') } })
    session.press(); await flush()
    sources[0].say()
    session.press(); await flush()
    assert.deepEqual(session.phase, { kind: 'failed', message: 'Not pasted', canRetry: false, canRestore: true })
    assert.ok(session.discarded, 'the text is kept')
    assert.equal(session.canRestore, true, 'the tray offers it as well')
    // The card says "Restore", and it works at once, not only after closing the card.
    session.restoreLast(); await flush()
    assert.equal(phase(session), 'paused')
    assert.equal(session.plainText(), 'rettet mein wort')
    } finally { mock.timers.reset() }
})

test('the delivery-failure card closes after a few seconds and the text stays restorable', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  try {
    const { session, sources } = setup(['bleibt erhalten'], { deliver: async () => { throw new Error('boom') } })
    session.press(); await flush()
    sources[0].say()
    session.press(); await flush()
    assert.equal(phase(session), 'failed')
    mock.timers.tick(4900); await flush()
    assert.equal(phase(session), 'failed')
    mock.timers.tick(200); await flush()
    assert.equal(phase(session), 'idle')
    assert.ok(session.discarded)
    session.restoreLast(); await flush()
    assert.equal(session.plainText(), 'bleibt erhalten')
    } finally { mock.timers.reset() }
})

test('a text that only reached the clipboard says so and the card closes after 4 seconds', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  try {
    const { session, sources } = setup(['auf die zwischenablage'], { deliver: async () => ({ pasted: false, reason: 'no window' }) })
    session.press(); await flush()
    sources[0].say()
    session.press(); await flush()
    assert.equal(phase(session), 'clipboard')
    mock.timers.tick(3900); await flush()
    assert.equal(phase(session), 'clipboard')
    mock.timers.tick(200); await flush()
    assert.equal(phase(session), 'idle')
    } finally { mock.timers.reset() }
})

// MARK: - The desktop shortcut, and the Undo window

test('toggle() finishes a dictation held with the key, whatever the trigger mode', async () => {
  const { session, sources, delivered } = setup(['per kurzbefehl'], { mode: 'hold' })
  session.toggle(); await settle()
  assert.equal(phase(session), 'listening')
  sources[0].say()
  session.toggle(); await settle()
  assert.deepEqual(delivered, ['per kurzbefehl'])
})

test('Undo is there for 5 seconds after a discard, and not for much less', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  try {
    const { session, sources } = setup(['nicht verlieren', 'noch einmal'])
    session.press(); await flush()
    sources[0].say()
    session.discard()
    assert.equal(phase(session), 'discarded')
    mock.timers.tick(4900); await flush()
    assert.equal(phase(session), 'discarded', 'still offered after 4.9 s')
    session.undoDiscard(); await flush()
    assert.equal(session.plainText(), 'nicht verlieren')
    session.discard()
    mock.timers.tick(5100); await flush()
    assert.equal(phase(session), 'idle', 'the card closed after 5 s')
    } finally { mock.timers.reset() }
})

// MARK: - A provider's upload limit

test('a recording over the provider limit says so and offers no Retry that cannot succeed', async () => {
  let asked = 0
  const { session, sources } = setup(['sehr lange aufnahme'], { transcribe: async () => { asked++; throw new TranscriptionFailure('tooLarge', 413) } })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(session.phase, { kind: 'failed', message: 'Too long for the provider', canRetry: false })
  session.retry(); await settle()
  assert.equal(asked, 1, 'Retry does nothing')
})

test('every other failure still offers Retry', async () => {
  const { session, sources } = setup(['hallo'], { transcribe: async () => { throw new TranscriptionFailure('rateLimited', 429) } })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(session.phase, { kind: 'failed', message: 'Provider busy', canRetry: true })
})

test('after the provider limit failed, a switch to another provider and the shortcut sends the same audio again', async () => {
  let provider: 'cloud' | 'local' = 'cloud'
  const { session, sources, delivered } = setup(['lang'], { transcribe: async samples => { if (provider === 'cloud') throw new TranscriptionFailure('tooLarge', 413); return decode(samples) } })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.equal(phase(session), 'failed')
  provider = 'local'
  session.press(); await settle() // nothing was thrown away: the audio is still there
  assert.deepEqual(delivered, ['lang'])
})

// MARK: - Silence is never sent

test('a recording of only silence is never sent to the provider, which would invent text for it', async () => {
  let asked = 0
  const { session, delivered } = setup([], { realGate: true, makeSource: () => new Recorded(silence(2)), transcribe: async () => { asked++; return 'Vielen Dank.' } })
  session.press(); await settle()
  session.press(); await settle()
  assert.equal(asked, 0, 'nothing went out')
  assert.deepEqual(delivered, [])
  assert.deepEqual(session.phase, { kind: 'failed', message: 'Nothing heard', canRetry: false })
})

test('a recording with speech in it is sent as before', async () => {
  let asked = 0
  const { session, delivered } = setup([], { realGate: true, makeSource: () => new Recorded(talking(1)), transcribe: async () => { asked++; return 'Hallo zusammen.' } })
  session.press(); await settle()
  session.press(); await settle()
  assert.equal(asked, 1)
  assert.deepEqual(delivered, ['Hallo zusammen.'])
})

test('silence before a pause is not sent, and the words after it are', async () => {
  let asked = 0
  const sounds = [silence(2), talking(1)]
  const { session, delivered } = setup([], { realGate: true, makeSource: index => new Recorded(sounds[index]), transcribe: async () => { asked++; return 'danach' } })
  session.press(); await settle()
  session.toggleMicrophone(); await settle()
  assert.equal(asked, 0)
  assert.equal(session.plainText(), '', 'no placeholder is left behind')
  session.toggleMicrophone(); await settle()
  session.press(); await tick(); await settle()
  assert.equal(asked, 1)
  assert.deepEqual(delivered, ['danach'])
})

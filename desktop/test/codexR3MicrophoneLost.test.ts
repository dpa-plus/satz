import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import path from 'node:path'
import { afterEach, mock, test } from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
import { Session } from '../src/core/session'
import { MicHub, MicRecorder } from '../src/main/recorder'
import { recordFor, type MicrophoneParts } from '../src/renderer/microphone'
import { flush } from './sessionHarness'

/**
 * Codex's third audit of 14 October 2026, I-1: a microphone that went away
 * while recording (its track ended, its audio context failed) left the
 * dictation "listening" to nothing. A quick pause and resume took the dead
 * capture over again, and finishing sent only the second before the loss,
 * without a word. Now the dictation pauses with what it recorded and says
 * "Mikrofon getrennt"; resuming opens a new capture, finishing sends it all.
 *
 * Wired as in the app: the card's side is the real recordFor and Microphone,
 * the main side is main.ts's recording block run as written there (unit tests
 * do not reach main.ts), and IPC arrives later and in order, as Electron
 * delivers it. Capture, transcription and paste are stand-ins. Each test
 * fails on the code before the fix.
 */
afterEach(() => mock.timers.reset())

class Track extends EventTarget {
  readyState: 'live' | 'ended' = 'live'
  /** As in a browser: stopping a track fires no "ended". */
  stop() { this.readyState = 'ended' }
  /** Unplugged: the browser ends the track and says so. */
  unplug() { this.readyState = 'ended'; this.dispatchEvent(new Event('ended')) }
}

function recordingBlock() {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const from = main.indexOf('  let recordingRequest = 0'), to = main.indexOf('\n  const delivered: string[] = []')
  assert.ok(from > 0 && to > from, 'the recording block is where it was')
  return main.slice(from, to)
}

function rig(options: { mainBlock?: (block: string) => string } = {}) {
  const tracks: Track[] = []
  const taps: { onChunk: (chunk: Float32Array) => void; onFailed: () => void; closed: boolean }[] = []
  let endedOnOpen = false
  const parts: MicrophoneParts = {
    async getUserMedia() {
      const track = new Track()
      if (endedOnOpen) track.readyState = 'ended'
      tracks.push(track)
      return { getTracks: () => [track] } as unknown as MediaStream
    },
    async openTap(onChunk, onFailed) {
      const tap = { onChunk, onFailed, closed: false }
      taps.push(tap)
      return { connect() {}, close() { tap.closed = true } }
    },
  }
  const ipcMain = new EventEmitter()
  const toCard = new Map<string, (value: unknown) => void>()
  const card = { send(channel: string, value: unknown) { queueMicrotask(() => toCard.get(channel)?.(value)) } }
  const bridge = {
    send(channel: string, ...args: unknown[]) { queueMicrotask(() => ipcMain.emit(channel, {}, ...args)) },
    on(channel: string, listener: (value: unknown) => void) { toCard.set(channel, listener) },
  }
  recordFor(bridge, parts, error => ((error as Error).name === 'MicrophoneLost' ? 'Microphone lost' : 'Microphone not working'))
  const context = vm.createContext({ ipcMain, card, MicHub, setTimeout, clearTimeout, de: (_de: string, en: string) => en, globalThis: {} as { hub?: MicHub } })
  const block = (options.mainBlock ?? (b => b))(recordingBlock())
  vm.runInContext(ts.transpileModule(`${block}\nglobalThis.hub = hub`, { compilerOptions: { target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.CommonJS } }).outputText, context)
  ipcMain.emit('card:ready')
  const hub = (context.globalThis as { hub: MicHub }).hub
  const delivered: string[] = [], sent: number[] = []
  const session = new Session({
    makeSource: () => new MicRecorder(hub),
    transcribe: async samples => { sent.push(samples.length); return `heard ${samples.length}` },
    replacements: () => [], missing: () => null, endpointMissing: () => false, triggerMode: () => 'tap',
    deliver: async text => { delivered.push(text); return { pasted: true } },
    hasSpeech: samples => samples.length > 0,
  })
  return {
    session, hub, ipcMain, tracks, taps, delivered, sent,
    /** A second of speech reaches the hub only through a live track and an open tap, and over IPC. */
    async speak(samples = 16_000) {
      const tap = taps.at(-1), track = tracks.at(-1)
      if (tap && !tap.closed && track?.readyState === 'live') tap.onChunk(new Float32Array(samples).fill(0.2))
      await flush()
    },
    live: () => tracks.filter(track => track.readyState === 'live').length,
    openWithEndedTrack() { endedOnOpen = true },
  }
}

/** The phase as plain data: kind and the lost flag. */
const shown = (session: Session) => JSON.stringify(session.phase)

test('I-1: the track ends while listening: the dictation pauses with what it recorded and says the microphone is lost', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush()
    assert.equal(shown(r.session), '{"kind":"listening"}')
    await r.speak(); assert.equal(r.hub.total, 16_000)
    r.tracks[0].unplug(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused","lost":true}', 'not listening to nothing')
    assert.equal(r.live(), 0); assert.equal(r.taps[0].closed, true, 'the dead capture is closed')
    // What was said before the loss went to be transcribed, as a pause sends it.
    assert.deepEqual(r.sent, [16_000])
    // Weitersprechen: a new capture, from the microphone there is now.
    r.session.toggleMicrophone(); await flush()
    assert.equal(shown(r.session), '{"kind":"listening"}')
    assert.equal(r.tracks.length, 2, 'a fresh capture, not the dead one')
    await r.speak()
    r.session.press(); mock.timers.tick(400); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 32000'], 'both seconds, one recording')
    assert.equal(r.live(), 0)
  } finally { r.session.dispose() }
})

test('I-1: the track ends in a pause\'s tail and the user resumes at once: a new capture, nothing lost', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush(); await r.speak()
    r.session.toggleMicrophone(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused"}')
    // Within the 400 ms tail, which still holds the capture.
    r.tracks[0].unplug(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused","lost":true}', 'the paused card says why')
    r.session.toggleMicrophone(); await flush()
    assert.equal(shown(r.session), '{"kind":"listening"}')
    assert.equal(r.tracks.length, 2, 'the dead capture in the tail is not taken over')
    await r.speak(); assert.equal(r.hub.total, 32_000)
    mock.timers.tick(400); await flush()
    r.session.press(); mock.timers.tick(400); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 32000'])
    assert.equal(r.live(), 0)
  } finally { r.session.dispose() }
})

test('I-1: the audio context fails while listening: the same as a track that ended', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush(); await r.speak()
    r.taps[0].onFailed(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused","lost":true}')
    assert.equal(r.live(), 0, 'the track of the failed context is let go')
    r.session.toggleMicrophone(); await flush(); await r.speak()
    r.session.press(); mock.timers.tick(400); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 32000'])
  } finally { r.session.dispose() }
})

test('I-1: finishing while paused after the loss sends what was recorded', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush(); await r.speak()
    r.tracks[0].unplug(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused","lost":true}', 'told before it is sent')
    r.session.press(); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 16000'])
    assert.equal(r.session.phase.kind, 'idle')
    assert.equal(r.tracks.length, 1, 'finishing opens no microphone')
  } finally { r.session.dispose() }
})

test('I-1: a loss told late, after the next microphone was asked for, does not end the new recording', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush(); await r.speak(8_000)
    r.session.press(); mock.timers.tick(400); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 8000'])
    r.session.press(); await flush()
    assert.equal(r.tracks.length, 2)
    // The first microphone's loss, crossing the second start on the way.
    r.ipcMain.emit('rec:lost', {}, 1); await flush()
    assert.equal(shown(r.session), '{"kind":"listening"}', 'the new microphone works')
    await r.speak(); assert.equal(r.hub.total, 16_000)
    // Its own loss still counts.
    r.tracks[1].unplug(); await flush()
    assert.equal(shown(r.session), '{"kind":"paused","lost":true}')
  } finally { r.session.dispose() }
})

test('I-1: a microphone that is gone while it opens fails the start, and the words before stay', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const r = rig()
  try {
    r.session.press(); await flush(); await r.speak()
    r.session.toggleMicrophone(); await flush(); mock.timers.tick(400); await flush()
    assert.equal(r.session.plainText().trim(), 'heard 16000')
    r.openWithEndedTrack()
    r.session.toggleMicrophone(); await flush()
    assert.deepEqual(r.session.phase, { kind: 'failed', message: 'Microphone lost', canRetry: false })
    assert.equal(r.live(), 0)
    // The shortcut sends what there is.
    r.session.press(); await flush(); mock.timers.tick(400); await flush()
    assert.deepEqual(r.delivered, ['heard 16000'])
  } finally { r.session.dispose() }
})

test('I-1: a lost recording ends where the capture did: the next capture\'s audio is not its, and no tail is waited for', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const hub = new MicHub({ async start() {}, stop() {} })
  const before = new MicRecorder(hub)
  let told = 0
  before.onLost = () => told++
  await before.start()
  hub.push(new Float32Array(100).fill(0.1))
  hub.lost()
  assert.equal(told, 1)
  const after = new MicRecorder(hub)
  await after.start()
  hub.push(new Float32Array(50).fill(0.3))
  assert.equal(before.sampleCount, 100)
  assert.equal(after.sampleCount, 50)
  let samples: Float32Array | null = null
  void before.finishSamples().then(value => { samples = value })
  await flush()
  assert.equal(samples!.length, 100, 'nothing more can come, so nothing is waited for')
  assert.ok(samples!.every(value => Math.abs(value - 0.1) < 1e-6))
})

test('I-1: the hub opens a new capture after a lost one even while a recording in its tail holds it, and tries again after a failed start', async () => {
  let starts = 0, fail = false
  const hub = new MicHub({ async start() { starts++; if (fail) throw new Error('no microphone') }, stop() {} })
  const tail = () => {}, lost: string[] = []
  await hub.acquire(tail, () => lost.push('tail'))
  hub.push(new Float32Array(100))
  hub.lost()
  assert.deepEqual(lost, ['tail'])
  fail = true
  await assert.rejects(hub.acquire(() => {}), /no microphone/)
  fail = false
  await hub.acquire(() => {})
  assert.equal(starts, 3, 'started, restarted after the loss, and again after that failed')
  assert.equal(hub.total, 100, 'the buffer the tail reads is kept')
})

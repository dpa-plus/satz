import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createServer } from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import { Session, type AudioSource } from '../src/core/session'
import { transcribe } from '../src/core/transcriber'
import { encodeWAV } from '../src/core/wav'
import { SherpaEngine, type SherpaAddon } from '../src/main/sherpaEngine'
import { A, gate, setup as setupLocal, speech, tick, until } from './lifecycleHarness'
import { decode, deferred, disposeAll, FakeSource, phase, settle } from './sessionHarness'

/**
 * Codex's bug hunt of 14 October 2026, F07: a thrown-away dictation's result
 * was ignored, but its work went on. A cloud request was sent again after
 * its Retry-After, and a long local dictation kept decoding its pieces ahead
 * of the next one. The Session now aborts a send's signal when it is thrown
 * away, superseded or reset; main.ts hands it to both transcribers. Each test
 * fails on the code before the fix.
 */
const sessions: Session[] = []
afterEach(() => { disposeAll(); for (const session of sessions.splice(0)) session.dispose() })

/** A Session as main.ts wires it, around `transcribe(samples, signal)`. */
function wired(makeSource: (index: number) => AudioSource, transcribe: (samples: Float32Array, signal: AbortSignal) => Promise<string>, options: { realGate?: boolean } = {}) {
  const delivered: string[] = [], logs: string[] = []
  let made = 0
  const session = new Session({
    makeSource: () => makeSource(made++), transcribe,
    replacements: () => [], missing: () => null, endpointMissing: () => false, triggerMode: () => 'tap',
    deliver: async text => { delivered.push(text); return { pasted: true } },
    log: message => logs.push(message),
    ...(options.realGate ? {} : { hasSpeech: (samples: Float32Array) => samples.length > 0 }),
  })
  sessions.push(session)
  return { session, delivered, logs }
}

// MARK: - The Session's side

test('F07: throwing a dictation away aborts the transcription it was waiting for, and that is not logged as a failure', async () => {
  const signals: AbortSignal[] = []
  const answer = deferred<string>()
  const source = new FakeSource('hello there')
  const { session, logs } = wired(() => source, (_samples, signal) => {
    signals.push(signal)
    signal.addEventListener('abort', () => answer.reject(new DOMException('aborted', 'AbortError')))
    return answer.promise
  })
  session.press(); await settle(); source.say()
  session.toggleMicrophone(); await settle()
  assert.equal(signals.length, 1)
  assert.equal(signals[0].aborted, false)
  session.discard(); await settle()
  assert.equal(signals[0].aborted, true)
  assert.ok(!logs.some(line => line.startsWith('transcription failed')), logs.join('\n'))
})

test('F07: a send overtaken by more audio of the same recording is aborted; the one that replaces it is not', async () => {
  const signals: AbortSignal[] = []
  const answers: ReturnType<typeof deferred<string>>[] = []
  const sources = [new FakeSource('one two'), new FakeSource(' three four')]
  const { session, delivered } = wired(index => sources[index], (samples, signal) => {
    signals.push(signal)
    const answer = deferred<string>()
    answers.push(answer)
    void answer.promise.catch(() => {})
    return answer.promise.then(() => decode(samples))
  })
  session.press(); await settle(); sources[0].say()
  session.toggleMicrophone(); await settle()
  session.toggleMicrophone(); await settle(); sources[1].say()
  session.press(); await settle()
  assert.equal(signals.length, 2, 'the whole recording went again')
  assert.deepEqual(signals.map(signal => signal.aborted), [true, false])
  answers[1].resolve(''); await settle()
  assert.deepEqual(delivered, ['one two three four'])
})

test('F07: a dictation that is finished normally never aborts its transcription', async () => {
  const signals: AbortSignal[] = []
  const source = new FakeSource('all of it')
  const { session, delivered } = wired(() => source, async (samples, signal) => { signals.push(signal); return decode(samples) })
  session.press(); await settle(); source.say()
  session.press(); await settle()
  assert.deepEqual(delivered, ['all of it'])
  assert.deepEqual(signals.map(signal => signal.aborted), [false])
})

// MARK: - Cloud

test('F07: a discarded cloud dictation waiting out a Retry-After is not uploaded again', async () => {
  const seen: number[] = []
  const server = createServer((request, response) => {
    request.resume()
    request.on('end', () => {
      seen.push(Date.now())
      response.writeHead(seen.length === 1 ? 429 : 200, { 'content-type': 'application/json', 'retry-after': '1' })
      response.end(seen.length === 1 ? '{}' : '{"combinedPhrases":[{"text":"synthetic words"}]}')
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  try {
    const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`
    const audio = new Float32Array(1600).fill(0.25)
    const source: AudioSource = { sampleCount: audio.length, start: async () => {}, samples: () => audio, finishSamples: async () => audio, cancel: () => {} }
    // As main.ts calls it: the signal is the fifth argument.
    const { session } = wired(() => source, (samples, signal) =>
      transcribe({ provider: 'microsoft', model: '', microsoftEndpoint: base, vocabulary: [], removesFillers: false, backupAfter: null }, encodeWAV(samples), 'SYNTHETIC-KEY', undefined, signal))
    session.press(); await settle()
    session.toggleMicrophone()
    await until(() => seen.length === 1)
    session.discard()
    await new Promise(resolve => setTimeout(resolve, 1400))
    assert.equal(seen.length, 1, 'no second upload after the discard')
    assert.equal(phase(session), 'discarded')
  } finally { server.closeAllConnections(); server.close() }
})

// MARK: - Local

/** A recognizer whose old pieces (quiet, 0.1) wait to be let through one at a time; new ones (0.2) answer at once. */
function heldRecognizer() {
  const calls: string[] = []
  const waits = [deferred(), deferred(), deferred()]
  let old = 0
  const addon: SherpaAddon = {
    createOfflineRecognizerAsync: async () => ({}), offlineRecognizerSetConfig() {}, createOfflineStream: () => ({}), offlineStreamSetOption() {},
    acceptWaveformOffline(stream, wave) { Object.assign(stream as object, { samples: wave.samples }) },
    async decodeOfflineStreamAsync(_recognizer, stream) {
      const isOld = ((stream as { samples: Float32Array }).samples[0] ?? 0) < 0.15
      calls.push(isOld ? `old piece ${++old}` : 'new piece')
      if (isOld) await waits[old - 1].promise
      return JSON.stringify({ text: isOld ? 'discarded old words' : 'new words' })
    },
  } as SherpaAddon
  return { addon, calls, waits }
}

class Recorded implements AudioSource {
  constructor(private data: Float32Array) {}
  async start() {}
  get sampleCount() { return this.data.length }
  samples(from: number, to: number) { return this.data.slice(from, to) }
  async finishSamples() { return this.data }
  cancel() {}
}

test('F07: a long local dictation thrown away while its first piece decodes skips its other pieces; the next dictation does not wait for them', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-discard-local-'))
  const { addon, calls, waits } = heldRecognizer()
  const engine = new SherpaEngine(dir, () => {}, () => {}, undefined, () => addon)
  try {
    const { session, delivered } = wired(
      index => new Recorded(new Float32Array((index ? 1 : 70) * 16_000).fill(index ? 0.2 : 0.1)),
      (samples, signal) => engine.transcribe(samples, 'sherpa/canary-1b-v2', [], 'de', undefined, signal),
      { realGate: true })
    session.press(); await settle(); session.press(); await settle()
    assert.deepEqual(calls, ['old piece 1'])
    session.discard(); session.press(); await settle(); session.press(); await settle()
    waits[0].resolve(); await settle(); await settle()
    assert.deepEqual(calls, ['old piece 1', 'new piece'], 'pieces 2 and 3 of the discarded dictation are skipped')
    assert.deepEqual(delivered, ['new words'])
    assert.equal(phase(session), 'idle')
  } finally {
    for (const wait of waits) wait.resolve()
    await engine.unload()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('F07: through the helper, an abandoned transcription still in the queue never runs; the one running finishes and the next one runs', async () => {
  const { local, whisper, dir } = setupLocal({}, [A])
  const held = gate()
  try {
    const running = local.transcribe(speech, A, [], 'de', undefined, new AbortController().signal)
    // The helper is forked by that call; its first run waits for the gate.
    whisper()!.engine.running = held
    const abandoned = new AbortController()
    const queued = local.transcribe(speech, A, [], 'de', undefined, abandoned.signal)
    const next = local.transcribe(speech, A, [], 'de')
    await until(() => whisper()!.engine.runs.length === 1)
    abandoned.abort()
    await until(() => whisper()!.messages.includes('abandon'))
    await tick(); await tick()
    held.open()
    assert.equal(await running, A)
    await assert.rejects(queued)
    assert.equal(await next, A)
    assert.equal(whisper()!.engine.runs.length, 2, 'the abandoned one never reached the model')
  } finally {
    held.open()
    await local.unload()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('F07: main.ts hands the signal to both the local and the cloud transcriber', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  assert.match(main, /transcribe: \(samples, signal\) =>/)
  assert.match(main, /local\.transcribe\([^\n]*, signal\)/)
  assert.match(main, /transcribe\(store\.transcriberSettings\(\), [^\n]*, signal\)/)
})

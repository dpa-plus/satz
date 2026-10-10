import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { localModel, localModels } from '../src/core/localModels'
import { runsSherpa, sherpaConfig, sherpaPackage, sherpaRoles, sherpaURL, tidySherpaText, type SherpaSource } from '../src/core/sherpa'
import { isDownloaded, markerPath, type LocalState } from '../src/main/localFiles'
import { fetchFiles, SherpaEngine, type SherpaAddon } from '../src/main/sherpaEngine'

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 500 && !done(); i++) await tick(2)
  assert.ok(done(), 'timed out')
}
const source = (id: string) => localModel(id)!.sherpa!
const file = (name: string) => `/m/${name}`

test('each sherpa-onnx model has exactly the files its recognizer needs, with sizes and checksums', () => {
  for (const model of localModels.filter(entry => entry.engine === 'sherpa')) {
    const { kind, files, revision } = model.sherpa!
    assert.deepEqual(files.map(entry => entry.role).sort(), sherpaRoles(kind).sort(), model.id)
    assert.match(revision, /^[0-9a-f]{40}$/)
    for (const entry of files) {
      assert.ok(entry.bytes > 0, entry.name)
      assert.match(entry.sha256, /^[0-9a-f]{64}$/, `${model.id} ${entry.name}`)
    }
    // Stored under <models>/sherpa/<name>/: an "owner/name" id like the Whisper repos.
    assert.match(model.id, /^sherpa\/[\w.-]+$/)
  }
  assert.equal(sherpaURL(source('sherpa/moonshine-tiny'), 'tokens.txt'),
    'https://huggingface.co/csukuangfj/sherpa-onnx-moonshine-tiny-en-int8/resolve/bf2b762c076d8ea61e2af0b3851c9564fb77552e/tokens.txt')
})

test('Parakeet runs as a NeMo transducer, a dictation of up to four minutes in one piece', () => {
  const config = sherpaConfig(source('sherpa/parakeet-v3'), file, 'de', 4)
  assert.deepEqual(config, {
    featConfig: { sampleRate: 16_000, featureDim: 80 },
    modelConfig: {
      transducer: { encoder: '/m/encoder.int8.onnx', decoder: '/m/decoder.int8.onnx', joiner: '/m/joiner.int8.onnx' },
      tokens: '/m/tokens.txt', numThreads: 4, provider: 'cpu', debug: 0, modelType: 'nemo_transducer',
    },
    decodingMethod: 'greedy_search',
  })
  // Its encoder holds 400 s: a longer piece is refused by ONNX Runtime.
  assert.equal(source('sherpa/parakeet-v3').window, 240)
  assert.equal(source('sherpa/parakeet-v2').window, 240)
})

test('Canary is told the language set in Settings, and writes punctuation', () => {
  for (const spoken of ['de', 'en'] as const) {
    assert.deepEqual(sherpaConfig(source('sherpa/canary-180m'), file, spoken, 2).modelConfig.canary,
      { encoder: '/m/encoder.int8.onnx', decoder: '/m/decoder.int8.onnx', srcLang: spoken, tgtLang: spoken, usePnc: 1 })
  }
  assert.equal(sherpaConfig(source('sherpa/canary-180m'), file, 'de', 2).modelConfig.modelType, undefined)
})

test('Moonshine has four parts; SenseVoice finds the language itself and writes numbers as digits', () => {
  assert.deepEqual(sherpaConfig(source('sherpa/moonshine-base'), file, 'de', 1).modelConfig.moonshine, {
    preprocessor: '/m/preprocess.onnx', encoder: '/m/encode.int8.onnx', uncachedDecoder: '/m/uncached_decode.int8.onnx', cachedDecoder: '/m/cached_decode.int8.onnx' })
  assert.deepEqual(sherpaConfig(source('sherpa/sense-voice'), file, 'en', 1).modelConfig.senseVoice, { model: '/m/model.int8.onnx', language: '', useInverseTextNormalization: 1 })
  // The models made for short clips are split at quiet moments.
  for (const id of ['sherpa/moonshine-base', 'sherpa/moonshine-tiny', 'sherpa/sense-voice', 'sherpa/canary-180m']) assert.equal(source(id).window, 30, id)
})

test('the native module for each system satz ships; none for Windows on ARM', () => {
  assert.equal(sherpaPackage('win32', 'x64'), 'sherpa-onnx-win-x64')
  assert.equal(sherpaPackage('linux', 'arm64'), 'sherpa-onnx-linux-arm64')
  assert.equal(runsSherpa('win32', 'arm64'), false)
  for (const [platform, arch] of [['win32', 'x64'], ['linux', 'x64'], ['linux', 'arm64'], ['darwin', 'arm64']]) assert.equal(runsSherpa(platform, arch), true)
})

test('tidying: no space before punctuation, words and letters untouched', () => {
  assert.equal(tidySherpaText('Bitte schick mir die Unterlagen bis Freitag , dann kann ich prüfen .'), 'Bitte schick mir die Unterlagen bis Freitag, dann kann ich prüfen.')
  assert.equal(tidySherpaText('Hello, World.'), 'Hello, World.')
  assert.equal(tidySherpaText('NASA SAID OK'), 'NASA SAID OK')
  assert.equal(tidySherpaText('  '), '')
})

// MARK: - Downloading

/** A server for a model's files: each one in pieces, or wrong, or slow. */
function server(contents: Record<string, Uint8Array>, options: { delay?: number; asked?: string[] } = {}): typeof fetch {
  return (async (url: string | URL, init?: RequestInit) => {
    const name = String(url).split('/').pop()!
    options.asked?.push(name)
    const body = contents[name]
    if (!body) return new Response('missing', { status: 404 })
    const signal = init?.signal
    return new Response(new ReadableStream({
      async start(controller) {
        for (let at = 0; at < body.length; at += 1000) {
          if (options.delay) await tick(options.delay)
          if (signal?.aborted) { controller.error(signal.reason); return }
          controller.enqueue(body.subarray(at, at + 1000))
        }
        controller.close()
      },
    }), { status: 200 })
  }) as typeof fetch
}

/** A made-up model of three files, its checksums right. */
function fakeSource(): { source: SherpaSource; contents: Record<string, Uint8Array> } {
  const contents: Record<string, Uint8Array> = { 'model.int8.onnx': new Uint8Array(5500).fill(7), 'tokens.txt': new TextEncoder().encode('a 0\nb 1\n') }
  const files = Object.entries(contents).map(([name, body]) => ({ name, role: name === 'tokens.txt' ? 'tokens' as const : 'model' as const, bytes: body.length, sha256: createHash('sha256').update(body).digest('hex') }))
  return { source: { kind: 'sense-voice', repo: 'test', revision: '0'.repeat(40), window: 30, files }, contents }
}

test('the files arrive one by one, with progress over all of them, each under its name only once complete', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-fetch-'))
  try {
    const { source, contents } = fakeSource()
    const seen: number[] = []
    await fetchFiles(source, dir, bytes => seen.push(bytes), new AbortController().signal, server(contents))
    assert.deepEqual(fs.readdirSync(dir).sort(), ['model.int8.onnx', 'tokens.txt'])
    assert.equal(seen.at(-1), 5500 + contents['tokens.txt'].length)
    assert.deepEqual(seen, [...seen].sort((a, b) => a - b))
    // Again: what is complete is kept, nothing is fetched.
    const asked: string[] = []
    await fetchFiles(source, dir, () => {}, new AbortController().signal, server(contents, { asked }))
    assert.deepEqual(asked, [])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a file left from an earlier download is kept only if its checksum is right, not just its size', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-fetch-'))
  try {
    const { source, contents } = fakeSource()
    // Right size, wrong bytes: fetched again and replaced.
    fs.writeFileSync(path.join(dir, 'model.int8.onnx'), new Uint8Array(5500).fill(9))
    fs.writeFileSync(path.join(dir, 'tokens.txt'), contents['tokens.txt'])
    const asked: string[] = []
    await fetchFiles(source, dir, () => {}, new AbortController().signal, server(contents, { asked }))
    assert.deepEqual(asked, ['model.int8.onnx'])
    assert.deepEqual(new Uint8Array(fs.readFileSync(path.join(dir, 'model.int8.onnx'))), contents['model.int8.onnx'])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a file that arrives damaged or not at all fails the download and leaves no file under its name', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-fetch-'))
  try {
    const { source, contents } = fakeSource()
    const damaged = { ...contents, 'model.int8.onnx': new Uint8Array(5500).fill(8) }
    await assert.rejects(fetchFiles(source, dir, () => {}, new AbortController().signal, server(damaged)), /model\.int8\.onnx arrived damaged/)
    assert.deepEqual(fs.readdirSync(dir), [])
    const short = { ...contents, 'model.int8.onnx': new Uint8Array(4000).fill(7) }
    await assert.rejects(fetchFiles(source, dir, () => {}, new AbortController().signal, server(short)), /damaged/)
    await assert.rejects(fetchFiles(source, dir, () => {}, new AbortController().signal, server({ 'model.int8.onnx': contents['model.int8.onnx'] })), /tokens\.txt: status 404/)
    assert.deepEqual(fs.readdirSync(dir), ['model.int8.onnx'])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

// MARK: - The engine

/** sherpa-onnx's native module as a recorder: what each recognizer was made with and what it was given. */
function fakeAddon() {
  const decoded: { config: unknown; seconds: number }[] = []
  const configs: unknown[] = []
  const addon: SherpaAddon = {
    version: '1.13.8',
    onnxruntimeVersion: '1.28.2',
    async createOfflineRecognizerAsync(config) { configs.push(structuredClone(config)); return { config: structuredClone(config) } },
    offlineRecognizerSetConfig(recognizer, config) { (recognizer as { config: unknown }).config = structuredClone(config) },
    createOfflineStream(recognizer) { return { recognizer, samples: new Float32Array(0) } },
    acceptWaveformOffline(stream, wave) { (stream as { samples: Float32Array }).samples = wave.samples },
    async decodeOfflineStreamAsync(recognizer, stream) {
      const seconds = (stream as { samples: Float32Array }).samples.length / 16_000
      decoded.push({ config: (recognizer as { config: unknown }).config, seconds })
      await tick(1)
      return JSON.stringify({ text: ` piece of ${Math.round(seconds)} s ` })
    },
  }
  return { addon, decoded, configs }
}

/** A model's files in place, as if downloaded. */
function placed(dir: string, id: string) {
  const folder = path.join(dir, id)
  fs.mkdirSync(folder, { recursive: true })
  for (const entry of localModel(id)!.sherpa!.files) fs.writeFileSync(path.join(folder, entry.name), '')
}

const speech = (seconds: number) => {
  const samples = new Float32Array(seconds * 16_000)
  for (let i = 0; i < samples.length; i++) samples[i] = 0.1 * Math.sin(i / 5)
  return samples
}

async function withEngine(body: (engine: SherpaEngine, fake: ReturnType<typeof fakeAddon>, dir: string, states: [string, LocalState][]) => Promise<void>, fetcher?: typeof fetch) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-sherpa-'))
  const fake = fakeAddon()
  const states: [string, LocalState][] = []
  const engine = new SherpaEngine(dir, () => {}, (id, state) => states.push([id, state]), fetcher, () => fake.addon)
  try { await body(engine, fake, dir, states) } finally { fs.rmSync(dir, { recursive: true, force: true }) }
}

test('Parakeet hears a long dictation whole (under four minutes); Moonshine, SenseVoice and Canary get it in pieces of at most 30 s', () => withEngine(async (engine, fake, dir) => {
  for (const id of ['sherpa/parakeet-v3', 'sherpa/moonshine-tiny']) placed(dir, id)
  assert.equal(await engine.transcribe(speech(70), 'sherpa/parakeet-v3', [], 'de'), 'piece of 70 s')
  fake.decoded.length = 0
  const text = await engine.transcribe(speech(70), 'sherpa/moonshine-tiny', [], 'de')
  assert.ok(fake.decoded.length === 3 && fake.decoded.every(piece => piece.seconds <= 30), JSON.stringify(fake.decoded))
  assert.equal(text.split('piece').length - 1, 3)
}))

test('silence is never sent, not even a quiet piece of a long dictation', () => withEngine(async (engine, fake, dir) => {
  placed(dir, 'sherpa/sense-voice')
  assert.equal(await engine.transcribe(new Float32Array(16_000 * 20), 'sherpa/sense-voice', [], 'de'), '')
  assert.equal(fake.decoded.length, 0)
  // 25 s of speech, then 35 s of nothing: the quiet second piece stays home.
  const samples = new Float32Array(60 * 16_000)
  samples.set(speech(25))
  await engine.transcribe(samples, 'sherpa/sense-voice', [], 'de')
  assert.equal(fake.decoded.length, 1)
}))

test("Canary follows the language chosen for it, any of its four, from one dictation to the next, without loading again", () => withEngine(async (engine, fake, dir) => {
  placed(dir, 'sherpa/canary-180m')
  const lang = () => (fake.decoded.at(-1)!.config as { modelConfig: { canary: { srcLang: string; tgtLang: string } } }).modelConfig.canary
  await engine.transcribe(speech(3), 'sherpa/canary-180m', [], 'en')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['en', 'en'])
  await engine.transcribe(speech(3), 'sherpa/canary-180m', [], 'de')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['de', 'de'])
  // Told Spanish or French, beyond the app's own German or English.
  await engine.transcribe(speech(3), 'sherpa/canary-180m', [], 'de', 'es')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['es', 'es'])
  await engine.transcribe(speech(3), 'sherpa/canary-180m', [], 'en', 'fr')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['fr', 'fr'])
  assert.equal(fake.configs.length, 1)
}))

test('a download: progress, then getting ready, then the marker and "ready"; its speed test loads nothing again', () => {
  const { contents } = fakeSource()
  const id = 'sherpa/moonshine-tiny'
  const files = Object.fromEntries(localModel(id)!.sherpa!.files.map(entry => [entry.name, contents['tokens.txt']]))
  // The catalog's checksums are the real ones: here only the flow is tested, through a source whose files match.
  return withEngine(async (engine, fake, dir, states) => {
    const real = localModel(id)!.sherpa!
    const saved = real.files
    real.files = saved.map(entry => ({ ...entry, bytes: contents['tokens.txt'].length, sha256: createHash('sha256').update(contents['tokens.txt']).digest('hex') }))
    try {
      engine.download(id)
      await until(() => states.some(([, state]) => state.kind === 'ready' || state.kind === 'failed'))
      const kinds = states.map(([, state]) => state.kind)
      assert.equal(kinds.at(-1), 'ready', JSON.stringify(states))
      assert.ok(kinds.includes('downloading') && kinds.includes('preparing'))
      assert.equal(isDownloaded(dir, id), true)
      await engine.measure(id, speech(10), [], 'en')
      assert.equal(fake.configs.length, 1)
    } finally { real.files = saved }
  }, server(files))
})

test('Cancel stops a download: nothing of it stays, no marker, and the model is missing again', () => {
  const big = new Uint8Array(200_000)
  const id = 'sherpa/sense-voice'
  return withEngine(async (engine, _fake, dir, states) => {
    engine.download(id)
    await until(() => fs.existsSync(path.join(dir, id, 'model.int8.onnx.part')))
    engine.cancel(id)
    await until(() => states.at(-1)![1].kind === 'missing')
    assert.equal(fs.existsSync(path.join(dir, id)), false)
    assert.equal(fs.existsSync(markerPath(dir, id)), false)
    assert.ok(!states.some(([, state]) => state.kind === 'failed'))
  }, server({ 'model.int8.onnx': big, 'tokens.txt': big }, { delay: 1 }))
})

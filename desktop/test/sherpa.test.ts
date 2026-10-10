import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { localModel, localModels, toldLanguage } from '../src/core/localModels'
import { makesUpTextForNoise, qwen3Limits, runsSherpa, sherpaConfig, sherpaPackage, sherpaRoles, sherpaURL, tidySherpaText, type SherpaSource } from '../src/core/sherpa'
import { isDownloaded, markerPath, type LocalState } from '../src/main/localFiles'
import { fetchFiles, hotwordList, SherpaEngine, type SherpaAddon } from '../src/main/sherpaEngine'

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
    // A role may be several files (Qwen3-ASR's tokenizer folder), so the roles are compared as sets.
    assert.deepEqual([...new Set(files.map(entry => entry.role))].sort(), [...sherpaRoles(kind)].sort(), model.id)
    assert.match(revision, /^[0-9a-f]{40}$/)
    assert.match(model.sherpa!.owner, /^[\w.-]+$/, model.id)
    assert.equal(new Set(files.map(entry => entry.name)).size, files.length, model.id)
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

test('each model comes from its own Hugging Face owner at a pinned commit, with the files the research listed', () => {
  const owners = Object.fromEntries(localModels.filter(entry => entry.engine === 'sherpa').map(entry => [entry.id, entry.sherpa!.owner]))
  assert.deepEqual(owners, {
    'sherpa/parakeet-v3': 'csukuangfj', 'sherpa/canary-180m': 'csukuangfj', 'sherpa/parakeet-v2': 'csukuangfj', 'sherpa/moonshine-base': 'csukuangfj',
    'sherpa/sense-voice': 'csukuangfj', 'sherpa/moonshine-tiny': 'csukuangfj',
    'sherpa/cohere-transcribe': 'csukuangfj2', 'sherpa/qwen3-asr-0.6b': 'csukuangfj2', 'sherpa/canary-1b-v2': 'Sarphix', 'sherpa/parakeet-german': 'x-ian',
  })
  assert.equal(sherpaURL(source('sherpa/cohere-transcribe'), 'encoder.int8.onnx.data'),
    'https://huggingface.co/csukuangfj2/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01/resolve/156a470cf08eefe706a0004f3c52d9ee567ca7a0/encoder.int8.onnx.data')
  assert.equal(sherpaURL(source('sherpa/qwen3-asr-0.6b'), 'tokenizer/vocab.json'),
    'https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a/tokenizer/vocab.json')
  assert.equal(sherpaURL(source('sherpa/canary-1b-v2'), 'tokens.txt'),
    'https://huggingface.co/Sarphix/canary-1b-v2-sherpa-onnx-int8/resolve/7d513cd4f39f6c7dc75c13a284b5e345b37f6198/tokens.txt')
  assert.equal(sherpaURL(source('sherpa/parakeet-german'), 'joiner.int8.onnx'),
    'https://huggingface.co/x-ian/sherpa-onnx-parakeet-primeline-de-int8/resolve/2a97df7e501bc25c6106a150a3379c5272088c53/joiner.int8.onnx')
  // Sizes and checksums as the research took them from the repos' file lists (10.10.2026).
  const file = (id: string, name: string) => source(id).files.find(entry => entry.name === name)!
  assert.deepEqual([file('sherpa/cohere-transcribe', 'encoder.int8.onnx.data').bytes, file('sherpa/cohere-transcribe', 'encoder.int8.onnx.data').sha256],
    [2_731_503_072, 'bcf1b7148c8518ae52df1ad2d2fc2b4e89261ea23e6c874eef1d9f55bcbaa4a3'])
  assert.equal(file('sherpa/canary-1b-v2', 'encoder.int8.onnx').sha256, '0d8f349aaa015d47c81d88c4ba3a5461c19bc09ebb72bf4c61698eec9f09e968')
  assert.equal(file('sherpa/parakeet-german', 'encoder.int8.onnx').sha256, 'ecb67ffb98a12bf46eaf7657cb2f714f6569511817a831296325dd32bc4daa30')
  assert.equal(source('sherpa/qwen3-asr-0.6b').files.filter(entry => entry.role === 'tokenizer').length, 3)
})

test('Cohere Transcribe: the encoder and its weights, the language it is told, punctuation and digits on', () => {
  const config = sherpaConfig(source('sherpa/cohere-transcribe'), file, 'de', 4)
  assert.deepEqual(config.modelConfig.cohereTranscribe, { encoder: '/m/encoder.int8.onnx', decoder: '/m/decoder.int8.onnx', language: 'de', usePunct: 1, useItn: 1 })
  assert.equal(config.modelConfig.tokens, '/m/tokens.txt')
  // The weights file is named by the encoder, in no field of the config; it has to be there all the same.
  assert.ok(JSON.stringify(config).indexOf('encoder.int8.onnx.data') < 0)
  assert.ok(source('sherpa/cohere-transcribe').files.some(entry => entry.name === 'encoder.int8.onnx.data' && entry.role === 'data'))
  // Up to 35 s per call: pieces of 30 s.
  assert.equal(source('sherpa/cohere-transcribe').window, 30)
  assert.equal((sherpaConfig(source('sherpa/cohere-transcribe'), file, 'en', 2).modelConfig.cohereTranscribe as { language: string }).language, 'en')
})

test('Qwen3-ASR: the three parts and the tokenizer folder, no tokens file, its limits set outright', () => {
  const config = sherpaConfig(source('sherpa/qwen3-asr-0.6b'), file, 'de', 4)
  assert.deepEqual(config.modelConfig.qwen3Asr, {
    convFrontend: '/m/conv_frontend.onnx', encoder: '/m/encoder.int8.onnx', decoder: '/m/decoder.int8.onnx', tokenizer: '/m/tokenizer', ...qwen3Limits })
  assert.equal(config.modelConfig.tokens, '')
  // The C API zeroes what is not set, and zero is refused.
  assert.ok(qwen3Limits.maxNewTokens > 0 && qwen3Limits.maxTotalLen > qwen3Limits.maxNewTokens)
  // The language is its own to find.
  assert.equal(localModel('sherpa/qwen3-asr-0.6b')!.language, 'auto')
  // Its decoder holds 512 tokens: the prompt, 13 a second of audio and the text. A piece of 15 s leaves 300 for the text and the word list.
  assert.equal(source('sherpa/qwen3-asr-0.6b').window, 15)
  const room = qwen3Limits.maxTotalLen - (source('sherpa/qwen3-asr-0.6b').window * 13 + 15 + 80)
  assert.ok(room >= 200, `${room} tokens left for the text`)
  assert.equal(qwen3Limits.maxTotalLen, 512)
})

test('Canary 1B v2 is a Canary and the German Parakeet a NeMo transducer: no new code path, the same configs', () => {
  assert.deepEqual(sherpaConfig(source('sherpa/canary-1b-v2'), file, 'en', 2).modelConfig.canary,
    { encoder: '/m/encoder.int8.onnx', decoder: '/m/decoder.int8.onnx', srcLang: 'en', tgtLang: 'en', usePnc: 1 })
  assert.equal(source('sherpa/canary-1b-v2').window, 30)
  assert.deepEqual(sherpaConfig(source('sherpa/parakeet-german'), file, 'de', 4), sherpaConfig(source('sherpa/parakeet-v3'), file, 'de', 4))
  assert.equal(source('sherpa/parakeet-german').window, 240)
  // Told like the small Canary: its four languages, sherpa-onnx 1.13.8 knows no more.
  assert.deepEqual(localModel('sherpa/canary-1b-v2')!.languages, ['en', 'de', 'es', 'fr'])
  assert.equal(toldLanguage('sherpa/canary-1b-v2', 'fr', 'de'), 'fr')
  assert.equal(toldLanguage('sherpa/canary-1b-v2', null, 'en'), 'en')
  assert.equal(localModel('sherpa/parakeet-german')!.language, 'de')
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
  return { source: { kind: 'sense-voice', owner: 'test', repo: 'test', revision: '0'.repeat(40), window: 30, files }, contents }
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
  const decoded: { config: unknown; seconds: number; options: Record<string, string> }[] = []
  const configs: unknown[] = []
  const addon: SherpaAddon = {
    version: '1.13.8',
    onnxruntimeVersion: '1.28.2',
    async createOfflineRecognizerAsync(config) { configs.push(structuredClone(config)); return { config: structuredClone(config) } },
    offlineRecognizerSetConfig(recognizer, config) { (recognizer as { config: unknown }).config = structuredClone(config) },
    createOfflineStream(recognizer) { return { recognizer, samples: new Float32Array(0), options: {} } },
    offlineStreamSetOption(stream, key, value) { (stream as { options: Record<string, string> }).options[key] = value },
    acceptWaveformOffline(stream, wave) { (stream as { samples: Float32Array }).samples = wave.samples },
    async decodeOfflineStreamAsync(recognizer, stream) {
      const seconds = (stream as { samples: Float32Array }).samples.length / 16_000
      decoded.push({ config: (recognizer as { config: unknown }).config, seconds, options: { ...(stream as { options: Record<string, string> }).options } })
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
  for (const entry of localModel(id)!.sherpa!.files) {
    fs.mkdirSync(path.dirname(path.join(folder, entry.name)), { recursive: true })
    fs.writeFileSync(path.join(folder, entry.name), '')
  }
}

/** Speech-like: loud syllables with quiet gaps. A pure tone at one level is no speech to Cohere's steady-noise check. */
const talk = (seconds: number) => {
  const samples = new Float32Array(seconds * 16_000)
  for (let i = 0; i < samples.length; i++) samples[i] = 0.1 * Math.sin(i / 5) * Math.max(0.03, Math.sin(i / 2500))
  return samples
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

// MARK: - Cohere Transcribe, Qwen3-ASR, and the two models that need no new code

test('Cohere Transcribe is told the language for every piece, pieces are 30 s at most, and a language it does not write is replaced, not refused', () => withEngine(async (engine, fake, dir) => {
  const id = 'sherpa/cohere-transcribe'
  placed(dir, id)
  const told = () => fake.decoded.at(-1)!.options.language
  await engine.transcribe(talk(3), id, [], 'de')
  assert.equal(told(), 'de')
  // The language set in Settings, then the one chosen for it among its fourteen.
  await engine.transcribe(talk(3), id, [], 'en')
  assert.equal(told(), 'en')
  await engine.transcribe(talk(3), id, [], 'de', 'ja')
  assert.equal(told(), 'ja')
  // Not one of its fourteen: its first, so the dictation is not lost to a refusal.
  await engine.transcribe(talk(3), id, [], 'de', 'ru')
  assert.equal(told(), 'de')
  // Loaded once; the language is a property of the stream, not of the recognizer.
  assert.equal(fake.configs.length, 1)
  fake.decoded.length = 0
  await engine.transcribe(talk(70), id, [], 'de', 'fr')
  assert.ok(fake.decoded.length === 3 && fake.decoded.every(piece => piece.seconds <= 30 && piece.options.language === 'fr'), JSON.stringify(fake.decoded))
}))

test('Cohere Transcribe makes up text for noise: a piece must have speech in it by its own level and not be one steady level; nothing quiet is sent', () => withEngine(async (engine, fake, dir) => {
  const id = 'sherpa/cohere-transcribe'
  placed(dir, id)
  let seed = 7
  const noise = (seconds: number, amplitude: number) => new Float32Array(seconds * 16_000).map(() => { seed = (seed * 16807) % 2147483647; return (seed / 2147483647 - 0.5) * amplitude })
  // Quiet room noise (about -50 dBFS): below what counts as speech.
  assert.equal(await engine.transcribe(noise(20, 0.01), id, [], 'de'), '')
  // A fan next to the microphone (about -30 dBFS): loud enough to count as speech by level, but one steady level.
  assert.equal(await engine.transcribe(noise(12, 0.08), id, [], 'de'), '')
  assert.equal(await engine.transcribe(new Float32Array(20 * 16_000), id, [], 'de'), '')
  assert.equal(fake.decoded.length, 0)
  // 25 s of speech, 35 s of nothing: the quiet piece stays home, and the language still goes with the one that is sent.
  const samples = new Float32Array(60 * 16_000)
  samples.set(talk(25))
  await engine.transcribe(samples, id, [], 'de')
  assert.equal(fake.decoded.length, 1)
  assert.equal(fake.decoded[0].options.language, 'de')
  // Speech over a fan is still speech: it rises and falls.
  fake.decoded.length = 0
  const over = noise(10, 0.08)
  const voice = talk(10)
  for (let i = 0; i < over.length; i++) over[i] += voice[i]
  await engine.transcribe(over, id, [], 'de')
  assert.equal(fake.decoded.length, 1)
}))

test('only Cohere Transcribe and Qwen3-ASR get the steady-noise check: the others wrote nothing for a fan', () => withEngine(async (engine, fake, dir) => {
  assert.deepEqual(localModels.filter(model => model.engine === 'sherpa' && makesUpTextForNoise(model.sherpa!.kind)).map(model => model.id).sort(), ['sherpa/cohere-transcribe', 'sherpa/qwen3-asr-0.6b'].sort())
  const id = 'sherpa/parakeet-german'
  placed(dir, id)
  let seed = 7
  const fan = new Float32Array(12 * 16_000).map(() => { seed = (seed * 16807) % 2147483647; return (seed / 2147483647 - 0.5) * 0.08 })
  await engine.transcribe(fan, id, [], 'de')
  assert.equal(fake.decoded.length, 1)
}))

test("Qwen3-ASR finds the language itself; the word list goes in as hotwords, and its text is kept only if it lost no words", () => {
  const id = 'sherpa/qwen3-asr-0.6b'
  const heard: { hotwords?: string; language?: string }[] = []
  // Plain: eight words. With the hint: the same eight, one spelled the way the list has it.
  const answers: Record<string, string> = { plain: 'wir nutzen kubernetis fuer die neue immobilien plattform', hinted: 'wir nutzen Kubernetes fuer die neue immobilien plattform' }
  const addon: SherpaAddon = {
    async createOfflineRecognizerAsync(config) { return { config } },
    offlineRecognizerSetConfig() {},
    createOfflineStream() { return { options: {} as Record<string, string> } },
    offlineStreamSetOption(stream, key, value) { (stream as { options: Record<string, string> }).options[key] = value },
    acceptWaveformOffline() {},
    async decodeOfflineStreamAsync(_recognizer, stream) {
      const options = (stream as { options: Record<string, string> }).options
      heard.push({ ...options })
      return JSON.stringify({ text: options.hotwords ? answers.hinted : answers.plain })
    },
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-sherpa-'))
  placed(dir, id)
  const engine = new SherpaEngine(dir, () => {}, () => {}, undefined, () => addon)
  return (async () => {
    try {
      assert.equal(await engine.transcribe(talk(5), id, ['Kubernetes', 'Klammer, auf'], 'de'), answers.hinted)
      // Two decodes, the first without the list; no language is ever given.
      assert.deepEqual(heard, [{}, { hotwords: 'Kubernetes,Klammer auf' }])
      // No word list: one decode, nothing set.
      heard.length = 0
      assert.equal(await engine.transcribe(talk(5), id, [], 'de'), answers.plain)
      assert.deepEqual(heard, [{}])
      // The hint made it drop most of a sentence: the plain text is kept.
      answers.hinted = 'wir nutzen'
      assert.equal(await engine.transcribe(talk(5), id, ['Kubernetes'], 'de'), answers.plain)
    } finally { fs.rmSync(dir, { recursive: true, force: true }) }
  })()
})

test('the hotwords are one comma-separated string of at most 24 words and 240 letters, without commas inside a word', () => {
  assert.equal(hotwordList([]), '')
  assert.equal(hotwordList(['  Kubernetes ', 'Klammer, auf', '', 'zeile\nzwei']), 'Kubernetes,Klammer auf,zeile zwei')
  assert.equal(hotwordList(Array.from({ length: 40 }, (_, i) => `wort${i}`)).split(',').length, 24)
  assert.ok(hotwordList(Array.from({ length: 24 }, () => 'x'.repeat(30))).length <= 240)
  // The first words are the ones that stay.
  assert.ok(hotwordList(['erstes', ...Array.from({ length: 40 }, () => 'y'.repeat(30))]).startsWith('erstes,'))
})

test('the files of a model with a folder arrive in that folder, each under its name only once complete', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-fetch-'))
  try {
    const contents: Record<string, Uint8Array> = { 'vocab.json': new TextEncoder().encode('{"a":1}'), 'merges.txt': new TextEncoder().encode('a b\n') }
    const files = Object.entries(contents).map(([name, body]) => ({ name: `tokenizer/${name}`, role: 'tokenizer' as const, bytes: body.length, sha256: createHash('sha256').update(body).digest('hex') }))
    const source: SherpaSource = { kind: 'qwen3-asr', owner: 'test', repo: 'test', revision: '0'.repeat(40), window: 20, files }
    await fetchFiles(source, dir, () => {}, new AbortController().signal, server(contents))
    assert.deepEqual(fs.readdirSync(path.join(dir, 'tokenizer')).sort(), ['merges.txt', 'vocab.json'])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('Canary 1B v2 follows the language chosen for it like the small one, and gets its second of silence', () => withEngine(async (engine, fake, dir) => {
  const id = 'sherpa/canary-1b-v2'
  placed(dir, id)
  const lang = () => (fake.decoded.at(-1)!.config as { modelConfig: { canary: { srcLang: string; tgtLang: string } } }).modelConfig.canary
  await engine.transcribe(speech(3), id, [], 'de')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['de', 'de'])
  await engine.transcribe(speech(3), id, [], 'de', 'es')
  assert.deepEqual([lang().srcLang, lang().tgtLang], ['es', 'es'])
  assert.equal(fake.configs.length, 1)
  // 3 s of speech and the second after it.
  assert.equal(fake.decoded.at(-1)!.seconds, 4)
  // Cohere's per-stream option is not set for it.
  assert.deepEqual(fake.decoded.at(-1)!.options, {})
}))

test('the German Parakeet takes a dictation of up to four minutes whole, with no language and no options', () => withEngine(async (engine, fake, dir) => {
  const id = 'sherpa/parakeet-german'
  placed(dir, id)
  assert.equal(await engine.transcribe(speech(70), id, ['Kubernetes'], 'en'), 'piece of 70 s')
  assert.deepEqual(fake.decoded.map(piece => piece.options), [{}])
}))

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { WhisperEngine, type Loaded } from '../src/main/whisperEngine'

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 400 && !done(); i++) await tick(2)
  assert.ok(done(), 'timed out')
}

/**
 * Whisper as counts: each load and each disposal is noted, and a disposed
 * model fails the way ONNX Runtime's does. Loading and running take a
 * moment, so a step can happen in the middle of a test.
 */
class CountingEngine extends WhisperEngine {
  loads: string[] = []
  disposals: string[] = []
  protected override async load(id: string): Promise<Loaded> {
    this.loads.push(id)
    await tick(5)
    const model = { disposed: false, dispose: async () => { this.disposals.push(id); model.disposed = true } }
    return { id, processor: null, tokenizer: null, model }
  }
  protected override async run(_samples: Float32Array, { id, model }: Loaded): Promise<string> {
    if (model.disposed) throw new Error('Session already disposed')
    await tick(5)
    return id
  }
}

/** A second of something loud enough to count as speech. */
const speech = new Float32Array(16_000).fill(0.1)
const A = 'onnx-community/whisper-large-v3-turbo'
const B = 'onnx-community/whisper-base'

async function withEngine(body: (engine: CountingEngine, downloaded: (id: string) => Promise<void>) => Promise<void>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-engine-'))
  const ready = new Set<string>()
  const engine = new CountingEngine(dir, () => {}, (id, state) => { if (state.kind === 'ready') ready.add(id) })
  try {
    await body(engine, id => until(() => ready.has(id)))
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
}

test('a download beside the model in use leaves it loaded; the new model is loaded once for its test and let go after', () => withEngine(async (engine, downloaded) => {
  engine.warmUp(A)
  assert.equal(await engine.transcribe(speech, A, [], 'de'), A)
  engine.download(B)
  await downloaded(B)
  assert.deepEqual(engine.disposals, [])
  assert.ok((await engine.measure(B, speech, [], 'de')) >= 0)
  assert.deepEqual(engine.disposals, [B])
  assert.equal(await engine.transcribe(speech, A, [], 'de'), A)
  assert.deepEqual(engine.loads, [A, B])
}))

test('the model in use, downloaded and warmed up on arrival: its test keeps it, and the first dictation loads nothing', () => withEngine(async (engine, downloaded) => {
  engine.download(A)
  await downloaded(A)
  engine.warmUp(A)
  await engine.measure(A, speech, [], 'de')
  assert.equal(await engine.transcribe(speech, A, [], 'de'), A)
  assert.deepEqual(engine.loads, [A])
  assert.deepEqual(engine.disposals, [])
}))

test('a downloaded model nobody uses is let go after its test', () => withEngine(async (engine, downloaded) => {
  engine.download(A)
  await downloaded(A)
  await engine.measure(A, speech, [], 'de')
  assert.deepEqual(engine.disposals, [A])
}))

test('Use during a test: the model under test becomes the one in use without a second load, the old one goes after the test', () => withEngine(async engine => {
  engine.warmUp(A)
  await engine.transcribe(speech, A, [], 'de')
  const measuring = engine.measure(B, speech, [], 'de')
  await until(() => engine.loads.includes(B))
  engine.warmUp(B)
  assert.ok((await measuring) >= 0)
  assert.equal(await engine.transcribe(speech, B, [], 'de'), B)
  assert.deepEqual(engine.loads, [A, B])
  assert.deepEqual(engine.disposals, [A])
}))

test('Remove during a test: the model under test is let go once, after its test; the one in use stays', () => withEngine(async engine => {
  engine.warmUp(A)
  await engine.transcribe(speech, A, [], 'de')
  const measuring = engine.measure(B, speech, [], 'de')
  await until(() => engine.loads.includes(B))
  const removing = engine.release(B)
  assert.ok((await measuring) >= 0)
  await removing
  assert.deepEqual(engine.disposals, [B])
  assert.equal(await engine.transcribe(speech, A, [], 'de'), A)
  assert.deepEqual(engine.loads, [A, B])
}))

const C = 'onnx-community/whisper-small'

test('a dictation finished during a speed test waits for the run under way, not the whole test', () => withEngine(async engine => {
  engine.warmUp(A)
  await engine.transcribe(speech, A, [], 'de')
  const order: string[] = []
  const measured = engine.measure(B, speech, [], 'de').then(() => order.push('measured'), error => order.push(error.message))
  await until(() => engine.loads.includes(B))
  const text = engine.transcribe(speech, A, [], 'de').then(text => { order.push('text'); return text })
  assert.equal(await text, A)
  await measured
  // The test stopped before its timed run and comes again later; its model went.
  assert.deepEqual(order, ['gave way to a dictation', 'text'])
  assert.deepEqual(engine.disposals, [B])
}))

test('downloads whose tests are put off keep at most one model beside the one in use, and leaving Local lets all go', () => withEngine(async (engine, downloaded) => {
  engine.warmUp(A)
  await engine.transcribe(speech, A, [], 'de')
  engine.download(B)
  await downloaded(B)
  engine.download(C)
  await downloaded(C)
  await engine.transcribe(speech, A, [], 'de')
  assert.deepEqual(engine.disposals, [B])
  await engine.unload()
  assert.deepEqual(engine.disposals.sort(), [A, B, C].sort())
}))

/**
 * Whisper's own steps as records: which tokens each decode starts with, and
 * whether the language was asked for (forward). The language check would
 * say English, so a German-only model that asked would show it.
 */
class LanguageEngine extends WhisperEngine {
  decodes: number[][] = []
  asked = 0
  static tokens: Record<string, number> = { '<|endoftext|>': 2, '<|notimestamps|>': 3, '<|transcribe|>': 4, '<|de|>': 5, '<|en|>': 6, '<|startofprev|>': 7 }
  decode(id: string, samples: Float32Array, vocabulary: string[], spoken: 'de' | 'en') {
    const model = {
      generation_config: { decoder_start_token_id: 1 },
      generate: async ({ decoder_input_ids }: { decoder_input_ids: number[][] }) => {
        this.decodes.push(decoder_input_ids[0])
        return { tolist: () => [[...decoder_input_ids[0], 100, 101, 2]] }
      },
      forward: async () => { this.asked++; const logits = new Float32Array(10).fill(-1); logits[6] = 9; return { logits: { data: logits } } },
    }
    const tokenizer = {
      convert_tokens_to_ids: (name: string) => LanguageEngine.tokens[name],
      decode: () => 'Hallo Welt',
      encode: () => [200, 201],
    }
    return this.run(samples, { id, processor: async () => ({ input_features: {} }), tokenizer, model }, vocabulary, spoken)
  }
}

/** Three seconds of speech: long enough that a model for both languages would be asked which it hears. */
const longSpeech = new Float32Array(3 * 16_000).fill(0.1)

test('a German-only model decodes German, with and without the word list, and is never asked which language it hears', async () => {
  const engine = new LanguageEngine(os.tmpdir(), () => {}, () => {})
  assert.equal(await engine.decode('onnx-community/whisper-large-v3-turbo-german-ONNX', longSpeech, ['Kubernetes'], 'en'), 'Hallo Welt')
  assert.deepEqual(engine.decodes, [[1, 5, 4, 3], [7, 200, 201, 1, 5, 4, 3]])
  assert.equal(engine.asked, 0)
})

test('the English-only model decodes English, whatever language is set for short clips', async () => {
  const engine = new LanguageEngine(os.tmpdir(), () => {}, () => {})
  await engine.decode('onnx-community/distil-large-v3.5-ONNX', longSpeech, ['Kubernetes'], 'de')
  await engine.decode('onnx-community/distil-large-v3.5-ONNX', speech, [], 'de')
  assert.deepEqual(engine.decodes, [[1, 6, 4, 3], [7, 200, 201, 1, 6, 4, 3], [1, 6, 4, 3]])
  assert.equal(engine.asked, 0)
})

test('a model for both languages takes the set language for a short clip, in both decodes', async () => {
  const engine = new LanguageEngine(os.tmpdir(), () => {}, () => {})
  await engine.decode('onnx-community/whisper-large-v3-turbo', speech, ['Kubernetes'], 'de')
  assert.deepEqual(engine.decodes, [[1, 5, 4, 3], [7, 200, 201, 1, 5, 4, 3]])
  assert.equal(engine.asked, 0)
})

test('a model for both languages is asked which it hears, and decodes in that one', async () => {
  const engine = new LanguageEngine(os.tmpdir(), () => {}, () => {})
  await engine.decode('onnx-community/whisper-medium-ONNX', longSpeech, [], 'de')
  assert.equal(engine.asked, 1)
  assert.deepEqual(engine.decodes, [[1, 6, 4, 3]])
})

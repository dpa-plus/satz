import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { localModel, localModels, whisperFiles } from '../src/core/localModels'
import { padsEnd } from '../src/core/sherpa'
import { hasSpeech, pieceThreshold, speechEnd, speechThreshold } from '../src/core/speech'
import { windows } from '../src/core/windows'
import { pieceNotHeard, SherpaEngine, type SherpaAddon } from '../src/main/sherpaEngine'
import { WhisperEngine } from '../src/main/whisperEngine'

/**
 * The fixes of the engine review (LE-01 and the sherpa hardening): what
 * counts as speech is decided for the whole recording, a piece that comes
 * back empty is not dropped, Canary gets its second of silence, Parakeet is
 * cut before its encoder's limit. The lifecycle of the helpers is in
 * engineFixLifecycle.test.ts, Whisper's downloads in engineFixWhisper.test.ts.
 */
const rate = 16_000
const concat = (...parts: Float32Array[]) => {
  const all = new Float32Array(parts.reduce((sum, part) => sum + part.length, 0))
  let at = 0
  for (const part of parts) { all.set(part, at); at += part.length }
  return all
}
const silence = (seconds: number) => new Float32Array(Math.round(seconds * rate))
/** A second of sound repeated: a quarter of an hour of speech without a quarter of an hour of making it. */
const tiled = (second: Float32Array, seconds: number) => {
  const all = new Float32Array(Math.round(seconds * rate))
  for (let at = 0; at < all.length; at += second.length) all.set(second.subarray(0, Math.min(second.length, all.length - at)), at)
  return all
}
/** Clear speech: well above any threshold. */
const loud = (seconds: number) => tiled(Float32Array.from({ length: rate }, (_, i) => 0.1 * Math.sin(i / 5)), seconds)
/** Steady noise: a 50 Hz hum at 0.003, which is no speech by its own level. */
const hum = (seconds: number) => Float32Array.from({ length: Math.round(seconds * rate) }, (_, i) => 0.003 * Math.sin(2 * Math.PI * 50 * i / rate))
/**
 * Low-gain speech over hum, as the review's fixture (speech at 0.01 gain, hum
 * at 0.003): bursts at 0.006 for a third of a second in two, over the hum. Its
 * frames are all below -45 dBFS and below three times its own quiet level.
 */
const quietVoice = (seconds: number) => Float32Array.from({ length: Math.round(seconds * rate) }, (_, i) =>
  (Math.floor(i / 2400) % 2 === 0 ? 0.006 * Math.sin(i * 0.2) : 0) + 0.003 * Math.sin(2 * Math.PI * 50 * i / rate))

// MARK: - What counts as speech

test('low-gain speech over hum is no speech by itself, but is once the recording has a silence in it (the review\'s LE-01 fixture)', () => {
  const alone = quietVoice(20)
  const longer = concat(alone, silence(10), loud(5))
  assert.equal(hasSpeech(alone), false)
  assert.equal(hasSpeech(longer), true)
  // Cut at the first quiet moment, the first piece is the 20 s of quiet voice.
  const [first, second] = windows(longer, rate)
  assert.equal(windows(longer, rate).length, 2)
  assert.ok(Math.abs(first.length / rate - 20.05) < 0.05, `${first.length / rate} s`)
  assert.equal(hasSpeech(first), false, 'judged alone it is the same 20 s as above')
  // Judged with the recording's level it is speech: what the engines now ask.
  const whole = speechThreshold(longer)
  assert.equal(hasSpeech(first, rate, pieceThreshold(first, whole)), true)
  assert.equal(hasSpeech(second, rate, pieceThreshold(second, whole)), true)
})

test('a piece is judged by the lower of its own level and the whole recording\'s, so nothing kept before is dropped', () => {
  // Noise all through: the whole recording's level is the noise floor's, high,
  // and a piece of quieter room with speech just above that room is still speech.
  const room = Float32Array.from({ length: 5 * rate }, (_, i) => 0.0004 * Math.sin(i * 0.9) + (Math.floor(i / 4800) % 2 === 0 ? 0.004 * Math.sin(i * 0.2) : 0))
  const noisy = concat(hum(20), room)
  const whole = speechThreshold(noisy)
  assert.ok(whole > speechThreshold(room), `${whole} against ${speechThreshold(room)}`)
  assert.equal(hasSpeech(room, rate, pieceThreshold(room, whole)), hasSpeech(room))
  assert.equal(pieceThreshold(room, whole), speechThreshold(room))
  assert.equal(pieceThreshold(room, 0.0005), 0.0005)
})

test('where the last sound ends: the end of the last 30 ms above the level, nothing for silence', () => {
  const frame = rate * 0.03
  const near = (end: number | null, expected: number) => assert.ok(end !== null && Math.abs(end - expected) < frame, `${end} for ${expected}`)
  near(speechEnd(concat(loud(2), silence(1))), 2 * rate)
  assert.equal(speechEnd(silence(3)), null)
  assert.equal(speechEnd(new Float32Array(0)), null)
  // Judged by a given level, the quiet hum is the last sound.
  const quiet = concat(loud(1), hum(1))
  near(speechEnd(quiet), rate)
  near(speechEnd(quiet, rate, 0.001), 2 * rate)
})

test('a window as short as a few seconds is cut in its quietest moment, nothing lost', () => {
  const audio = concat(loud(4), silence(0.1), loud(4))
  const pieces = windows(audio, rate, 5 * rate)
  assert.equal(pieces.reduce((sum, piece) => sum + piece.length, 0), audio.length)
  assert.ok(pieces.every(piece => piece.length <= 5 * rate))
  assert.ok(Math.abs(pieces[0].length - 4.05 * rate) < 0.05 * rate)
})

// MARK: - The catalog

test('Parakeet is cut before its encoder\'s limit of 400 s; the models made for short clips at 30 s, Qwen3-ASR at 15 s (its decoder holds 512 tokens); only Canary is padded', () => {
  for (const model of localModels.filter(entry => entry.sherpa)) {
    const { kind, window } = model.sherpa!
    assert.equal(window, kind === 'nemo-transducer' ? 240 : kind === 'qwen3-asr' ? 15 : 30, model.id)
    assert.equal(padsEnd(kind), kind === 'canary', model.id)
  }
})

test('each Whisper repo is pinned to a commit, its three files with the size and checksum the repo lists', () => {
  const whisper = localModels.filter(entry => entry.engine === 'whisper')
  assert.equal(whisper.length, 8)
  for (const model of whisper) {
    assert.match(model.whisper!.revision, /^[0-9a-f]{40}$/, model.id)
    assert.deepEqual(model.whisper!.files.map(file => file.name), whisperFiles, model.id)
    assert.equal(model.whisper!.files.reduce((sum, file) => sum + file.bytes, 0), model.bytes, model.id)
    for (const file of model.whisper!.files) {
      if (file.name.endsWith('.onnx')) assert.match(file.sha256 ?? '', /^[0-9a-f]{64}$/, `${model.id} ${file.name}`)
      else assert.match(file.gitOid ?? '', /^[0-9a-f]{40}$/, `${model.id} ${file.name}`)
    }
  }
})

// MARK: - sherpa-onnx pieces

/** sherpa-onnx's native module that hears what `answer` says it hears, and notes every audio it was given. */
function listening(answer: (samples: Float32Array, call: number) => string) {
  const calls: Float32Array[] = []
  const addon: SherpaAddon = {
    async createOfflineRecognizerAsync(config) { return { config: structuredClone(config) } },
    offlineRecognizerSetConfig() {},
    createOfflineStream() { return { samples: new Float32Array(0) } },
    offlineStreamSetOption() {},
    acceptWaveformOffline(stream, wave) { (stream as { samples: Float32Array }).samples = wave.samples },
    async decodeOfflineStreamAsync(_recognizer, stream) {
      const samples = (stream as { samples: Float32Array }).samples
      calls.push(samples)
      return JSON.stringify({ text: answer(samples, calls.length - 1) })
    },
  }
  return { addon, calls }
}

async function hearing(id: string, samples: Float32Array, answer: (samples: Float32Array, call: number) => string, options: { window?: number } = {}): Promise<{ text?: string; error?: Error; calls: number[] }> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-fix-'))
  const folder = path.join(dir, id)
  fs.mkdirSync(folder, { recursive: true })
  for (const file of localModel(id)!.sherpa!.files) fs.writeFileSync(path.join(folder, file.name), '')
  const { addon, calls } = listening(answer)
  const engine = new SherpaEngine(dir, () => {}, () => {}, undefined, () => addon)
  // A shorter window than the catalog's, to have pieces without minutes of audio.
  const source = localModel(id)!.sherpa!
  const window = source.window
  if (options.window) source.window = options.window
  try {
    const outcome = await engine.transcribe(samples, id, [], 'en').then(text => ({ text }), error => ({ error: error as Error }))
    return { ...outcome, calls: calls.map(call => call.length / rate) }
  } finally {
    source.window = window
    await engine.unload()
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

test('LE-01: a piece that only the whole recording\'s level calls speech reaches the recognizer (the 20 s of quiet voice before a silence)', async () => {
  const longer = concat(quietVoice(20), silence(10), loud(5))
  const { text, calls } = await hearing('sherpa/moonshine-tiny', longer, (samples, call) => (call === 0 ? 'the quiet part' : 'the loud part'))
  // Before: only the last piece was sent, and its sentence was the whole answer.
  assert.equal(text, 'the quiet part the loud part')
  assert.equal(calls.length, 2)
  assert.ok(Math.abs(calls[0] - 20.05) < 0.05, JSON.stringify(calls))
})

test('silence and a piece without any sound are still never sent', async () => {
  const { text, calls } = await hearing('sherpa/moonshine-tiny', concat(loud(25), silence(35)), () => 'speech')
  assert.equal(text, 'speech')
  assert.equal(calls.length, 1)
})

test('a piece that comes back empty is tried once more, up to its last sound', async () => {
  // 24 s of speech, a pause (where the first piece ends), 20 s more and a second of quiet at the end.
  const samples = concat(loud(24), silence(0.5), loud(20), silence(1))
  const { text, calls } = await hearing('sherpa/moonshine-tiny', samples, (heard, call) => (call === 0 ? 'first part' : heard.length > 21 * rate ? '' : 'second part'))
  assert.equal(text, 'first part second part')
  assert.equal(calls.length, 3)
  // The second try is the piece without the quiet at its end: shorter by about a second.
  assert.ok(calls[1] - calls[2] > 0.9 && calls[1] - calls[2] < 1.1, JSON.stringify(calls))
})

test('a piece with speech in it that stays empty fails the dictation instead of being dropped', async () => {
  const samples = concat(loud(24), silence(0.5), loud(20), silence(1))
  const result = await hearing('sherpa/moonshine-tiny', samples, (_heard, call) => (call === 0 ? 'first part' : ''))
  // Before: 'first part', and the second piece's words were never asked for again.
  assert.equal(result.text, undefined)
  assert.match(result.error?.message ?? '', new RegExp(pieceNotHeard))
  assert.equal(result.calls.length, 3, 'the piece was tried twice')
})

test('a recording of one piece that comes back empty is the session\'s "not understood", not an error', async () => {
  const result = await hearing('sherpa/moonshine-tiny', concat(loud(5), silence(1)), () => '')
  assert.equal(result.error, undefined)
  assert.equal(result.text, '')
})

test('steady noise louder than the rest, which only the recording\'s lower level lets through, may come back empty without failing the dictation', async () => {
  // Speech, a pure hum piece (no quiet frame of its own to compare with), and a silence at the end that makes the whole recording's level low.
  const samples = concat(loud(9.5), hum(9), silence(3))
  const pieces = windows(samples, rate, 10 * rate)
  const whole = speechThreshold(samples)
  assert.equal(hasSpeech(pieces[1]), false, 'by its own level the hum is no speech')
  assert.equal(hasSpeech(pieces[1], rate, pieceThreshold(pieces[1], whole)), true, 'by the whole recording\'s it is')
  const { text, error, calls } = await hearing('sherpa/moonshine-tiny', samples, (_heard, call) => (call === 0 ? 'the words' : ''), { window: 10 })
  assert.equal(error, undefined)
  assert.equal(text, 'the words')
  assert.ok(calls.length >= 2, 'the hum was sent: a quiet piece of speech is not lost for want of a try')
})

test('Canary gets a second of silence after each piece (and after the second try); the other models get the audio as it is', async () => {
  const samples = concat(loud(3))
  assert.deepEqual((await hearing('sherpa/canary-180m', samples, () => 'ohne Gutschriften')).calls, [4])
  for (const id of ['sherpa/moonshine-tiny', 'sherpa/sense-voice', 'sherpa/parakeet-v3']) assert.deepEqual((await hearing(id, samples, () => 'ohne Gutschriften')).calls, [3], id)
  // Padded with silence, not with anything else.
  let padding = 1
  await hearing('sherpa/canary-180m', samples, heard => { padding = heard.subarray(3 * rate).reduce((sum, value) => sum + Math.abs(value), 0); return 'x' })
  assert.equal(padding, 0)
  // The second try, up to the last sound, is padded too.
  const retried = await hearing('sherpa/canary-180m', concat(loud(3), silence(2)), (_heard, call) => (call === 0 ? '' : 'x'))
  assert.deepEqual(retried.calls.map(Math.round), [6, 4])
})

test('Parakeet takes a recording of any length in pieces it can hold: its encoder refuses more than 400 s', async () => {
  const encoder = (heard: Float32Array) => {
    if (heard.length > 400 * rate) throw new Error('Non-zero status code returned while running Add node: Attempting to broadcast an axis by a dimension other than 1. 250 by 5250')
    return 'words'
  }
  for (const seconds of [239, 420, 900]) {
    const { text, error, calls } = await hearing('sherpa/parakeet-v3', loud(seconds), encoder)
    assert.equal(error, undefined, `${seconds} s: ${error?.message}`)
    assert.ok(calls.every(call => call <= 240), `${seconds} s: ${JSON.stringify(calls)}`)
    assert.equal(calls.length, Math.ceil(seconds / 240), `${seconds} s`)
    assert.equal(text, Array(calls.length).fill('words').join(' '))
    assert.ok(Math.abs(calls.reduce((sum, call) => sum + call, 0) - seconds) < 0.001, 'nothing cut away')
  }
})

// MARK: - Whisper pieces

/**
 * Whisper with a model that notes the audio of each piece it is given and the
 * language each piece was decoded in, answers a word per piece, and, when
 * asked which language it hears, says what `guesses` has next.
 */
class Listening extends WhisperEngine {
  pieces: number[] = []
  languages: number[] = []
  asked = 0
  static tokens: Record<string, number> = { '<|endoftext|>': 2, '<|notimestamps|>': 3, '<|transcribe|>': 4, '<|de|>': 5, '<|en|>': 6, '<|startofprev|>': 7 }
  async hear(samples: Float32Array, options: { id?: string; spoken?: 'de' | 'en'; guesses?: ('de' | 'en')[] } = {}) {
    const guesses = options.guesses ?? []
    const model = {
      generation_config: { decoder_start_token_id: 1 },
      generate: async ({ decoder_input_ids }: { decoder_input_ids: number[][] }) => {
        // The plain decode of each piece (the one with the word list starts with the prompt).
        if (decoder_input_ids[0][0] === 1) this.languages.push(decoder_input_ids[0][1])
        return { tolist: () => [[...decoder_input_ids[0], 100, 2]] }
      },
      forward: async () => {
        const logits = new Float32Array(10).fill(-1)
        logits[Listening.tokens[`<|${guesses[this.asked++] ?? 'en'}|>`]] = 9
        return { logits: { data: logits } }
      },
    }
    const tokenizer = { convert_tokens_to_ids: (name: string) => Listening.tokens[name], decode: () => `piece ${this.pieces.length}`, encode: () => [200] }
    const processor = async (piece: Float32Array) => { this.pieces.push(piece.length / rate); return { input_features: {} } }
    // The English-only model by default: no language to ask for, as the pieces are what the tests look at.
    return this.run(samples, { id: options.id ?? 'onnx-community/distil-large-v3.5-ONNX', processor, tokenizer, model }, [], options.spoken ?? 'en')
  }
}

test('LE-01 on Whisper: the first 29 s window of quiet voice reaches the model once more is said after a silence', async () => {
  const longer = concat(quietVoice(20), silence(9), loud(5))
  const engine = new Listening(os.tmpdir(), () => {}, () => {})
  const text = await engine.hear(longer)
  // Each piece has Whisper's half second of silence in front of it. Before, the first piece was dropped.
  assert.equal(engine.pieces.length, 2, JSON.stringify(engine.pieces))
  assert.ok(Math.abs(engine.pieces[0] - 20.55) < 0.06, JSON.stringify(engine.pieces))
  assert.equal(text, 'piece 1 piece 2')
})

test('Whisper still never hears silence', async () => {
  const engine = new Listening(os.tmpdir(), () => {}, () => {})
  assert.equal(await engine.hear(concat(loud(5), silence(40))), 'piece 1')
  assert.equal(engine.pieces.length, 1)
})

/** 31 s of steady sound with one quiet tenth of a second at 29.45 s: the last piece is the 1.5 s after it (the review's tail). */
const withShortTail = () => {
  const samples = loud(31)
  samples.fill(0, Math.round(29.45 * rate), Math.round(29.55 * rate))
  return samples
}

test('a last piece under two seconds takes the language heard in the pieces before it, not a guess of its own and not the Settings language', async () => {
  const both = 'onnx-community/whisper-tiny'
  // German in the long piece; the tail's own guess would be a coin toss, English here.
  const german = new Listening(os.tmpdir(), () => {}, () => {})
  await german.hear(withShortTail(), { id: both, spoken: 'en', guesses: ['de', 'en'] })
  assert.equal(german.pieces.length, 2, JSON.stringify(german.pieces))
  assert.ok(german.pieces[1] < 2.5, 'the tail is a short piece')
  assert.equal(german.asked, 1, 'the short tail was not asked')
  assert.deepEqual(german.languages, [5, 5])
  // English in the long piece with German set in Settings: the tail is English, too.
  const english = new Listening(os.tmpdir(), () => {}, () => {})
  await english.hear(withShortTail(), { id: both, spoken: 'de', guesses: ['en', 'de'] })
  assert.deepEqual(english.languages, [6, 6])
})

test('a recording of one short piece still takes the language set in Settings; a long one is asked in every piece', async () => {
  const both = 'onnx-community/whisper-tiny'
  const short = new Listening(os.tmpdir(), () => {}, () => {})
  await short.hear(loud(1.5), { id: both, spoken: 'de', guesses: ['en'] })
  assert.deepEqual([short.asked, short.languages], [0, [5]])
  const long = new Listening(os.tmpdir(), () => {}, () => {})
  const samples = concat(loud(25), silence(0.1), loud(10))
  await long.hear(samples, { id: both, spoken: 'en', guesses: ['de', 'en'] })
  assert.equal(long.asked, 2)
  assert.deepEqual(long.languages, [5, 6])
})

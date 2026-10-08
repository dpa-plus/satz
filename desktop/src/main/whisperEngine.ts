import fs from 'node:fs'
import { hasSpeech, keepEveryWord } from '../core/speech'
import { windows } from '../core/windows'
import { markerPath, type LocalState } from './localFiles'

/**
 * Whisper itself: transformers.js on ONNX Runtime, in satz's helper process
 * (local-worker.ts). ONNX Runtime runs on the thread that calls it, so on
 * Electron's main thread every load and every recording froze the shortcut,
 * the card and Settings for seconds.
 */
type Transformers = typeof import('@huggingface/transformers')
/* eslint-disable @typescript-eslint/no-explicit-any -- transformers.js types its models loosely */
interface Loaded { id: string; processor: any; tokenizer: any; model: any }

/** The encoder at 8 bits ran twice as fast as at 4 on a CPU; the decoder at 4 bits loses nothing that was heard. */
const dtype = { encoder_model: 'q8', decoder_model_merged: 'q4' } as const
/** Bytes each model downloads, for a progress bar that does not jump while the file sizes come in. */
const expectedBytes: Record<string, number> = {
  'onnx-community/whisper-large-v3-turbo': 980e6,
  'onnx-community/whisper-small': 250e6,
}
/** Whisper's decoder takes 448 tokens, prompt and answer together; the prompt may have half. */
const contextTokens = 448
const promptTokens = 223
const rate = 16_000
/** Silence before each piece: speech from the very first instant lost its first words. */
const lead = rate / 2

export class WhisperEngine {
  private loaded: { id: string; model: Promise<Loaded> } | null = null
  /** One transcription at a time: they share one model. */
  private queue: Promise<unknown> = Promise.resolve()
  private library: Promise<Transformers> | null = null

  constructor(private dir: string, private log: (message: string) => void, private setState: (id: string, state: LocalState) => void) {}

  private transformers(): Promise<Transformers> {
    this.library ??= import('@huggingface/transformers').then(library => {
      library.env.cacheDir = this.dir
      return library
    })
    return this.library
  }

  // MARK: - Download

  download(id: string) {
    this.setState(id, { kind: 'downloading', fraction: 0 })
    this.log(`local: downloading ${id}`)
    const files = new Map<string, { loaded: number; total: number }>()
    let shown = 0
    const progress = (event: { status: string; file?: string; loaded?: number; total?: number }) => {
      if (event.status !== 'progress' || !event.file || !event.total) return
      files.set(event.file, { loaded: event.loaded ?? 0, total: event.total })
      let loaded = 0
      let total = 0
      for (const file of files.values()) { loaded += file.loaded; total += file.total }
      const fraction = Math.min(1, loaded / Math.max(total, expectedBytes[id] ?? 0))
      // Once a percent: every event redrew the settings page.
      if (Math.floor(fraction * 100) === Math.floor(shown * 100)) return
      shown = fraction
      this.setState(id, fraction >= 0.999 ? { kind: 'preparing' } : { kind: 'downloading', fraction })
    }
    const started = Date.now()
    this.retire(this.loaded)
    const model = this.load(id, progress, false)
    this.loaded = { id, model }
    // The marker inside the chain: a full disk failing it left the download
    // stuck at "preparing" for good.
    model.then(() => {
      fs.mkdirSync(this.dir, { recursive: true })
      fs.writeFileSync(markerPath(this.dir, id), new Date().toISOString())
    }).then(() => {
      this.log(`local: ${id} ready after ${Math.round((Date.now() - started) / 1000)} s`)
      this.setState(id, { kind: 'ready' })
    }, error => {
      if (this.loaded?.model === model) this.loaded = null
      this.log(`local: ${id} failed: ${error?.message ?? error}`)
      this.setState(id, { kind: 'failed', message: String(error?.message ?? error) })
    })
  }

  // MARK: - In memory

  /** Starts loading, so the model is there by the time the speaking is done. */
  warmUp(id: string) {
    this.model(id).catch(() => {})
  }

  /**
   * Gives the memory back, once the transcriptions already queued are done:
   * disposed under one, it failed with "Session already disposed". Queued
   * itself, so a transcription waiting in line that loads the model again
   * does not leave that one in memory.
   */
  async unload(): Promise<void> {
    const job = this.queue.then(async () => {
      const loaded = this.loaded
      this.loaded = null
      if (loaded) await loaded.model.then(({ model }) => model.dispose(), () => {})
    })
    this.queue = job.catch(() => {})
    await job
  }

  /** A model replaced by another: disposed once the running transcription is done with it. */
  private retire(loaded: { id: string; model: Promise<Loaded> } | null) {
    if (loaded) void this.queue.then(() => loaded.model).then(({ model }) => model.dispose(), () => {})
  }

  private model(id: string): Promise<Loaded> {
    if (this.loaded?.id === id) return this.loaded.model
    this.retire(this.loaded)
    const started = Date.now()
    const model = this.load(id)
    this.loaded = { id, model }
    model.then(
      () => this.log(`local: ${id} loaded in ${((Date.now() - started) / 1000).toFixed(1)} s`),
      error => {
        // Tried again by the next dictation.
        this.log(`local: loading ${id} failed: ${error?.message ?? error}`)
        if (this.loaded?.model === model) this.loaded = null
      })
    return model
  }

  private async load(id: string, progress_callback?: (event: any) => void, local_files_only = true): Promise<Loaded> {
    const library = await this.transformers()
    const options = { progress_callback, local_files_only }
    const [processor, tokenizer, model] = await Promise.all([
      library.AutoProcessor.from_pretrained(id, options),
      library.AutoTokenizer.from_pretrained(id, options),
      library.WhisperForConditionalGeneration.from_pretrained(id, { ...options, dtype, device: 'cpu' }),
    ])
    reuseEncoderOutput(model)
    return { id, processor, tokenizer, model }
  }

  // MARK: - Transcribing

  /**
   * @param samples 16 kHz mono, as recorded.
   * @param spoken the language set in Settings, used where a clip is too short to tell.
   */
  transcribe(samples: Float32Array, id: string, vocabulary: string[], spoken: 'de' | 'en' = 'de'): Promise<string> {
    const job = this.queue.then(() => this.run(samples, id, vocabulary, spoken))
    this.queue = job.catch(() => {})
    return job
  }

  private async run(samples: Float32Array, id: string, vocabulary: string[], spoken: 'de' | 'en'): Promise<string> {
    // Whisper makes something up for silence ("you", "Thank you.").
    if (!hasSpeech(samples)) return ''
    const { processor, tokenizer, model } = await this.model(id)
    const { Tensor } = await this.transformers()
    const config = model.generation_config
    const token = (name: string) => tokenizer.convert_tokens_to_ids(name) as number
    const start = config.decoder_start_token_id as number
    const end = token('<|endoftext|>')
    const notimestamps = token('<|notimestamps|>')
    const transcribeToken = token('<|transcribe|>')
    const languages = Object.values(config.lang_to_id) as number[]
    const said: string[] = []
    // 30 s at a time, cut at the quietest moment of each piece's last ten
    // seconds. Whisper's own timestamps were tried for this: without its
    // timestamp rules it often wrote none and a whole window went by, and
    // with them it translated English sentences into German.
    for (const audio of windows(samples, rate, 30 * rate - lead)) {
      if (!hasSpeech(audio)) continue
      const piece = new Float32Array(lead + audio.length)
      piece.set(audio, lead)
      const { input_features } = await processor(piece)
      const decode = async (init: number[]) => {
        const output = await model.generate({ inputs: input_features, decoder_input_ids: [init], max_new_tokens: contextTokens - init.length })
        const ids = (output.tolist()[0] as (number | bigint)[]).map(Number).slice(init.length).filter(t => t !== end)
        return (tokenizer.decode(ids, { skip_special_tokens: true }) as string).replace(/<\|[^|]*\|>/g, ' ').replace(/\s+/g, ' ').trim()
      }
      // transformers.js takes English unless told otherwise. Whisper's first
      // word after the start is the language it hears, asked for in every
      // piece, so German and English both work without a setting. Under two
      // seconds the guess is a coin toss ("Ja." came back as "Yeah."): there
      // the language set in Settings.
      let language = token(`<|${spoken}|>`)
      if (samples.length >= 2 * rate) {
        const step = await model.forward({ input_features, decoder_input_ids: new Tensor('int64', [BigInt(start)], [1, 1]) })
        const logits = step.logits.data as Float32Array
        language = languages.reduce((best, next) => (logits[next] > logits[best] ? next : best))
      }
      let text = await decode([start, language, transcribeToken, notimestamps])
      // The word list, then what was said before this piece, as Whisper's own
      // prompt: text it takes as having come before, so it spells those
      // words the same way. Ends in a full stop: without one, sentences came
      // back without theirs.
      const before = [vocabulary.length ? `${vocabulary.join(', ')}.` : '', said.join(' ')].filter(Boolean).join(' ')
      if (before) {
        const prompt = (tokenizer.encode(` ${before}`, { add_special_tokens: false }) as number[]).slice(-promptTokens)
        const prompted = await decode([token('<|startofprev|>'), ...prompt, start, language, transcribeToken, notimestamps])
        const kept = keepEveryWord(prompted, text)
        if (kept.chosen === 'plain') this.log('local: the word list cost words here, kept the text without it')
        text = kept.text
      }
      if (text) said.push(text)
    }
    return said.join(' ').replace(/\s+/g, ' ').trim()
  }
}

/**
 * The language check runs the encoder, the slow half of Whisper, and
 * generate() would run it again on the very same audio. The second call gets
 * the first one's answer: a dictation took 1.7 s instead of 3 on a Mac's CPU.
 */
function reuseEncoderOutput(model: any) {
  const encoder = model.sessions.model
  const run = encoder.run.bind(encoder)
  let last: { input: unknown; output: unknown } | null = null
  encoder.run = async (feeds: Record<string, unknown>, ...rest: unknown[]) => {
    if (last && feeds.input_features === last.input) return last.output
    const output = await run(feeds, ...rest)
    last = { input: feeds.input_features, output }
    return output
  }
}

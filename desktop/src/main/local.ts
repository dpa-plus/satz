import fs from 'node:fs'
import path from 'node:path'
import { windows } from '../core/windows'

/**
 * Whisper on this computer, for the provider "Lokal": transformers.js on ONNX
 * Runtime, the model downloaded once from Hugging Face into satz's own
 * folder. Nothing leaves the computer and nothing costs anything; the price
 * is the download and the memory a loaded model takes. Like
 * LocalModels.swift on the Mac, which runs Whisper through WhisperKit.
 */
export type LocalState =
  | { kind: 'missing' }
  | { kind: 'downloading'; fraction: number }
  /** Downloaded, while ONNX Runtime builds the model for this computer. */
  | { kind: 'preparing' }
  | { kind: 'ready' }
  | { kind: 'failed'; message: string }

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

export class LocalModels {
  private states = new Map<string, LocalState>()
  private loaded: { id: string; model: Promise<Loaded> } | null = null
  /** One transcription at a time: they share one model. */
  private queue: Promise<unknown> = Promise.resolve()
  private library: Promise<Transformers> | null = null

  constructor(private dir: string, private log: (message: string) => void, private changed: () => void) {}

  state(id: string): LocalState {
    return this.states.get(id) ?? (fs.existsSync(this.marker(id)) ? { kind: 'ready' } : { kind: 'missing' })
  }

  isReady(id: string) { return this.state(id).kind === 'ready' }

  /** Written only once everything has arrived: an interrupted download leaves files that look like a model and are not. */
  private marker(id: string) { return path.join(this.dir, `${id.replace(/\//g, '--')}.ready`) }

  private set(id: string, state: LocalState) {
    this.states.set(id, state)
    this.changed()
  }

  private transformers(): Promise<Transformers> {
    this.library ??= import('@huggingface/transformers').then(library => {
      library.env.cacheDir = this.dir
      return library
    })
    return this.library
  }

  // MARK: - Download

  download(id: string) {
    const now = this.state(id).kind
    if (now === 'downloading' || now === 'preparing') return
    this.set(id, { kind: 'downloading', fraction: 0 })
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
      this.set(id, fraction >= 0.999 ? { kind: 'preparing' } : { kind: 'downloading', fraction })
    }
    const started = Date.now()
    this.unload()
    const model = this.load(id, progress, false)
    this.loaded = { id, model }
    model.then(() => {
      fs.mkdirSync(this.dir, { recursive: true })
      fs.writeFileSync(this.marker(id), new Date().toISOString())
      this.log(`local: ${id} ready after ${Math.round((Date.now() - started) / 1000)} s`)
      this.set(id, { kind: 'ready' })
    }, error => {
      if (this.loaded?.model === model) this.loaded = null
      this.log(`local: ${id} failed: ${error?.message ?? error}`)
      this.set(id, { kind: 'failed', message: String(error?.message ?? error) })
    })
  }

  /** The folder goes to the Trash, like everything satz removes. */
  async remove(id: string, trash: (folder: string) => Promise<void>) {
    if (this.loaded?.id === id) this.unload()
    const folder = path.join(this.dir, id)
    if (fs.existsSync(folder)) await trash(folder)
    fs.rmSync(this.marker(id), { force: true })
    this.set(id, { kind: 'missing' })
    this.log(`local: ${id} moved to the Trash`)
  }

  // MARK: - In memory

  /** Starts loading, so the model is there by the time the speaking is done. */
  warmUp(id: string) {
    if (this.isReady(id)) this.model(id).catch(() => {})
  }

  /** Gives the memory back, when another provider is chosen. */
  unload() {
    const loaded = this.loaded
    if (!loaded) return
    this.loaded = null
    loaded.model.then(({ model }) => model.dispose(), () => {})
  }

  private model(id: string): Promise<Loaded> {
    if (this.loaded?.id === id) return this.loaded.model
    this.unload()
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

  /** @param samples 16 kHz mono, as recorded. */
  transcribe(samples: Float32Array, id: string, vocabulary: string[]): Promise<string> {
    const job = this.queue.then(() => this.run(samples, id, vocabulary))
    this.queue = job.catch(() => {})
    return job
  }

  private async run(samples: Float32Array, id: string, vocabulary: string[]): Promise<string> {
    const { processor, tokenizer, model } = await this.model(id)
    const { Tensor } = await this.transformers()
    const config = model.generation_config
    const token = (name: string) => tokenizer.convert_tokens_to_ids(name) as number
    const start = config.decoder_start_token_id as number
    const languages = Object.values(config.lang_to_id) as number[]
    let language: number | null = null
    const said: string[] = []
    for (const piece of windows(samples)) {
      const { input_features } = await processor(piece)
      // transformers.js takes English unless told otherwise. Whisper's first
      // word after the start is the language it hears: asked for once, so
      // German and English both work without a setting.
      if (language === null) {
        const step = await model.forward({ input_features, decoder_input_ids: new Tensor('int64', [BigInt(start)], [1, 1]) })
        const logits = step.logits.data as Float32Array
        language = languages.reduce((best, next) => (logits[next] > logits[best] ? next : best))
      }
      const decode = async (before: string) => {
        const prompt = before ? (tokenizer.encode(` ${before}`, { add_special_tokens: false }) as number[]).slice(-promptTokens) : []
        const init = [...(prompt.length ? [token('<|startofprev|>'), ...prompt] : []), start, language, token('<|transcribe|>'), token('<|notimestamps|>')]
        const output = await model.generate({ inputs: input_features, decoder_input_ids: [init], max_new_tokens: contextTokens - init.length })
        const ids = (output.tolist()[0] as (number | bigint)[]).map(Number)
        return (tokenizer.decode(ids.slice(init.length), { skip_special_tokens: true }) as string).replace(/<\|[^|]*\|>/g, '').trim()
      }
      // The word list, then what was said before this piece, as Whisper's own
      // prompt: text it takes as having come before, so it spells those
      // words the same way. Ends in a full stop: without one, sentences came
      // back without theirs.
      const before = [vocabulary.length ? `${vocabulary.join(', ')}.` : '', said.join(' ')].filter(Boolean).join(' ')
      let text = await decode('')
      if (before) {
        const kept = keepEveryWord(await decode(before), text)
        if (kept.chosen === 'plain') this.log('local: the word list cost words here, kept the text without it')
        text = kept.text
      }
      if (text) said.push(text)
    }
    return said.join(' ').replace(/\s+/g, ' ')
  }
}

/**
 * With a prompt, Whisper sometimes leaves out what does not fit it: an
 * English sentence in a German recording was dropped every time. Its prompt
 * is worth having only when the text keeps every word, so the text without
 * one is the check; the audio was encoded once for both.
 */
export function keepEveryWord(prompted: string, plain: string): { text: string; chosen: 'prompted' | 'plain' } {
  const words = (text: string) => text.split(/\s+/).filter(Boolean).length
  return words(prompted) >= 0.85 * words(plain) ? { text: prompted, chosen: 'prompted' } : { text: plain, chosen: 'plain' }
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

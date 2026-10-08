import fs from 'node:fs'
import { germanOrEnglish, localModel } from '../core/localModels'
import { hasSpeech, keepEveryWord } from '../core/speech'
import { windows } from '../core/windows'
import { gaveWay, markerPath, type LocalState } from './localFiles'

/**
 * Whisper itself: transformers.js on ONNX Runtime, in satz's helper process
 * (local-worker.ts). ONNX Runtime runs on the thread that calls it, so on
 * Electron's main thread every load and every recording froze the shortcut,
 * the card and Settings for seconds.
 */
type Transformers = typeof import('@huggingface/transformers')
/* eslint-disable @typescript-eslint/no-explicit-any -- transformers.js types its models loosely */
export interface Loaded { id: string; processor: any; tokenizer: any; model: any }
/** A model in memory, or on its way there. */
interface Held { id: string; model: Promise<Loaded> }

/** The encoder at 8 bits ran twice as fast as at 4 on a CPU; the decoder at 4 bits loses nothing that was heard. */
const dtype = { encoder_model: 'q8', decoder_model_merged: 'q4' } as const
/** Whisper's decoder takes 448 tokens, prompt and answer together; the prompt may have half. */
const contextTokens = 448
const promptTokens = 223
const rate = 16_000
/** Silence before each piece: speech from the very first instant lost its first words. */
const lead = rate / 2

export class WhisperEngine {
  /** The model dictations use. */
  private loaded: Held | null = null
  /**
   * Models held for their speed test, beside the one in use: downloading or
   * trying another model took the one in use out of memory, and the next
   * dictation waited for it to load again.
   */
  private trials = new Map<string, Held>()
  /** One transcription at a time: they share one model. */
  private queue: Promise<unknown> = Promise.resolve()
  private library: Promise<Transformers> | null = null
  private disposed = new WeakSet<Held>()
  /** A dictation queued since the speed test began: the test stops before its next run. */
  private dictationWaiting = false

  constructor(private dir: string, private log: (message: string) => void, private setState: (id: string, state: LocalState) => void) {}

  private transformers(): Promise<Transformers> {
    this.library ??= import('@huggingface/transformers').then(library => {
      library.env.cacheDir = this.dir
      return library
    })
    return this.library
  }

  // MARK: - Download

  /** Fetches the files and loads the model for its speed test, which satz asks for next (`measure`). */
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
      const fraction = Math.min(1, loaded / Math.max(total, localModel(id)?.bytes ?? 0))
      // Once a percent: every event redrew the settings page.
      if (Math.floor(fraction * 100) === Math.floor(shown * 100)) return
      shown = fraction
      this.setState(id, fraction >= 0.999 ? { kind: 'preparing' } : { kind: 'downloading', fraction })
    }
    const started = Date.now()
    this.retireTrials()
    const trial: Held = { id, model: this.load(id, progress, false) }
    this.trials.set(id, trial)
    // The marker inside the chain: a full disk failing it left the download
    // stuck at "preparing" for good.
    trial.model.then(() => {
      fs.mkdirSync(this.dir, { recursive: true })
      fs.writeFileSync(markerPath(this.dir, id), new Date().toISOString())
    }).then(() => {
      this.log(`local: ${id} ready after ${Math.round((Date.now() - started) / 1000)} s`)
      this.setState(id, { kind: 'ready' })
    }, error => {
      if (this.trials.get(id) === trial) this.trials.delete(id)
      this.log(`local: ${id} failed: ${error?.message ?? error}`)
      this.setState(id, { kind: 'failed', message: String(error?.message ?? error) })
    })
  }

  // MARK: - Speed

  /**
   * How long `id` takes for `samples`: the clip goes through the same path
   * as a dictation (word list included, so a second decode counts), twice,
   * and the second, warm run is timed. In the dictations' queue, so it never
   * shares the processor with one. A model that is not the one in use is
   * loaded for this alone and let go afterwards.
   * @returns milliseconds of the second run
   */
  measure(id: string, samples: Float32Array, vocabulary: string[], spoken: 'de' | 'en'): Promise<number> {
    const job = this.queue.then(async () => {
      this.dictationWaiting = false
      let own: Held | null = null
      if (this.loaded?.id !== id) {
        own = this.trials.get(id) ?? { id, model: this.load(id) }
        this.retireTrials(id)
        // Where choosing it in the meantime takes it over instead of loading a copy.
        this.trials.set(id, own)
      }
      try {
        const model = await (own ? own.model : this.model(id))
        // A dictation finished during the test waits for at most the run
        // under way, not for the rest of the test (seconds with Large v3).
        if (this.dictationWaiting) throw new Error(gaveWay)
        await this.run(samples, model, vocabulary, spoken)
        if (this.dictationWaiting) throw new Error(gaveWay)
        const started = performance.now()
        await this.run(samples, model, vocabulary, spoken)
        return performance.now() - started
      } finally {
        if (own && this.trials.get(id) === own) {
          this.trials.delete(id)
          await this.dispose(own)
        }
      }
    })
    this.queue = job.catch(() => {})
    return job
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
      if (loaded) await this.dispose(loaded)
      // Those held for a test go too: Local is not wanted any more.
      const trials = [...this.trials.values()]
      this.trials.clear()
      for (const held of trials) await this.dispose(held)
    })
    this.queue = job.catch(() => {})
    await job
  }

  /** Lets go of one model, in use or held for a test, so its files can go. */
  async release(id: string): Promise<void> {
    const job = this.queue.then(async () => {
      for (const held of [this.loaded, this.trials.get(id)]) if (held?.id === id) await this.dispose(held)
      if (this.loaded?.id === id) this.loaded = null
      this.trials.delete(id)
    })
    this.queue = job.catch(() => {})
    await job
  }

  /**
   * At most one model beside the one in use: downloads that finished while
   * their tests waited for a dictation each kept theirs in memory. A test
   * that comes later loads its model again.
   */
  private retireTrials(except?: string) {
    for (const [id, held] of this.trials) {
      if (id === except) continue
      this.trials.delete(id)
      this.retire(held)
    }
  }

  /** A model replaced by another: disposed once the running transcription is done with it. */
  private retire(held: Held | null) {
    if (held) void this.queue.then(() => this.dispose(held))
  }

  /** Once per model: twice failed with "Session already disposed", which nothing caught. */
  private async dispose(held: Held) {
    if (this.disposed.has(held)) return
    this.disposed.add(held)
    await held.model.then(({ model }) => model.dispose()).catch(() => {})
  }

  private model(id: string): Promise<Loaded> {
    if (this.loaded?.id === id) return this.loaded.model
    this.retire(this.loaded)
    // The model just tested is taken over rather than loaded a second time.
    const trial = this.trials.get(id)
    this.trials.delete(id)
    const started = Date.now()
    const held: Held = trial ?? { id, model: this.load(id) }
    this.loaded = held
    held.model.then(
      () => { if (!trial) this.log(`local: ${id} loaded in ${((Date.now() - started) / 1000).toFixed(1)} s`) },
      error => {
        // Tried again by the next dictation.
        this.log(`local: loading ${id} failed: ${error?.message ?? error}`)
        if (this.loaded === held) this.loaded = null
      })
    return held.model
  }

  /** Protected, like `run`: the tests put a model in its place that counts its loads and disposals. */
  protected async load(id: string, progress_callback?: (event: any) => void, local_files_only = true): Promise<Loaded> {
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
    // Whisper makes something up for silence ("you", "Thank you.").
    this.dictationWaiting = true
    const job = this.queue.then(async () => (hasSpeech(samples) ? this.run(samples, await this.model(id), vocabulary, spoken) : ''))
    this.queue = job.catch(() => {})
    return job
  }

  protected async run(samples: Float32Array, { processor, tokenizer, model }: Loaded, vocabulary: string[], spoken: 'de' | 'en'): Promise<string> {
    const { Tensor } = await this.transformers()
    const config = model.generation_config
    const token = (name: string) => tokenizer.convert_tokens_to_ids(name) as number
    const start = config.decoder_start_token_id as number
    const end = token('<|endoftext|>')
    const notimestamps = token('<|notimestamps|>')
    const transcribeToken = token('<|transcribe|>')
    const languages = { de: token('<|de|>'), en: token('<|en|>') }
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
      const decode = async (init: number[], longest = contextTokens) => {
        const output = await model.generate({ inputs: input_features, decoder_input_ids: [init], max_new_tokens: Math.min(longest, contextTokens - init.length) })
        const ids = (output.tolist()[0] as (number | bigint)[]).map(Number).slice(init.length).filter(t => t !== end)
        return { tokens: ids.length, text: (tokenizer.decode(ids, { skip_special_tokens: true }) as string).replace(/<\|[^|]*\|>/g, ' ').replace(/\s+/g, ' ').trim() }
      }
      // transformers.js takes English unless told otherwise. Whisper's first
      // word after the start is the language it hears, asked for in every
      // piece and read for German and English only (germanOrEnglish), so
      // both work without a setting. Under two seconds the guess is a coin
      // toss ("Ja." came back as "Yeah."): there the language set in Settings.
      let language = token(`<|${spoken}|>`)
      if (samples.length >= 2 * rate) {
        const step = await model.forward({ input_features, decoder_input_ids: new Tensor('int64', [BigInt(start)], [1, 1]) })
        language = germanOrEnglish(step.logits.data as Float32Array, languages) ?? language
      }
      const plain = await decode([start, language, transcribeToken, notimestamps])
      let text = plain.text
      // The word list, then what was said before this piece, as Whisper's own
      // prompt: text it takes as having come before, so it spells those
      // words the same way. Ends in a full stop: without one, sentences came
      // back without theirs. Nothing heard stays nothing (keepEveryWord), so
      // then there is nothing to ask.
      const before = [vocabulary.length ? `${vocabulary.join(', ')}.` : '', said.join(' ')].filter(Boolean).join(' ')
      if (before && text) {
        const prompt = (tokenizer.encode(` ${before}`, { add_special_tokens: false }) as number[]).slice(-promptTokens)
        // Kept only when about as long as the plain text, so it never needs
        // much more room. A prompt Whisper kept repeating ("Klammer zu
        // Klammer zu …" over English speech) ran to the full 448 tokens: 4.6 s
        // of Turbo's time for text that was thrown away.
        const prompted = (await decode([token('<|startofprev|>'), ...prompt, start, language, transcribeToken, notimestamps], 2 * plain.tokens + 20)).text
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

import { AsyncLocalStorage } from 'node:async_hooks'
import type { Language } from '../core/language'
import { germanOrEnglish, onlyLanguage } from '../core/localModels'
import { hasSpeech, keepEveryWord } from '../core/speech'
import { windows } from '../core/windows'
import { LocalEngine } from './localEngine'
import type { LocalState } from './localFiles'

/**
 * Whisper itself: transformers.js on ONNX Runtime, in satz's Whisper helper
 * process (local-worker.ts). ONNX Runtime runs on the thread that calls it,
 * so on Electron's main thread every load and every recording froze the
 * shortcut, the card and Settings for seconds. What a model's life looks
 * like (in memory, tested, queued) is LocalEngine's.
 */
type Transformers = typeof import('@huggingface/transformers')
/* eslint-disable @typescript-eslint/no-explicit-any -- transformers.js types its models loosely */
export interface Loaded { id: string; processor: any; tokenizer: any; model: any }

/** The encoder at 8 bits ran twice as fast as at 4 on a CPU; the decoder at 4 bits loses nothing that was heard. */
const dtype = { encoder_model: 'q8', decoder_model_merged: 'q4' } as const
/** Whisper's decoder takes 448 tokens, prompt and answer together; the prompt may have half. */
const contextTokens = 448
const promptTokens = 223
const rate = 16_000
/** Silence before each piece: speech from the very first instant lost its first words. */
const lead = rate / 2

export class WhisperEngine extends LocalEngine<Loaded> {
  private library: Promise<Transformers> | null = null
  /**
   * The signal of the download a fetch belongs to, carried along with all of
   * that download's work. One field for it was cleared as soon as the first
   * part failed, while transformers.js went on fetching the other parts:
   * without a signal, past Cancel.
   */
  private download$ = new AsyncLocalStorage<AbortSignal>()

  /** @param fetcher Electron's net.fetch in the helper, put in globalThis.fetch there; asked for at each file. */
  constructor(dir: string, log: (message: string) => void, setState: (id: string, state: LocalState) => void,
    private fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init)) {
    super(dir, log, setState)
  }

  private transformers(): Promise<Transformers> {
    this.library ??= import('@huggingface/transformers').then(library => {
      library.env.cacheDir = this.dir
      // Every file transformers.js fetches for a download carries its signal, so Cancel stops it.
      library.env.fetch = ((url: string, init?: RequestInit) => {
        const signal = this.download$.getStore()
        signal?.throwIfAborted()
        return this.fetcher(url, { ...init, signal })
      }) as typeof fetch
      return library
    })
    return this.library
  }

  /** transformers.js fetches the files while it loads the model; its events are per file, the fraction is of all of them. */
  protected async fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal): Promise<Loaded> {
    const files = new Map<string, { loaded: number; total: number }>()
    const onEvent = (event: { status: string; file?: string; loaded?: number; total?: number }) => {
      if (event.status !== 'progress' || !event.file || !event.total) return
      files.set(event.file, { loaded: event.loaded ?? 0, total: event.total })
      let loaded = 0
      let total = 0
      for (const file of files.values()) { loaded += file.loaded; total += file.total }
      progress(loaded / Math.max(total, this.expectedBytes(id)))
    }
    return this.download$.run(signal, () => this.load(id, onEvent, false))
  }

  protected async free({ model }: Loaded) {
    await model.dispose()
  }

  /**
   * Protected, like `run`: the tests put a model in its place that counts its
   * loads and disposals. Settles once all three parts have: the first one
   * failing (a cancelled download) used to end it while the others still
   * fetched and wrote. A model that did load is let go then.
   */
  protected async load(id: string, progress_callback?: (event: any) => void, local_files_only = true): Promise<Loaded> {
    const library = await this.transformers()
    const options = { progress_callback, local_files_only }
    const parts: PromiseSettledResult<any>[] = await Promise.allSettled([
      library.AutoProcessor.from_pretrained(id, options),
      library.AutoTokenizer.from_pretrained(id, options),
      library.WhisperForConditionalGeneration.from_pretrained(id, { ...options, dtype, device: 'cpu' }),
    ])
    const [processor, tokenizer, model] = parts.map(part => (part.status === 'fulfilled' ? part.value : undefined))
    const failed = parts.find(part => part.status === 'rejected')
    if (failed) {
      await model?.dispose().catch(() => {})
      throw failed.reason
    }
    reuseEncoderOutput(model)
    return { id, processor, tokenizer, model }
  }

  // MARK: - Transcribing

  protected async run(samples: Float32Array, { id, processor, tokenizer, model }: Loaded, vocabulary: string[], spoken: Language): Promise<string> {
    const only = onlyLanguage(id)
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
      // A model for one language is never asked: it gets its own, in both
      // decodes below.
      let language = token(`<|${only ?? spoken}|>`)
      if (!only && samples.length >= 2 * rate) {
        const { Tensor } = await this.transformers()
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

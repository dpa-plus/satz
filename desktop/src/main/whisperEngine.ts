import { AsyncLocalStorage } from 'node:async_hooks'
import { createHash } from 'node:crypto'
import path from 'node:path'
import type { Language } from '../core/language'
import { germanOrEnglish, localModel, onlyLanguage, type WhisperFile, type WhisperSource } from '../core/localModels'
import { hasSpeech, keepEveryWord, pieceThreshold, speechThreshold } from '../core/speech'
import { windows } from '../core/windows'
import { LocalEngine } from './localEngine'
import { removeStaleTemps, type LocalState } from './localFiles'

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

/**
 * transformers.js asks for `<host>/<repo>/resolve/main/<file>`. The same
 * address at the commit the catalog names, and which of the model's three
 * files it is (the others are small JSON, fetched as they are). Not an
 * address on `main`: then it would be fetched unpinned, so it is an error.
 * transformers.js's own `revision` option would do the first, but moves every
 * file to a folder named for the commit, and the models already downloaded
 * would be gone.
 */
export function pinnedRequest(id: string, source: WhisperSource, url: string): { url: string; file?: WhisperFile } {
  const address = new URL(url)
  const base = `/${id}/resolve/main/`
  if (!address.pathname.startsWith(base)) throw new Error(`${id}: ${url} is not on the main branch, cannot pin it`)
  const name = address.pathname.slice(base.length)
  address.pathname = `/${id}/resolve/${source.revision}/${name}`
  return { url: address.href, file: source.files.find(file => file.name === decodeURIComponent(name)) }
}

/**
 * The same response, whose body fails at its end unless it is exactly the file
 * the catalog names: the right size and checksum. transformers.js writes a
 * file to `<file>.tmp…` and gives it its name when the body has been read; a
 * body that ends in an error removes the temp file instead, so nothing damaged
 * ever sits under the name the model is loaded from. (Too long a body fails at
 * once: no need to fill the disk with it first.)
 */
export function checked(response: Response, file: WhisperFile): Response {
  // tokenizer.json is a plain git file: its id is a SHA-1 over a header and the content.
  const hash = createHash(file.sha256 ? 'sha256' : 'sha1')
  if (!file.sha256) hash.update(`blob ${file.bytes}\0`)
  let loaded = 0
  const check = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      loaded += chunk.length
      if (loaded > file.bytes) throw new Error(`${file.name} arrived damaged`)
      hash.update(chunk)
      controller.enqueue(chunk)
    },
    flush() {
      if (loaded !== file.bytes || hash.digest('hex') !== (file.sha256 ?? file.gitOid)) throw new Error(`${file.name} arrived damaged`)
    },
  })
  return new Response(response.body!.pipeThrough(check), { status: response.status, statusText: response.statusText, headers: response.headers })
}

export class WhisperEngine extends LocalEngine<Loaded> {
  private library: Promise<Transformers> | null = null
  /**
   * The download a fetch belongs to (its signal and the model), carried along
   * with all of that download's work. One field for it was cleared as soon as
   * the first part failed, while transformers.js went on fetching the other
   * parts: without a signal, past Cancel.
   */
  private download$ = new AsyncLocalStorage<{ signal: AbortSignal; id: string }>()

  /** @param fetcher Electron's net.fetch in the helper, put in globalThis.fetch there; asked for at each file. */
  constructor(dir: string, log: (message: string) => void, setState: (id: string, state: LocalState) => void,
    private fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init)) {
    super(dir, log, setState)
  }

  private transformers(): Promise<Transformers> {
    this.library ??= import('@huggingface/transformers').then(library => {
      library.env.cacheDir = this.dir
      // Every file transformers.js fetches for a download carries its signal,
      // so Cancel stops it, and comes from the commit the catalog names, its
      // three big files checked on the way in. (A model typed in by hand has
      // no commit to name.)
      library.env.fetch = (async (url: string, init?: RequestInit) => {
        const download = this.download$.getStore()
        download?.signal.throwIfAborted()
        const source = download && localModel(download.id)?.whisper
        const asked = source ? pinnedRequest(download!.id, source, String(url)) : { url, file: undefined }
        const response = await this.fetcher(asked.url, { ...init, signal: download?.signal })
        // A range request (transformers.js asks for the size that way) is 206, not the file.
        return asked.file && response.status === 200 && response.body ? checked(response, asked.file) : response
      }) as typeof fetch
      return library
    })
    return this.library
  }

  /** transformers.js fetches the files while it loads the model; its events are per file, the fraction is of all of them. */
  protected async fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal): Promise<Loaded> {
    // What an earlier try left half written when this helper (or satz) stopped
    // in the middle: transformers.js writes under a new name each time.
    removeStaleTemps(path.join(this.dir, id))
    const files = new Map<string, { loaded: number; total: number }>()
    const onEvent = (event: { status: string; file?: string; loaded?: number; total?: number }) => {
      if (event.status !== 'progress' || !event.file || !event.total) return
      files.set(event.file, { loaded: event.loaded ?? 0, total: event.total })
      let loaded = 0
      let total = 0
      for (const file of files.values()) { loaded += file.loaded; total += file.total }
      progress(loaded / Math.max(total, this.expectedBytes(id)))
    }
    return this.download$.run({ signal, id }, () => this.load(id, onEvent, false))
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
    /** The language the pieces so far were heard in. */
    let heard: number | undefined
    // What is quiet is decided once, for the whole recording: judged alone, a
    // piece of low-gain speech over hum was dropped as soon as more was said
    // after a silence (see pieceThreshold).
    const whole = speechThreshold(samples, rate)
    // 30 s at a time, cut at the quietest moment of each piece's last ten
    // seconds. Whisper's own timestamps were tried for this: without its
    // timestamp rules it often wrote none and a whole window went by, and
    // with them it translated English sentences into German.
    for (const audio of windows(samples, rate, 30 * rate - lead)) {
      if (!hasSpeech(audio, rate, pieceThreshold(audio, whole, rate))) continue
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
      // toss ("Ja." came back as "Yeah."): the piece, not the recording, is
      // what counts there, since the last piece of a long dictation is often
      // a few words ("Ja, genau." became "yeah, good now."). Such a piece
      // takes the language of the pieces before it, one recording being in
      // one language, else the language set in Settings. A model for one
      // language is never asked: it gets its own, in both decodes below.
      let language = heard ?? token(`<|${only ?? spoken}|>`)
      if (!only && audio.length >= 2 * rate) {
        const { Tensor } = await this.transformers()
        const step = await model.forward({ input_features, decoder_input_ids: new Tensor('int64', [BigInt(start)], [1, 1]) })
        heard = germanOrEnglish(step.logits.data as Float32Array, languages) ?? heard
        language = heard ?? language
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

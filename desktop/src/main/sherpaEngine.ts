import { createHash } from 'node:crypto'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import v8 from 'node:v8'
import vm from 'node:vm'
import type { Language } from '../core/language'
import { localModel } from '../core/localModels'
import { sherpaConfig, sherpaPackage, sherpaURL, tidySherpaText, type SherpaConfig, type SherpaSource } from '../core/sherpa'
import { hasSpeech } from '../core/speech'
import { windows } from '../core/windows'
import { LocalEngine } from './localEngine'
import type { LocalState } from './localFiles'

/**
 * Handy's models on sherpa-onnx, in satz's second helper process
 * (sherpa-worker.ts). Not in Whisper's: sherpa-onnx brings its own ONNX
 * Runtime (1.28.2, onnxruntime-node has 1.30.0), and on Windows both are
 * onnxruntime.dll. Windows hands a DLL that is already loaded to whoever
 * asks for the same name next, so in one process one of the two would run
 * on the other's runtime.
 */

/** What sherpa-onnx's native module offers for offline recognition. */
export interface SherpaAddon {
  createOfflineRecognizerAsync(config: SherpaConfig): Promise<unknown>
  offlineRecognizerSetConfig(recognizer: unknown, config: SherpaConfig): void
  createOfflineStream(recognizer: unknown): unknown
  acceptWaveformOffline(stream: unknown, wave: { samples: Float32Array; sampleRate: number }): void
  decodeOfflineStreamAsync(recognizer: unknown, stream: unknown): Promise<string>
  /** "1.13.8", and the ONNX Runtime it brings ("1.28.2"). */
  version?: string
  onnxruntimeVersion?: string
}

/** A model in memory: its recognizer, and the config it was made with, which Canary's language changes. */
export interface SherpaLoaded { id: string; recognizer: unknown; config: SherpaConfig; language: string }

const rate = 16_000

/**
 * V8's collector. Electron's helper processes do not expose it even when
 * started with --expose-gc (the flag reached the process and did nothing),
 * so the flag is set from inside and the function taken from a new context.
 */
function collector(): (() => void) | undefined {
  try {
    v8.setFlagsFromString('--expose-gc')
    return vm.runInNewContext('gc') as () => void
  } catch { return undefined }
}

/**
 * sherpa-onnx's native module, without sherpa-onnx-node's JavaScript, which
 * looks for it only inside app.asar. In the package it lies beside the
 * archive (build/after-pack.cjs puts it there): a native library inside it
 * could not load the ONNX Runtime next to it. Elsewhere (npm start, the
 * tests) it is the npm package for this system.
 */
export function loadAddon(): SherpaAddon {
  const name = sherpaPackage(process.platform, process.arch)
  const packaged = path.join(__dirname, '..', '..', 'app.asar.unpacked', 'node_modules', name, 'sherpa-onnx.node')
  return createRequire(__filename)(fs.existsSync(packaged) ? packaged : `${name}/sherpa-onnx.node`) as SherpaAddon
}

/**
 * Threads for one recognizer. Parakeet V3 took 0.31 s for 10 s of speech
 * with four on an M5 Pro, 0.29 s with eight and 0.61 s with one: four is
 * nearly all of it, and leaves the rest of the computer usable meanwhile.
 */
const threads = () => Math.max(1, Math.min(4, os.availableParallelism()))

/** A file's SHA-256, read in pieces: Parakeet's encoder is 650 MB. */
async function sha256(file: string, signal: AbortSignal): Promise<string> {
  const hash = createHash('sha256')
  for await (const chunk of fs.createReadStream(file, { signal })) hash.update(chunk as Buffer)
  return hash.digest('hex')
}

/**
 * Fetches each file into the model's folder as `<name>.part`, checks its
 * size and checksum, and only then gives it its name. A file already there
 * (from a download that stopped halfway) is kept only if its checksum is
 * right too: one of the right size was taken as it was, damaged or not.
 * `progress` gets the bytes of the whole model that have arrived.
 */
export async function fetchFiles(source: SherpaSource, folder: string, progress: (bytes: number) => void, signal: AbortSignal, fetcher: typeof fetch) {
  fs.mkdirSync(folder, { recursive: true })
  let done = 0
  for (const file of source.files) {
    const target = path.join(folder, file.name)
    if (fs.existsSync(target)) {
      if (fs.statSync(target).size === file.bytes && await sha256(target, signal) === file.sha256) {
        done += file.bytes
        progress(done)
        continue
      }
      fs.rmSync(target, { force: true })
    }
    const part = `${target}.part`
    const response = await fetcher(sherpaURL(source, file.name), { signal })
    if (!response.ok || !response.body) throw new Error(`${file.name}: status ${response.status}`)
    const hash = createHash('sha256')
    const out = await fs.promises.open(part, 'w')
    let loaded = 0
    try {
      const reader = response.body.getReader()
      for (;;) {
        signal.throwIfAborted()
        const { done: end, value } = await reader.read()
        if (end) break
        hash.update(value)
        await out.write(value)
        loaded += value.length
        progress(done + loaded)
      }
    } finally {
      await out.close()
    }
    if (loaded !== file.bytes || hash.digest('hex') !== file.sha256) {
      fs.rmSync(part, { force: true })
      throw new Error(`${file.name} arrived damaged`)
    }
    fs.renameSync(part, target)
    done += file.bytes
  }
}

export class SherpaEngine extends LocalEngine<SherpaLoaded> {
  private addon: SherpaAddon | null = null
  private collect = collector()

  /** @param fetcher Electron's net.fetch in the helper, put in globalThis.fetch there; asked for at each download. */
  constructor(dir: string, log: (message: string) => void, setState: (id: string, state: LocalState) => void,
    private fetcher: typeof fetch = (input, init) => globalThis.fetch(input, init), private loadNative: () => SherpaAddon = loadAddon) {
    super(dir, log, setState)
  }

  private native() {
    if (!this.addon) {
      this.addon = this.loadNative()
      // Which build runs, and whether the memory of a model let go comes back at once (free below).
      this.log(`local: sherpa-onnx ${this.addon.version ?? '?'} on ONNX Runtime ${this.addon.onnxruntimeVersion ?? '?'}, ${threads()} threads, ${this.collect ? 'collector at hand' : 'no collector'}`)
    }
    return this.addon
  }

  private source(id: string): SherpaSource {
    const source = localModel(id)?.sherpa
    if (!source) throw new Error(`${id} is not a sherpa-onnx model`)
    return source
  }

  protected async fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal): Promise<SherpaLoaded> {
    const source = this.source(id)
    const total = source.files.reduce((sum, file) => sum + file.bytes, 0)
    await fetchFiles(source, path.join(this.dir, id), bytes => progress(bytes / total), signal, this.fetcher)
    return this.load(id)
  }

  protected async load(id: string): Promise<SherpaLoaded> {
    const folder = path.join(this.dir, id)
    const config = sherpaConfig(this.source(id), name => path.join(folder, name), 'de', threads())
    // Off the helper's own thread, like every decode: it keeps answering while a model loads.
    const recognizer = await this.native().createOfflineRecognizerAsync(config)
    return { id, recognizer, config, language: 'de' }
  }

  /**
   * The word list is not passed: these models take no prompt (the
   * replacements still apply). A language goes to Canary only, which cannot
   * tell by itself: the one chosen for it, else the one set in Settings.
   */
  protected async run(samples: Float32Array, loaded: SherpaLoaded, _vocabulary: string[], spoken: Language, told?: string): Promise<string> {
    const source = this.source(loaded.id)
    const language = told ?? spoken
    if (source.kind === 'canary' && loaded.language !== language) {
      Object.assign(loaded.config.modelConfig.canary as object, { srcLang: language, tgtLang: language })
      this.native().offlineRecognizerSetConfig(loaded.recognizer, loaded.config)
      loaded.language = language
    }
    const said: string[] = []
    for (const piece of source.windowed ? windows(samples, rate) : [samples]) {
      if (!hasSpeech(piece)) continue
      const stream = this.native().createOfflineStream(loaded.recognizer)
      this.native().acceptWaveformOffline(stream, { samples: piece, sampleRate: rate })
      const { text } = JSON.parse(await this.native().decodeOfflineStreamAsync(loaded.recognizer, stream)) as { text?: string }
      const tidy = tidySherpaText(text ?? '')
      if (tidy) said.push(tidy)
    }
    return said.join(' ').replace(/\s+/g, ' ').trim()
  }

  /**
   * sherpa-onnx-node frees a recognizer when it is garbage collected and has
   * no call for it: collected now, the memory comes back now rather than
   * whenever the collector gets round to it. (Not all of it: local.ts ends
   * the helper when nothing is left to hold.)
   */
  protected async free(loaded: SherpaLoaded) {
    loaded.recognizer = null
    this.collect?.()
  }
}

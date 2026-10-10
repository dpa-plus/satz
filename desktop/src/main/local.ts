import { utilityProcess, type UtilityProcess } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { engineOf, secondsPer10, type LocalModel, type Speed } from '../core/localModels'
import { gaveWay, isDownloaded, isModelId, machineName, markerPath, readSpeed, removeStaleTemps, writeSpeed, type LocalState } from './localFiles'

export type { LocalState } from './localFiles'

type Engine = LocalModel['engine']

type Waiter = { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void }

/** Starts a helper process: Electron's utilityProcess.fork, a stand-in in the tests. */
export type Fork = (script: string, args: string[], options: { serviceName: string }) => UtilityProcess
const electronFork: Fork = (script, args, options) => utilityProcess.fork(script, args, options)

/**
 * One helper process, started when first needed. Each process keeps its own
 * waiting requests: one that was stopped on purpose fails nothing that went
 * to the one started after it.
 */
class Helper {
  private current: { worker: UtilityProcess; waiting: Map<number, Waiter> } | null = null

  /** @param stopped a crash, not a stop asked for: the downloads it had under way fail. */
  constructor(private script: string, private name: string, private dir: string, private fork: Fork,
    private receive: (message: Record<string, unknown>) => void, private stopped: () => void, private log: (message: string) => void) {}

  get running() { return this.current !== null }
  /** Nothing waiting for an answer. */
  get idle() { return !this.current || this.current.waiting.size === 0 }

  post(message: Record<string, unknown>) {
    this.start().worker.postMessage(message)
  }

  ask(message: Record<string, unknown>, request: number): Promise<Record<string, unknown>> {
    const current = this.start()
    return new Promise((resolve, reject) => {
      current.waiting.set(request, { resolve, reject })
      current.worker.postMessage({ ...message, request })
    })
  }

  /** Ends the process, and with it all the memory it held. */
  stop() {
    const current = this.current
    if (!current) return
    this.current = null
    this.log(`local: ${this.name} let go`)
    current.worker.kill()
  }

  private start() {
    if (this.current) return this.current
    const worker = this.fork(path.join(__dirname, this.script), [this.dir], { serviceName: this.name })
    const current = { worker, waiting: new Map<number, Waiter>() }
    worker.on('message', (message: Record<string, unknown>) => {
      const request = message.request as number
      const waiter = current.waiting.get(request)
      if (message.type === 'result' || message.type === 'done') { waiter?.resolve(message); current.waiting.delete(request) }
      else if (message.type === 'error') { waiter?.reject(new Error(message.message as string)); current.waiting.delete(request) }
      else this.receive(message)
    })
    // A fatal error in the helper: logged; its exit then fails what waits.
    worker.on('error', (type: string, location: string) => this.log(`local: ${this.name} error ${type} at ${location}`))
    worker.on('exit', code => {
      for (const { reject } of current.waiting.values()) reject(new Error(`${this.name} stopped`))
      current.waiting.clear()
      if (this.current !== current) return
      this.current = null
      this.log(`local: ${this.name} stopped (${code})`)
      this.stopped()
    })
    this.current = current
    return current
  }
}

export interface LocalModelsOptions {
  /** Starts a helper process; Electron's utilityProcess.fork unless a test gives its own. */
  fork?: Fork
  /**
   * false: nothing in the models folder is downloaded, removed or swept. A
   * test copy of satz that was not given a folder of its own would be using
   * the real satz's models, and must not change them (like the Mac's
   * LaunchMode.canChangeModels).
   */
  canChangeFiles?: boolean
}

/**
 * The models on this computer, for the provider "Lokal": Whisper on
 * transformers.js and ONNX Runtime, and Handy's models on sherpa-onnx, each
 * downloaded once from Hugging Face into satz's own folder. Nothing leaves
 * the computer and nothing costs anything; the price is the download and
 * the memory a loaded model takes. Like LocalModels.swift on the Mac.
 *
 * Each engine runs in a helper process of its own (local-worker.ts,
 * sherpa-worker.ts): ONNX Runtime blocks the thread it runs on, which on
 * the main thread froze the shortcut, the card and Settings for seconds, and
 * the two engines bring two ONNX Runtimes that must not share a process
 * (sherpaEngine.ts says why). This side keeps the states and sends each
 * model's work to its engine.
 */
export class LocalModels {
  private states = new Map<string, LocalState>()
  /** Models whose speed test is running. */
  private measuring = new Set<string>()
  private helpers: Record<Engine, Helper>
  private requests = 0
  /**
   * The model Local should have in memory: the one in use while Local is the
   * provider, none otherwise. A helper told to let go checks it again once
   * it has: a switch away and straight back, made while a dictation held up
   * the unload, ended the helper of the model just chosen again.
   */
  private wanted: string | null = null
  /** A download that arrived complete: satz may start using it, and measures its speed. */
  onArrived: (id: string) => void = () => {}

  private canChangeFiles: boolean

  constructor(private dir: string, private log: (message: string) => void, private changed: () => void, private version: string, options: LocalModelsOptions = {}) {
    const fork = options.fork ?? electronFork
    this.canChangeFiles = options.canChangeFiles ?? true
    const make = (engine: Engine, script: string, name: string) =>
      new Helper(script, name, dir, fork, message => this.receive(message), () => this.helperStopped(engine), log)
    this.helpers = { whisper: make('whisper', 'local-worker.js', 'satz Whisper'), sherpa: make('sherpa', 'sherpa-worker.js', 'satz sherpa-onnx') }
    // Before any helper runs: what a satz that quit in the middle of a download left behind.
    if (this.canChangeFiles) {
      const removed = removeStaleTemps(dir)
      if (removed.length) log(`local: removed ${removed.length} half-written file${removed.length === 1 ? '' : 's'} of a download that was cut off`)
    }
  }

  private helperFor(id: string) { return this.helpers[engineOf(id)] }

  state(id: string): LocalState {
    return this.states.get(id) ?? (isDownloaded(this.dir, id) ? { kind: 'ready' } : { kind: 'missing' })
  }

  isReady(id: string) { return this.state(id).kind === 'ready' }
  isMeasuring(id: string) { return this.measuring.has(id) }
  speed(id: string): Speed | null { return readSpeed(this.dir, id) }

  /** One download at a time: two at once halved both, and the second one's button was what the user was waiting on. */
  get downloading() {
    return [...this.states.values()].some(state => state.kind === 'downloading' || state.kind === 'preparing')
  }

  private set(id: string, state: LocalState) {
    const was = this.states.get(id)?.kind
    // Ready and missing come from the disk from now on.
    if (state.kind === 'ready' || state.kind === 'missing') this.states.delete(id)
    else this.states.set(id, state)
    const wasDownloading = was === 'downloading' || was === 'preparing'
    if (state.kind === 'ready' && wasDownloading) this.onArrived(id)
    this.changed()
    // A download that ended without a model (failed, cancelled) was the
    // helper's last work if nothing is wanted of it; one that arrived is
    // followed by its speed test, which looks again when it is over.
    if (wasDownloading && (state.kind === 'failed' || state.kind === 'missing')) void this.letGo(engineOf(id))
  }

  /** A helper that crashed fails the downloads it had under way. */
  private helperStopped(engine: Engine) {
    for (const [id, state] of this.states) {
      if (engineOf(id) === engine && (state.kind === 'downloading' || state.kind === 'preparing')) this.set(id, { kind: 'failed', message: 'stopped' })
    }
  }

  private receive(message: Record<string, unknown>) {
    if (message.type === 'state') this.set(message.id as string, message.state as LocalState)
    if (message.type === 'log') this.log(message.message as string)
  }

  private ask(helper: Helper, message: Record<string, unknown>) {
    return helper.ask(message, ++this.requests)
  }

  /** A download or a speed test under way in this engine's helper. */
  private busy(engine: Engine) {
    return [...this.states].some(([id, state]) => engineOf(id) === engine && (state.kind === 'downloading' || state.kind === 'preparing'))
      || [...this.measuring].some(id => engineOf(id) === engine)
  }

  /**
   * The helper lets go of every model, once what is queued is done, and then
   * ends if nothing else needs it: ONNX Runtime keeps much of a model's
   * memory after letting go of it (700 MB of Parakeet's 1.9 GB, more with
   * each load), and only the process ending gives it all back. The next
   * model starts it again. Asked again whenever the work that kept the
   * helper alive is over (a download, a speed test): a switch to another
   * provider made meanwhile found it busy and left it running for good.
   */
  private async letGo(engine: Engine) {
    const helper = this.helpers[engine]
    if (!helper.running || this.wantedOn(engine)) return
    await this.ask(helper, { type: 'unload' }).catch(() => {})
    // Chosen again while the unload waited behind a dictation: the unload
    // took that model too, so it loads again, and the helper stays.
    const wanted = this.wanted
    if (wanted && this.wantedOn(engine)) helper.post({ type: 'warmUp', id: wanted })
    else if (helper.idle && !this.busy(engine)) helper.stop()
  }

  private wantedOn(engine: Engine) { return this.wanted !== null && engineOf(this.wanted) === engine }

  /** Fetches the files beside the model in use, which stays loaded. */
  download(id: string) {
    if (!isModelId(id) || this.downloading) return
    if (!this.canChangeFiles) return this.log(`local: not downloading ${id}, a test copy needs --models-dir for that`)
    this.set(id, { kind: 'downloading', fraction: 0 })
    this.helperFor(id).post({ type: 'download', id })
  }

  /** Stops a download; what it fetched goes, and the model is "missing" again. */
  cancel(id: string) {
    const kind = this.states.get(id)?.kind
    if (isModelId(id) && kind === 'downloading') this.helperFor(id).post({ type: 'cancel', id })
  }

  /**
   * Times the model on `clip` (16 kHz mono) through the dictations' own path
   * and queue, and keeps the answer beside it. A model that is not in use is
   * loaded for the test alone.
   */
  async measure(id: string, clip: Float32Array, vocabulary: string[], spoken: 'de' | 'en', told?: string): Promise<'done' | 'deferred' | 'failed'> {
    if (!this.isReady(id) || this.measuring.has(id)) return 'failed'
    this.measuring.add(id)
    this.changed()
    // Asked again after a dictation: the helper is still needed.
    let again = false
    try {
      const { ms } = await this.ask(this.helperFor(id), { type: 'measure', id, samples: clip, vocabulary, spoken, told })
      const speed: Speed = { secondsPer10: secondsPer10(Number(ms), clip.length / 16_000), date: new Date().toISOString(), version: this.version, machine: machineName() }
      writeSpeed(this.dir, id, speed)
      this.log(`local: ${id} takes ${speed.secondsPer10.toFixed(1)} s per 10 s of speech`)
      return 'done'
    } catch (error) {
      if ((error as Error).message === gaveWay) {
        again = true
        this.log(`local: ${id}'s speed test gave way to a dictation, again later`)
        return 'deferred'
      }
      this.log(`local: measuring ${id} failed: ${(error as Error).message}`)
      return 'failed'
    } finally {
      this.measuring.delete(id)
      this.changed()
      // The last of a download's work, for a model nobody uses: a download
      // started on another provider, or on the other engine than the one in use.
      if (!again) void this.letGo(engineOf(id))
    }
  }

  /** The folder goes to the Trash, like everything satz removes, once the engine has let go of it. The model in use stays loaded when another goes. */
  async remove(id: string, trash: (folder: string) => Promise<void>) {
    if (!isModelId(id)) return
    if (!this.canChangeFiles) return this.log(`local: not removing ${id}, a test copy needs --models-dir for that`)
    const helper = this.helperFor(id)
    if (helper.running) await this.ask(helper, { type: 'release', id }).catch(() => {})
    const folder = path.join(this.dir, id)
    if (fs.existsSync(folder)) await trash(folder)
    fs.rmSync(markerPath(this.dir, id), { force: true })
    this.set(id, { kind: 'missing' })
    this.log(`local: ${id} moved to the Trash`)
  }

  /**
   * Starts loading, so the model is there by the time the speaking is done.
   * The other engine lets go of its model: one model in use, one in memory.
   */
  warmUp(id: string) {
    if (!this.isReady(id)) return
    this.wanted = id
    this.helperFor(id).post({ type: 'warmUp', id })
    for (const engine of Object.keys(this.helpers) as Engine[]) if (engine !== engineOf(id)) void this.letGo(engine)
  }

  /** Gives the memory back, when another provider is chosen, after any transcription still running. */
  async unload() {
    this.wanted = null
    await Promise.all((Object.keys(this.helpers) as Engine[]).map(engine => this.letGo(engine)))
  }

  /**
   * @param samples 16 kHz mono, as recorded.
   * @param spoken the language set in Settings, for clips too short to tell.
   * @param told the language a model that cannot tell (Canary) listens for.
   */
  transcribe(samples: Float32Array, id: string, vocabulary: string[], spoken: 'de' | 'en', told?: string): Promise<string> {
    // A speed test in the other helper stops before its next run: it would share the processor with this dictation.
    for (const helper of Object.values(this.helpers)) if (helper !== this.helperFor(id) && helper.running) helper.post({ type: 'dictationElsewhere' })
    return this.ask(this.helperFor(id), { type: 'transcribe', id, vocabulary, samples, spoken, told }).then(({ text }) => String(text ?? ''))
  }
}

import fs from 'node:fs'
import path from 'node:path'
import type { Language } from '../core/language'
import { localModel } from '../core/localModels'
import { hasSpeech } from '../core/speech'
import { gaveWay, markerPath, type LocalState } from './localFiles'

/** A model in memory, or on its way there. */
interface Held<Model> { id: string; model: Promise<Model> }

/** Why a download stopped: the user cancelled it (the helper's error message). */
export const cancelled = 'cancelled'

/**
 * What both engines on this computer share: the model dictations use, held
 * in memory, models held for their speed test beside it, one queue for
 * every run, the download with its progress and Cancel, and the speed test
 * that gives way to a dictation. Whisper (whisperEngine.ts) and sherpa-onnx
 * (sherpaEngine.ts) each run in their own helper process and fill in how a
 * model is fetched, loaded, run and let go.
 */
export abstract class LocalEngine<Model> {
  /** The model dictations use. */
  private loaded: Held<Model> | null = null
  /**
   * Models held for their speed test, beside the one in use: downloading or
   * trying another model took the one in use out of memory, and the next
   * dictation waited for it to load again.
   */
  private trials = new Map<string, Held<Model>>()
  /** One transcription at a time: they share one model and the processor. */
  private queue: Promise<unknown> = Promise.resolve()
  private disposed = new WeakSet<Held<Model>>()
  /** A dictation queued since the speed test began: the test stops before its next run. */
  private dictationWaiting = false
  /** Downloads under way, for Cancel. */
  private downloads = new Map<string, AbortController>()

  constructor(protected dir: string, protected log: (message: string) => void, private setState: (id: string, state: LocalState) => void) {}

  /**
   * Fetches the model's files and loads it, which proves they work.
   * `progress` takes the fraction of all bytes that have arrived. Settles
   * only once all of its work has stopped, also after `signal` aborts: the
   * folder of a cancelled download is removed then, and nothing may still
   * be writing into it.
   */
  protected abstract fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal): Promise<Model>
  /** Loads a model that is on the computer. */
  protected abstract load(id: string): Promise<Model>
  /**
   * @param spoken the language set in Settings (German or English), for clips too short to tell.
   * @param told the language a model that cannot tell (Canary) listens for; `spoken` where not given.
   */
  protected abstract run(samples: Float32Array, model: Model, vocabulary: string[], spoken: Language, told?: string): Promise<string>
  protected abstract free(model: Model): Promise<void>

  // MARK: - Download

  /** Fetches the files and loads the model for its speed test, which satz asks for next (`measure`). */
  download(id: string) {
    if (this.downloads.has(id)) return
    const controller = new AbortController()
    this.downloads.set(id, controller)
    this.setState(id, { kind: 'downloading', fraction: 0 })
    this.log(`local: downloading ${id}`)
    let shown = 0
    let settled = false
    const progress = (fraction: number) => {
      // A file still arriving after Cancel took the card back to "downloading", for good.
      if (controller.signal.aborted || settled) return
      fraction = Math.min(1, Math.max(0, fraction))
      // Once a percent: every event redrew the settings page.
      if (Math.floor(fraction * 100) === Math.floor(shown * 100)) return
      shown = fraction
      this.setState(id, fraction >= 0.999 ? { kind: 'preparing' } : { kind: 'downloading', fraction })
    }
    const started = Date.now()
    this.retireTrials()
    const trial: Held<Model> = { id, model: this.fetchAndLoad(id, progress, controller.signal) }
    this.trials.set(id, trial)
    // The marker inside the chain: a full disk failing it left the download
    // stuck at "preparing" for good.
    trial.model.finally(() => { settled = true }).then(() => {
      if (controller.signal.aborted) throw new Error(cancelled)
      fs.mkdirSync(path.dirname(markerPath(this.dir, id)), { recursive: true })
      fs.writeFileSync(markerPath(this.dir, id), new Date().toISOString())
    }).then(() => {
      this.log(`local: ${id} ready after ${Math.round((Date.now() - started) / 1000)} s`)
      this.setState(id, { kind: 'ready' })
    }, error => {
      if (this.trials.get(id) === trial) this.trials.delete(id)
      if (controller.signal.aborted) {
        // What arrived is of no use: a model is complete or it is not there.
        // Removed once nothing writes to it any more.
        if (!fs.existsSync(markerPath(this.dir, id))) fs.rmSync(path.join(this.dir, id), { recursive: true, force: true })
        this.log(`local: ${id} cancelled`)
        this.setState(id, { kind: 'missing' })
        return
      }
      this.log(`local: ${id} failed: ${error?.message ?? error}`)
      this.setState(id, { kind: 'failed', message: String(error?.message ?? error) })
    }).finally(() => this.downloads.delete(id))
  }

  /** Stops a download under way; what it fetched goes. */
  cancel(id: string) {
    this.downloads.get(id)?.abort(new Error(cancelled))
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
  measure(id: string, samples: Float32Array, vocabulary: string[], spoken: Language, told?: string): Promise<number> {
    const job = this.queue.then(async () => {
      this.dictationWaiting = false
      let own: Held<Model> | null = null
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
        await this.run(samples, model, vocabulary, spoken, told)
        if (this.dictationWaiting) throw new Error(gaveWay)
        const started = performance.now()
        await this.run(samples, model, vocabulary, spoken, told)
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

  /**
   * A dictation is on its way to the other engine's helper: a test running
   * here stops before its next run, as for a dictation of its own, so the
   * two do not share the processor for long.
   */
  dictationElsewhere() {
    this.dictationWaiting = true
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
      // Those held for a test go too: Local is not wanted any more. Not
      // waited for here: one may be a download still under way, and the
      // dictation queued next waited for all of it.
      const trials = [...this.trials.values()]
      this.trials.clear()
      for (const held of trials) void this.dispose(held)
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
  private retire(held: Held<Model> | null) {
    if (held) void this.queue.then(() => this.dispose(held))
  }

  /** Once per model: twice failed with "Session already disposed", which nothing caught. */
  private async dispose(held: Held<Model>) {
    if (this.disposed.has(held)) return
    this.disposed.add(held)
    await held.model.then(model => this.free(model)).catch(() => {})
  }

  private model(id: string): Promise<Model> {
    if (this.loaded?.id === id) return this.loaded.model
    this.retire(this.loaded)
    // The model just tested is taken over rather than loaded a second time.
    const trial = this.trials.get(id)
    this.trials.delete(id)
    const started = Date.now()
    const held: Held<Model> = trial ?? { id, model: this.load(id) }
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

  // MARK: - Transcribing

  /**
   * @param samples 16 kHz mono, as recorded.
   * @param spoken the language set in Settings, used where a clip is too short to tell.
   * @param told the language a model that cannot tell (Canary) listens for.
   */
  transcribe(samples: Float32Array, id: string, vocabulary: string[], spoken: Language = 'de', told?: string): Promise<string> {
    // Every model makes something up for silence ("you", "Thank you.").
    this.dictationWaiting = true
    const job = this.queue.then(async () => (hasSpeech(samples) ? this.run(samples, await this.model(id), vocabulary, spoken, told) : ''))
    this.queue = job.catch(() => {})
    return job
  }

  /** The catalog's byte count, for progress before a server says how big a file is. */
  protected expectedBytes(id: string) {
    return localModel(id)?.bytes ?? 0
  }
}

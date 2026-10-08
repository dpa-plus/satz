import { utilityProcess, type UtilityProcess } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { isDownloaded, markerPath, type LocalState } from './localFiles'

export type { LocalState } from './localFiles'

/**
 * Whisper on this computer, for the provider "Lokal": transformers.js on ONNX
 * Runtime, the model downloaded once from Hugging Face into satz's own
 * folder. Nothing leaves the computer and nothing costs anything; the price
 * is the download and the memory a loaded model takes. Like
 * LocalModels.swift on the Mac, which runs Whisper through WhisperKit.
 *
 * Whisper itself runs in a helper process (local-worker.ts, whisperEngine.ts):
 * ONNX Runtime blocks the thread it runs on, and on the main thread that
 * froze the shortcut, the card and Settings for seconds. This side keeps the
 * states and talks to it.
 */
export class LocalModels {
  private states = new Map<string, LocalState>()
  private worker: UtilityProcess | null = null
  private waiting = new Map<number, { resolve: (value: string) => void; reject: (error: Error) => void }>()
  private requests = 0

  constructor(private dir: string, private log: (message: string) => void, private changed: () => void) {}

  state(id: string): LocalState {
    return this.states.get(id) ?? (isDownloaded(this.dir, id) ? { kind: 'ready' } : { kind: 'missing' })
  }

  isReady(id: string) { return this.state(id).kind === 'ready' }

  private set(id: string, state: LocalState) {
    // Ready and missing come from the disk from now on.
    if (state.kind === 'ready' || state.kind === 'missing') this.states.delete(id)
    else this.states.set(id, state)
    this.changed()
  }

  private helper(): UtilityProcess {
    if (this.worker) return this.worker
    const worker = utilityProcess.fork(path.join(__dirname, 'local-worker.js'), [this.dir], { serviceName: 'satz Whisper' })
    worker.on('message', message => this.receive(message))
    // A fatal error in the helper: logged; its exit then fails what waits.
    worker.on('error', (type: string, location: string) => this.log(`local: helper error ${type} at ${location}`))
    worker.on('exit', code => {
      if (this.worker === worker) this.worker = null
      this.log(`local: helper stopped (${code})`)
      for (const { reject } of this.waiting.values()) reject(new Error('Whisper stopped'))
      this.waiting.clear()
      for (const [id, state] of this.states) if (state.kind === 'downloading' || state.kind === 'preparing') this.set(id, { kind: 'failed', message: 'Whisper stopped' })
    })
    this.worker = worker
    return worker
  }

  private receive(message: { type: string; id?: string; state?: LocalState; message?: string; request?: number; text?: string }) {
    switch (message.type) {
      case 'state': this.set(message.id!, message.state!); break
      case 'log': this.log(message.message!); break
      case 'result': case 'done': this.waiting.get(message.request!)?.resolve(message.text ?? ''); this.waiting.delete(message.request!); break
      case 'error': this.waiting.get(message.request!)?.reject(new Error(message.message)); this.waiting.delete(message.request!); break
    }
  }

  private ask(message: Record<string, unknown>): Promise<string> {
    return new Promise((resolve, reject) => {
      const request = ++this.requests
      this.waiting.set(request, { resolve, reject })
      this.helper().postMessage({ ...message, request })
    })
  }

  download(id: string) {
    const now = this.state(id).kind
    if (now === 'downloading' || now === 'preparing') return
    this.set(id, { kind: 'downloading', fraction: 0 })
    this.helper().postMessage({ type: 'download', id })
  }

  /** The folder goes to the Trash, like everything satz removes, once Whisper has let go of it. */
  async remove(id: string, trash: (folder: string) => Promise<void>) {
    await this.unload()
    const folder = path.join(this.dir, id)
    if (fs.existsSync(folder)) await trash(folder)
    fs.rmSync(markerPath(this.dir, id), { force: true })
    this.set(id, { kind: 'missing' })
    this.log(`local: ${id} moved to the Trash`)
  }

  /** Starts loading, so the model is there by the time the speaking is done. */
  warmUp(id: string) {
    if (this.isReady(id)) this.helper().postMessage({ type: 'warmUp', id })
  }

  /** Gives the memory back, when another provider is chosen, after any transcription still running. */
  async unload() {
    if (this.worker) await this.ask({ type: 'unload' }).catch(() => {})
  }

  /** @param samples 16 kHz mono, as recorded. @param spoken the language set in Settings, for clips too short to tell. */
  transcribe(samples: Float32Array, id: string, vocabulary: string[], spoken: 'de' | 'en'): Promise<string> {
    return this.ask({ type: 'transcribe', id, vocabulary, samples, spoken })
  }
}

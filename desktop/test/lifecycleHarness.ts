import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import type { UtilityProcess } from 'electron'
import { localModel } from '../src/core/localModels'
import { serve, type Port } from '../src/main/helper'
import { LocalModels, type Fork, type LocalModelsOptions } from '../src/main/local'
import { LocalEngine } from '../src/main/localEngine'
import { markerPath } from '../src/main/localFiles'

/**
 * What the lifecycle tests of LocalModels share: helper processes as objects
 * in this process, around an engine whose runs and downloads can be held open.
 * Everything else is satz's own: LocalModels, the helper's message loop,
 * LocalEngine.
 */
export const tick = () => new Promise(resolve => setImmediate(resolve))
export async function until(done: () => boolean) {
  for (let i = 0; i < 400 && !done(); i++) await tick()
  assert.ok(done(), 'timed out')
}
export const gate = () => { let open = () => {}; const opened = new Promise<void>(resolve => { open = resolve }); return { opened, open } }

export interface FakeModel { id: string; freed: boolean }

export class Fake extends LocalEngine<FakeModel> {
  live = new Set<FakeModel>()
  runs: string[] = []
  running: ReturnType<typeof gate> | null = null
  fetching: ReturnType<typeof gate> | null = null
  protected async fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal) {
    await this.fetching?.opened
    signal.throwIfAborted()
    progress(1)
    return this.load(id)
  }
  protected async load(id: string) { const model = { id, freed: false }; this.live.add(model); return model }
  protected async free(model: FakeModel) { model.freed = true; this.live.delete(model) }
  protected async run(_samples: Float32Array, model: FakeModel) {
    this.runs.push(model.id)
    await this.running?.opened
    assert.equal(model.freed, false, 'let go of during its own run')
    return model.id
  }
}

export interface FakeWorker extends EventEmitter { script: string; killed: boolean; messages: string[]; engine: Fake; postMessage(data: { type: string }): void; kill(): boolean }

/** Every helper the code forks lands in `workers`; `kill()` ends one a moment later, as a process does. */
export function fakeFork(workers: FakeWorker[]): Fork {
  return (script, args) => {
    const worker = Object.assign(new EventEmitter(), { script: path.basename(script), killed: false, messages: [] as string[] }) as FakeWorker
    const listeners: ((event: { data: unknown }) => void)[] = []
    const port: Port = { on: (_event, listener) => listeners.push(listener), postMessage: message => setImmediate(() => { if (!worker.killed) worker.emit('message', message) }) }
    worker.postMessage = data => { worker.messages.push(data.type); setImmediate(() => { if (!worker.killed) listeners.forEach(listener => listener({ data })) }) }
    worker.kill = () => { worker.killed = true; setImmediate(() => worker.emit('exit', 0)); return true }
    serve((dir, log, setState) => (worker.engine = new Fake(dir, log, setState)), port, args[0])
    workers.push(worker)
    return worker as unknown as UtilityProcess
  }
}

/** A Whisper model, and a sherpa-onnx one. */
export const A = 'onnx-community/whisper-base'
export const B = 'sherpa/moonshine-tiny'
export const speech = new Float32Array(16_000).fill(0.1)

/** The files a model has when it is downloaded. */
export function place(dir: string, id: string) {
  const files = localModel(id)!.sherpa?.files.map(file => file.name) ?? ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']
  for (const file of files) { fs.mkdirSync(path.dirname(path.join(dir, id, file)), { recursive: true }); fs.writeFileSync(path.join(dir, id, file), 'x') }
}

/** A and B on the computer, as downloaded. */
export function setup(options: Omit<LocalModelsOptions, 'fork'> = {}, present = [A, B]) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lifecycle-'))
  for (const id of present) { place(dir, id); fs.writeFileSync(markerPath(dir, id), 'now') }
  const workers: FakeWorker[] = []
  const logs: string[] = []
  const local = new LocalModels(dir, message => logs.push(message), () => {}, 'test', { ...options, fork: fakeFork(workers) })
  const last = (script: string) => workers.filter(worker => worker.script === script).at(-1)
  return { local, dir, workers, logs, whisper: () => last('local-worker.js'), sherpa: () => last('sherpa-worker.js') }
}

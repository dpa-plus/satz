import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import type { UtilityProcess } from 'electron'
import { localModel } from '../src/core/localModels'
import { serve, type Port } from '../src/main/helper'
import { LocalModels, type Fork } from '../src/main/local'
import { LocalEngine } from '../src/main/localEngine'
import { markerPath } from '../src/main/localFiles'

const tick = () => new Promise(resolve => setImmediate(resolve))
async function until(done: () => boolean) {
  for (let i = 0; i < 400 && !done(); i++) await tick()
  assert.ok(done(), 'timed out')
}
const gate = () => { let open = () => {}; const opened = new Promise<void>(resolve => { open = resolve }); return { opened, open } }

interface FakeModel { id: string; freed: boolean }

/** An engine whose runs and downloads can be held open. Everything else is satz's own: LocalModels, the helper's message loop, LocalEngine. */
class Fake extends LocalEngine<FakeModel> {
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

/** Helper processes as objects in this process: what satz posts reaches serve(), what serve() posts comes back. */
interface FakeWorker extends EventEmitter { script: string; killed: boolean; messages: string[]; engine: Fake; postMessage(data: { type: string }): void; kill(): boolean }
function fakeFork(workers: FakeWorker[]): Fork {
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

const A = 'onnx-community/whisper-base'
const B = 'sherpa/moonshine-tiny'
const speech = new Float32Array(16_000).fill(0.1)

/** A and B on the computer, as downloaded. */
function setup(): { local: LocalModels; whisper: () => FakeWorker | undefined; dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lifecycle-'))
  for (const id of [A, B]) {
    const files = localModel(id)!.sherpa?.files.map(file => file.name) ?? ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']
    for (const file of files) { fs.mkdirSync(path.dirname(path.join(dir, id, file)), { recursive: true }); fs.writeFileSync(path.join(dir, id, file), 'x') }
    fs.writeFileSync(markerPath(dir, id), 'now')
  }
  const workers: FakeWorker[] = []
  const local = new LocalModels(dir, () => {}, () => {}, 'test', fakeFork(workers))
  return { local, dir, whisper: () => workers.filter(worker => worker.script === 'local-worker.js').at(-1) }
}

test("Whisper, a sherpa model and Whisper again while a dictation runs: Whisper's helper stays, its model is loaded again", async () => {
  const { local, whisper, dir } = setup()
  try {
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    const worker = whisper()!
    worker.engine.running = gate()
    const dictation = local.transcribe(speech, A, [], 'de')
    await until(() => worker.engine.runs.length === 1)
    local.warmUp(B)
    await until(() => worker.messages.includes('unload'))
    local.warmUp(A)
    worker.engine.running.open()
    assert.equal(await dictation, A)
    for (let i = 0; i < 30; i++) await tick()
    assert.equal(worker.killed, false, "the helper of the model chosen again was ended")
    assert.deepEqual([...worker.engine.live].map(model => model.id), [A])
    // And the next dictation goes to it.
    assert.equal(await local.transcribe(speech, A, [], 'de'), A)
    assert.equal(whisper(), worker)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('Whisper Base in use while Large v3 downloads, a sherpa model and back: the next Base dictation does not wait for the download', async () => {
  const { local, whisper, dir } = setup()
  try {
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    const worker = whisper()!
    worker.engine.fetching = gate()
    local.download('onnx-community/whisper-large-v3-ONNX')
    await until(() => local.state('onnx-community/whisper-large-v3-ONNX').kind === 'downloading')
    local.warmUp(B)
    await until(() => worker.messages.includes('unload'))
    for (let i = 0; i < 5; i++) await tick()
    local.warmUp(A)
    const first = await Promise.race([local.transcribe(speech, A, [], 'de'), new Promise(resolve => setTimeout(() => resolve('still waiting for the download'), 300))])
    assert.equal(first, A)
    assert.equal(local.state('onnx-community/whisper-large-v3-ONNX').kind, 'downloading')
    // The download was never stopped by any of it.
    assert.equal(worker.killed, false)
    // What the download writes, then it finishes.
    for (const file of ['onnx/encoder_model_quantized.onnx', 'onnx/decoder_model_merged_q4.onnx', 'tokenizer.json']) {
      fs.mkdirSync(path.dirname(path.join(dir, 'onnx-community/whisper-large-v3-ONNX', file)), { recursive: true })
      fs.writeFileSync(path.join(dir, 'onnx-community/whisper-large-v3-ONNX', file), 'x')
    }
    worker.engine.fetching.open()
    await until(() => local.state('onnx-community/whisper-large-v3-ONNX').kind === 'ready')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('choosing another provider lets go of the helper altogether, and Local chosen again starts it anew', async () => {
  const { local, whisper, dir } = setup()
  try {
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    const first = whisper()!
    await local.unload()
    await until(() => first.killed)
    local.warmUp(A)
    await until(() => whisper() !== first && whisper()?.engine?.live.size === 1)
    assert.equal(await local.transcribe(speech, A, [], 'de'), A)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

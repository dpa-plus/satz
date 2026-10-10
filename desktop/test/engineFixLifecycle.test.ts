import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { LocalModels } from '../src/main/local'
import { markerPath, removeStaleTemps } from '../src/main/localFiles'
import { A, B, fakeFork, gate, place, setup, speech, tick, until, type FakeWorker } from './lifecycleHarness'

/**
 * The lifecycle of the helper processes, which nothing tested: a helper ends
 * when the work that kept it alive is over (LE-02), and the behaviours of
 * LocalModels that deleting left every other test passing (remove, the
 * dictation in the other engine, one download at a time, a crashed helper, a
 * stopped helper's late exit). Each of these tests fails on the code without
 * its line, which is how they were written.
 */
const C = 'onnx-community/whisper-small'
const D = 'sherpa/sense-voice'

/** A download finished by hand: the files it would have written, then the helper may go on. */
function arrive(dir: string, id: string, worker: FakeWorker) {
  place(dir, id)
  worker.engine.fetching!.open()
}

/** What main.ts wires: a download that arrived is measured. */
function measureOnArrival(local: LocalModels, measured: string[]) {
  local.onArrived = id => { void local.measure(id, speech, [], 'de').then(result => measured.push(`${id} ${result}`)) }
}

// MARK: - A helper nobody wants any more ends (LE-02)

test('a download started on Local and finished on another provider: the helper ends after the download and its speed test', async () => {
  const { local, whisper, dir } = setup({}, [])
  try {
    const measured: string[] = []
    measureOnArrival(local, measured)
    local.download(C)
    const worker = whisper()!
    worker.engine.fetching = gate()
    // The provider is switched while it downloads: the helper is busy and stays.
    await local.unload()
    await tick()
    assert.equal(worker.killed, false)
    arrive(dir, C, worker)
    await until(() => measured.length === 1)
    assert.deepEqual(measured, [`${C} done`])
    // Before: nothing looked at the helper again, and it stayed for good.
    await until(() => worker.killed)
    assert.equal(local.state(C).kind, 'ready')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a download on the other engine than the one in use: that engine\'s helper ends after its speed test, the model in use stays loaded', async () => {
  const { local, whisper, sherpa, dir } = setup({}, [A])
  try {
    const measured: string[] = []
    measureOnArrival(local, measured)
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    local.download(D)
    const worker = sherpa()!
    worker.engine.fetching = gate()
    arrive(dir, D, worker)
    await until(() => measured.length === 1)
    await until(() => worker.killed)
    assert.equal(whisper()!.killed, false)
    assert.deepEqual([...whisper()!.engine.live].map(model => model.id), [A])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a cancelled download ends a helper nobody wants, and a failed one too', async () => {
  const { local, whisper, sherpa, dir } = setup({}, [])
  try {
    local.download(C)
    const cancelled = whisper()!
    cancelled.engine.fetching = gate()
    await until(() => local.state(C).kind === 'downloading' && cancelled.messages.includes('download'))
    local.cancel(C)
    await until(() => cancelled.messages.includes('cancel'))
    // The helper has heard it (messages arrive a moment after they are posted).
    await tick()
    await tick()
    cancelled.engine.fetching.open()
    await until(() => cancelled.killed)
    assert.equal(local.state(C).kind, 'missing')

    local.download(D)
    const failing = sherpa()!
    // Fails the way a download does: the engine cannot get its files.
    Object.assign(failing.engine, { fetchAndLoad: async () => { throw new Error('status 404') } })
    await until(() => local.state(D).kind === 'failed')
    await until(() => failing.killed)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('Local chosen again meanwhile: the helper of that engine is kept when the download and its speed test are over', async () => {
  const { local, whisper, dir } = setup({}, [A])
  try {
    const measured: string[] = []
    measureOnArrival(local, measured)
    local.download(C)
    const worker = whisper()!
    worker.engine.fetching = gate()
    await local.unload()
    local.warmUp(A)
    await until(() => worker.engine.live.size >= 1)
    arrive(dir, C, worker)
    await until(() => measured.length === 1)
    for (let i = 0; i < 30; i++) await tick()
    assert.equal(worker.killed, false, 'the helper of the model chosen again was ended')
    assert.equal(await local.transcribe(speech, A, [], 'de'), A)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a speed test that gave way to a dictation keeps the helper: it is asked again, and the helper ends after that', async () => {
  const { local, whisper, dir } = setup({}, [C])
  try {
    const measuring = local.measure(C, speech, [], 'de')
    const worker = whisper()!
    worker.engine.running = gate()
    await until(() => worker.engine.runs.length === 1)
    worker.engine.dictationElsewhere()
    worker.engine.running.open()
    assert.equal(await measuring, 'deferred')
    for (let i = 0; i < 20; i++) await tick()
    assert.equal(worker.killed, false)
    worker.engine.running = null
    assert.equal(await local.measure(C, speech, [], 'de'), 'done')
    await until(() => worker.killed)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

// MARK: - What deleting a line left unnoticed

test('removing a model lets its engine go of it first, then moves the folder to the Trash, takes the marker away and says "missing"', async () => {
  const { local, whisper, dir } = setup()
  try {
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    const worker = whisper()!
    const trashed: string[] = []
    let held = -1
    await local.remove(A, async folder => {
      // The files are about to go: the model must not be in memory any more.
      held = worker.engine.live.size
      trashed.push(folder)
      fs.rmSync(folder, { recursive: true, force: true })
    })
    assert.equal(held, 0, 'the engine still held the model while its folder went')
    assert.deepEqual(trashed, [path.join(dir, A)])
    assert.equal(fs.existsSync(markerPath(dir, A)), false)
    assert.equal(local.state(A).kind, 'missing')
    assert.ok(worker.messages.includes('release'))
    // The other model is not touched, and a name that leads out of the folder is not a model.
    assert.equal(local.state(B).kind, 'ready')
    await local.remove('../outside', async folder => { trashed.push(folder) })
    assert.equal(trashed.length, 1)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a dictation in one engine tells the other engine\'s helper to stop its speed test before its next run', async () => {
  const { local, whisper, sherpa, dir } = setup({}, [B, C])
  try {
    local.warmUp(B)
    await until(() => sherpa()?.engine?.live.size === 1)
    const measuring = local.measure(C, speech, [], 'de')
    whisper()!.engine.running = gate()
    await until(() => whisper()!.engine.runs.length === 1)
    assert.equal(await local.transcribe(speech, B, [], 'de'), B)
    assert.ok(whisper()!.messages.includes('dictationElsewhere'))
    assert.ok(!sherpa()!.messages.includes('dictationElsewhere'), 'a dictation does not stop its own engine\'s tests twice')
    whisper()!.engine.running!.open()
    // The test gave way instead of sharing the processor with the dictation.
    assert.equal(await measuring, 'deferred')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('one download at a time, whichever engine: the second is ignored', async () => {
  const { local, workers, whisper, dir } = setup({}, [])
  try {
    local.download(C)
    whisper()!.engine.fetching = gate()
    local.download(D)
    await tick()
    assert.equal(local.state(D).kind, 'missing')
    assert.deepEqual(workers.map(worker => worker.script), ['local-worker.js'], 'a second helper was started for it')
    whisper()!.engine.fetching!.open()
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a helper that crashes fails the downloads it had under way, and the next download starts a new one', async () => {
  const { local, whisper, workers, dir } = setup({}, [])
  try {
    local.download(C)
    const worker = whisper()!
    worker.engine.fetching = gate()
    await until(() => worker.messages.includes('download') && local.state(C).kind === 'downloading')
    assert.equal(local.downloading, true)
    worker.emit('exit', 1)
    assert.deepEqual(local.state(C), { kind: 'failed', message: 'stopped' })
    assert.equal(local.downloading, false)
    local.download(C)
    await tick()
    assert.equal(workers.filter(entry => entry.script === 'local-worker.js').length, 2)
    whisper()!.engine.fetching = gate()
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a helper ended on purpose does not take the one started after it along when its exit arrives late', async () => {
  const { local, whisper, workers, dir } = setup()
  try {
    local.warmUp(A)
    await until(() => whisper()?.engine?.live.size === 1)
    const first = whisper()!
    await local.unload()
    assert.equal(first.killed, true)
    // Local chosen again before the first helper's exit has been heard.
    local.warmUp(A)
    const second = whisper()!
    assert.notEqual(second, first)
    for (let i = 0; i < 10; i++) await tick()
    assert.equal(await local.transcribe(speech, A, [], 'de'), A)
    assert.equal(workers.filter(worker => worker.script === 'local-worker.js').length, 2, 'a third helper was started')
    assert.equal(whisper(), second)
    assert.equal(second.killed, false)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

// MARK: - A test copy without a models folder of its own

test('canChangeFiles false: no download starts and nothing is removed; the models can still be used', async () => {
  const { local, workers, logs, dir } = setup({ canChangeFiles: false }, [A])
  try {
    local.download(C)
    await tick()
    assert.equal(workers.length, 0, 'a helper was started for the download')
    assert.equal(local.state(C).kind, 'missing')
    assert.ok(logs.some(line => line.includes('not downloading') && line.includes(C)), logs.join('\n'))
    const trashed: string[] = []
    await local.remove(A, async folder => { trashed.push(folder) })
    assert.deepEqual(trashed, [])
    assert.equal(fs.existsSync(markerPath(dir, A)), true)
    assert.equal(local.state(A).kind, 'ready')
    assert.equal(await local.transcribe(speech, A, [], 'de'), A)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('canChangeFiles defaults to true: downloads and removals work', async () => {
  const { local, whisper, dir } = setup({}, [A])
  try {
    local.download(C)
    await until(() => whisper() !== undefined)
    let trashed = 0
    await local.remove(A, async () => { trashed++ })
    assert.equal(trashed, 1)
    assert.equal(local.state(A).kind, 'missing')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

// MARK: - Files a quit left behind

/** The id of a process that has ended. */
const deadPid = () => spawnSync(process.execPath, ['-e', '']).pid

test('half-written files of downloads that stopped with satz are removed at the start; those of a writer still running, and everything else, stay', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-temps-'))
  try {
    const folder = path.join(dir, 'onnx-community', 'whisper-base', 'onnx')
    fs.mkdirSync(folder, { recursive: true })
    const stale = path.join(folder, `encoder_model_quantized.onnx.tmp.${deadPid()}.lflnfy`)
    const alive = path.join(folder, `decoder_model_merged_q4.onnx.tmp.${process.pid}.11svmr2`)
    const complete = path.join(folder, 'encoder_model_quantized.onnx')
    const sherpaPart = path.join(dir, 'sherpa', 'sense-voice', 'model.int8.onnx.part')
    const other = path.join(dir, 'notes.tmp')
    fs.mkdirSync(path.dirname(sherpaPart), { recursive: true })
    for (const file of [stale, alive, complete, sherpaPart, other]) fs.writeFileSync(file, 'x')
    assert.deepEqual(removeStaleTemps(dir), [stale])
    assert.deepEqual([stale, alive, complete, sherpaPart, other].map(file => fs.existsSync(file)), [false, true, true, true, true])
    // A folder that is not there is nothing to clean.
    assert.deepEqual(removeStaleTemps(path.join(dir, 'nowhere')), [])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('LocalModels sweeps the models folder when satz starts, unless it may not change it', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-temps-'))
  try {
    const folder = path.join(dir, 'onnx-community', 'whisper-base', 'onnx')
    fs.mkdirSync(folder, { recursive: true })
    const stale = path.join(folder, `encoder_model_quantized.onnx.tmp.${deadPid()}.lflnfy`)
    fs.writeFileSync(stale, 'x'.repeat(1000))
    const logs: string[] = []
    new LocalModels(dir, message => logs.push(message), () => {}, 'test', { fork: fakeFork([]), canChangeFiles: false })
    assert.equal(fs.existsSync(stale), true, 'a test copy removed a file from the real satz\'s folder')
    new LocalModels(dir, message => logs.push(message), () => {}, 'test', { fork: fakeFork([]) })
    assert.equal(fs.existsSync(stale), false)
    assert.deepEqual(logs, ['local: removed 1 half-written file of a download that was cut off'])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

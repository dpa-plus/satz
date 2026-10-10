import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { A, B, gate, setup, speech, tick, until } from './lifecycleHarness'

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

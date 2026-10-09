import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import type { LocalState } from '../src/main/localFiles'
import { WhisperEngine } from '../src/main/whisperEngine'

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 500 && !done(); i++) await tick(4)
  assert.ok(done(), 'timed out')
}

/**
 * Cancel on a real transformers.js download, against a stand-in for Hugging
 * Face: the config arrives, every model file hangs until its request is
 * aborted. A request without a signal is answered, so work that escaped
 * Cancel shows: it used to go on fetching, and its progress took the card
 * from "missing" back to "downloading" for good. In its own process (node's
 * test runner gives each file one), so the stand-in is the fetch
 * transformers.js finds when it loads.
 */
test('Cancel on a Whisper download stops all of it: no request escapes, no progress after "missing"', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-whisper-cancel-'))
  const id = 'onnx-community/whisper-base'
  const states: LocalState[] = []
  const requests: { file: string; signal: AbortSignal | null; afterCancel: boolean }[] = []
  let cancelled = false
  let engine: WhisperEngine
  globalThis.fetch = (async (url: string | URL, init: RequestInit = {}) => {
    const file = String(url).split('/').at(-1)!
    requests.push({ file, signal: init.signal ?? null, afterCancel: cancelled })
    if (!init.signal) {
      if (file.endsWith('.onnx')) return new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(2_000_000)) } }), { headers: { 'content-length': '10000000' } })
      return new Response('{}', { headers: { 'content-length': '2' } })
    }
    if (file === 'config.json') return Response.json({ model_type: 'whisper', architectures: ['WhisperForConditionalGeneration'], d_model: 512, encoder_layers: 6, decoder_layers: 6, encoder_attention_heads: 8, decoder_attention_heads: 8 })
    init.signal.throwIfAborted()
    return new Promise((_resolve, reject) => {
      init.signal!.addEventListener('abort', () => reject(init.signal!.reason), { once: true })
      // Cancel the moment a model file is on its way.
      if (file.endsWith('.onnx') && !cancelled) setImmediate(() => { if (!cancelled) { cancelled = true; engine.cancel(id) } })
    })
  }) as typeof fetch
  engine = new WhisperEngine(dir, () => {}, (_id, state) => states.push(state))
  try {
    engine.download(id)
    await until(() => states.at(-1)?.kind === 'missing' || states.at(-1)?.kind === 'failed')
    await tick(400)
    assert.ok(cancelled)
    const end = states.findIndex(state => state.kind === 'missing')
    assert.ok(end > 0, JSON.stringify(states))
    assert.deepEqual(states.slice(end).map(state => state.kind), ['missing'])
    assert.deepEqual(requests.filter(request => request.afterCancel && !request.signal?.aborted).map(request => request.file), [])
    assert.equal(fs.existsSync(path.join(dir, id)), false)
    // A second Cancel finds nothing under way, and a new download starts.
    engine.cancel(id)
    engine.download(id)
    await until(() => states.at(-1)?.kind === 'downloading')
    engine.cancel(id)
    await until(() => states.at(-1)?.kind === 'missing')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { localModel, whisperFiles, type WhisperFile } from '../src/core/localModels'
import type { LocalState } from '../src/main/localFiles'
import { checked, pinnedRequest, WhisperEngine } from '../src/main/whisperEngine'

/**
 * Whisper's downloads come from the commit the catalog names, and each of the
 * three big files is checked while it arrives. In a file of its own: the
 * downloads here run on the real transformers.js against a stand-in for
 * Hugging Face, which finds `globalThis.fetch` when it loads (node's test
 * runner gives each file its own process).
 */
const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 500 && !done(); i++) await tick(4)
  assert.ok(done(), 'timed out')
}
const sha256 = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')
/** tokenizer.json's id in a repo: git's, the SHA-1 of the content behind a header. */
const gitOid = (bytes: Uint8Array) => createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex')
const bytes = (length: number, fill: number) => new Uint8Array(length).fill(fill)

/** A body in pieces of a thousand bytes, as a download arrives. */
const body = (content: Uint8Array) => new ReadableStream<Uint8Array>({
  start(controller) {
    for (let at = 0; at < content.length; at += 1000) controller.enqueue(content.subarray(at, at + 1000))
    controller.close()
  },
})
const read = async (response: Response) => new Uint8Array(await response.arrayBuffer())

const encoder: WhisperFile = { name: whisperFiles[0], bytes: 5500, sha256: sha256(bytes(5500, 7)) }
const tokenizerBytes = new TextEncoder().encode('{"model":{}}'.repeat(300))
const tokenizer: WhisperFile = { name: whisperFiles[2], bytes: tokenizerBytes.length, gitOid: gitOid(tokenizerBytes) }

// MARK: - The address

test('a file is asked for at the commit the catalog names, never at main; which of the three files it is is known', () => {
  const source = { revision: 'a'.repeat(40), files: [encoder, tokenizer] }
  const id = 'onnx-community/whisper-tiny'
  assert.deepEqual(pinnedRequest(id, source, `https://huggingface.co/${id}/resolve/main/onnx/encoder_model_quantized.onnx`),
    { url: `https://huggingface.co/${id}/resolve/${'a'.repeat(40)}/onnx/encoder_model_quantized.onnx`, file: encoder })
  const config = pinnedRequest(id, source, `https://huggingface.co/${id}/resolve/main/config.json`)
  assert.equal(config.url, `https://huggingface.co/${id}/resolve/${'a'.repeat(40)}/config.json`)
  assert.equal(config.file, undefined)
  // A mirror keeps its host; a query keeps its place.
  assert.equal(pinnedRequest(id, source, `http://127.0.0.1:9/${id}/resolve/main/tokenizer.json?download=true`).url, `http://127.0.0.1:9/${id}/resolve/${'a'.repeat(40)}/tokenizer.json?download=true`)
  // Anything else would be fetched unpinned: refused.
  assert.throws(() => pinnedRequest(id, source, `https://huggingface.co/${id}/resolve/refs%2Fpr%2F1/config.json`), /cannot pin/)
  assert.throws(() => pinnedRequest(id, source, 'https://huggingface.co/other/model/resolve/main/config.json'), /cannot pin/)
})

// MARK: - The bytes

test('a body that is the file passes, whatever way it is cut into pieces', async () => {
  const response = checked(new Response(body(bytes(5500, 7)), { headers: { 'content-length': '5500' } }), encoder)
  assert.equal(response.headers.get('content-length'), '5500')
  assert.deepEqual(await read(response), bytes(5500, 7))
  assert.deepEqual(await read(checked(new Response(body(tokenizerBytes)), tokenizer)), tokenizerBytes)
})

test('a body of the wrong bytes, too short or too long fails when it is read, so the file never gets its name', async () => {
  const wrong = bytes(5500, 8)
  await assert.rejects(read(checked(new Response(body(wrong)), encoder)), /encoder_model_quantized\.onnx arrived damaged/)
  await assert.rejects(read(checked(new Response(body(bytes(4000, 7))), encoder)), /arrived damaged/)
  await assert.rejects(read(checked(new Response(body(bytes(5600, 7))), encoder)), /arrived damaged/)
  const changed = tokenizerBytes.slice()
  changed[10] ^= 1
  await assert.rejects(read(checked(new Response(body(changed)), tokenizer)), /tokenizer\.json arrived damaged/)
})

test('a body longer than the file stops at once, not at its end', async () => {
  let read = 0
  const endless = new ReadableStream<Uint8Array>({ pull(controller) { read++; controller.enqueue(bytes(1000, 7)) } })
  await assert.rejects(checked(new Response(endless), encoder).arrayBuffer(), /arrived damaged/)
  assert.ok(read < 20, `${read} pieces read`)
})

// MARK: - A download

/** Whisper's stand-in for Hugging Face: the model's small files, and the big ones as given. */
function huggingFace(files: Record<string, Uint8Array>, requested: string[]) {
  globalThis.fetch = (async (url: string | URL, init: RequestInit = {}) => {
    requested.push(String(url))
    const file = decodeURIComponent(new URL(String(url)).pathname).split('/resolve/').pop()!.replace(/^[^/]+\//, '')
    init.signal?.throwIfAborted()
    if (files[file]) return new Response(body(files[file]), { headers: { 'content-length': String(files[file].length) } })
    if (file === 'config.json') return Response.json({ model_type: 'whisper', architectures: ['WhisperForConditionalGeneration'], d_model: 512, encoder_layers: 6, decoder_layers: 6, encoder_attention_heads: 8, decoder_attention_heads: 8 })
    return new Response('{}', { headers: { 'content-length': '2' } })
  }) as typeof fetch
}

/** Downloads `id` with the catalog's three files swapped for these, to the end (ready, or failed). */
async function download(id: string, served: Record<string, Uint8Array>, expected: WhisperFile[], before: (folder: string) => void = () => {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-whisper-pin-'))
  before(path.join(dir, id))
  const model = localModel(id)!
  const saved = model.whisper!.files
  model.whisper!.files = expected
  const states: LocalState[] = []
  const requested: string[] = []
  huggingFace(served, requested)
  const engine = new WhisperEngine(dir, () => {}, (_id, state) => states.push(state))
  try {
    engine.download(id)
    await until(() => states.at(-1)?.kind === 'failed' || states.at(-1)?.kind === 'ready')
    const list = () => (fs.existsSync(path.join(dir, id)) ? fs.readdirSync(path.join(dir, id), { recursive: true }).map(String) : [])
    // A failure is reported as soon as one file fails; a sibling still being
    // fetched finishes (or is removed) a moment later. Read what stays.
    for (let i = 0; i < 150 && list().some(file => file.includes('.tmp.')); i++) await new Promise(resolve => setTimeout(resolve, 20))
    const left = list()
    return { state: states.at(-1)!, requested, left, revision: model.whisper!.revision, dir }
  } finally {
    model.whisper!.files = saved
    await engine.unload()
  }
}

test('a Whisper download asks for every file at the commit, none at main, and files that match are kept under their names', async () => {
  const id = 'onnx-community/whisper-tiny'
  const decoder: WhisperFile = { name: whisperFiles[1], bytes: 6000, sha256: sha256(bytes(6000, 9)) }
  const served = { [encoder.name]: bytes(5500, 7), [decoder.name]: bytes(6000, 9), [tokenizer.name]: tokenizerBytes }
  // The half file an earlier try left when its process ended: written before the download, gone after it.
  const leftover = (folder: string, pid: number | undefined) => {
    fs.mkdirSync(path.join(folder, 'onnx'), { recursive: true })
    fs.writeFileSync(path.join(folder, 'onnx', `encoder_model_quantized.onnx.tmp.${pid}.lflnfy`), 'x'.repeat(4000))
  }
  const { requested, left, revision, dir, state } = await download(id, served, [encoder, decoder, tokenizer], folder => leftover(folder, spawnSync(process.execPath, ['-e', '']).pid))
  try {
    assert.deepEqual(left.filter(file => /\.tmp\.\d+\.lflnfy$/.test(file)), [], 'the half file of an earlier try stayed')
    assert.ok(requested.length >= 5, requested.join('\n'))
    for (const url of requested) assert.ok(url.includes(`/${id}/resolve/${revision}/`) && !url.includes('/resolve/main/'), url)
    // The stand-in's bytes are no ONNX model: the load that follows fails, but the files passed their checks and are there.
    assert.ok(!/arrived damaged/.test(JSON.stringify(state)), JSON.stringify(state))
    for (const file of whisperFiles) assert.ok(left.includes(file), `${file} missing from ${left.join(', ')}`)
    assert.deepEqual(left.filter(file => file.includes('.tmp.')), [])
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a Whisper file that arrives damaged fails the download and leaves nothing under its name or half written', async () => {
  const id = 'onnx-community/whisper-base'
  const decoder: WhisperFile = { name: whisperFiles[1], bytes: 6000, sha256: sha256(bytes(6000, 9)) }
  // The encoder is the right length with other bytes: what a size check alone lets through.
  const served = { [encoder.name]: bytes(5500, 8), [decoder.name]: bytes(6000, 9), [tokenizer.name]: tokenizerBytes }
  const { state, left, dir } = await download(id, served, [encoder, decoder, tokenizer])
  try {
    // The stand-in's other files are no real model, so the download fails at
    // its load either way; what tells the cases apart is the file: the same
    // stand-in with the right bytes (the test above) leaves the encoder in place.
    assert.equal(state.kind, 'failed')
    assert.ok(!left.includes(encoder.name), `${encoder.name} is there: ${left.join(', ')}`)
    assert.deepEqual(left.filter(file => file.includes('.tmp.')), [])
    assert.ok(left.includes(whisperFiles[1]), 'the files that were right are kept for the next try')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

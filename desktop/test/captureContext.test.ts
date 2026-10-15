import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { test } from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
import { Microphone, lostError, type MicrophoneParts } from '../src/renderer/microphone'

/** Run the real card capture adapter with Web Audio stand-ins; never opens a device. */
function cardCapture(options: { initial?: string; resumeFails?: boolean; holdResume?: boolean } = {}) {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'renderer', 'card.ts'), 'utf8')
  const from = source.indexOf('recordFor(satz, {')
  assert.ok(from > 0, 'card capture adapter exists')
  let parts!: MicrophoneParts, context!: Context, losses = 0
  const tracks: { readyState: string; stop(): void }[] = []
  class Context {
    state = options.initial ?? 'running'
    resumed = 0
    finishResume: (() => void) | null = null
    audioWorklet = { async addModule() {} }
    onstatechange: (() => void) | null = null
    constructor() { context = this }
    createMediaStreamSource() { return { connect() {} } }
    addEventListener() {}
    async resume() {
      this.resumed++
      if (options.holdResume) await new Promise<void>(resolve => { this.finishResume = resolve })
      if (options.resumeFails) throw new Error('cannot resume')
      this.state = 'running'
      this.onstatechange?.()
    }
    async close() { this.state = 'closed'; this.onstatechange?.() }
    change(state: string) { this.state = state; this.onstatechange?.() }
  }
  class Worklet { port = { onmessage: null }; onprocessorerror = null }
  const navigator = { mediaDevices: { async getUserMedia() {
    const track = { readyState: 'live', stop() { this.readyState = 'ended' } }
    tracks.push(track)
    return { getTracks: () => [track] }
  } } }
  const code = ts.transpileModule(source.slice(from), { compilerOptions: { target: ts.ScriptTarget.ES2023 } }).outputText
  vm.runInNewContext(code, {
    recordFor(_bridge: unknown, adapter: MicrophoneParts) { parts = adapter },
    satz: { send() {} }, worklet: '', AudioContext: Context, AudioWorkletNode: Worklet,
    navigator, Blob, URL, lostError, words: (_de: string, en: string) => en,
  })
  const microphone = new Microphone(parts, () => {}, () => losses++)
  return { microphone, context: () => context, losses: () => losses, live: () => tracks.filter(t => t.readyState === 'live').length }
}

for (const state of ['closed', 'suspended', 'interrupted']) {
  test(`a running card capture becoming ${state} reports loss and releases its track`, async () => {
    const r = cardCapture()
    try {
      assert.equal(await r.microphone.start(), true)
      r.context().change(state)
      assert.equal(r.losses(), 1)
      assert.equal(r.live(), 0)
      assert.equal(r.context().state, 'closed')
      assert.equal(await r.microphone.start(), true, 'resume opens a fresh working context')
      assert.equal(r.context().state, 'running')
      assert.equal(r.live(), 1)
      assert.equal(r.losses(), 1)
    } finally { r.microphone.stop() }
  })
}

test('an initially suspended card context is resumed before successful capture', async () => {
  const r = cardCapture({ initial: 'suspended' })
  try {
    assert.equal(await r.microphone.start(), true)
    assert.equal(r.context().resumed, 1)
    assert.equal(r.context().state, 'running')
    assert.equal(r.losses(), 0)
  } finally { r.microphone.stop() }
})

for (const state of ['closed', 'interrupted']) {
  test(`a card context already ${state} fails opening and releases capture`, async () => {
    const r = cardCapture({ initial: state })
    try {
      await assert.rejects(r.microphone.start(), { name: 'MicrophoneLost' })
      assert.equal(r.live(), 0)
      assert.equal(r.context().state, 'closed')
      assert.equal(r.losses(), 0)
    } finally { r.microphone.stop() }
  })
}

test('a startup context that cannot resume fails opening and releases capture', async () => {
  const r = cardCapture({ initial: 'suspended', resumeFails: true })
  try {
    await assert.rejects(r.microphone.start())
    assert.equal(r.live(), 0)
    assert.equal(r.context().state, 'closed')
    assert.equal(r.losses(), 0)
  } finally { r.microphone.stop() }
})

test('intentional card capture stop reports no context loss', async () => {
  const r = cardCapture()
  assert.equal(await r.microphone.start(), true)
  r.microphone.stop()
  assert.equal(r.live(), 0)
  assert.equal(r.context().state, 'closed')
  assert.equal(r.losses(), 0)
})

test('stop while startup resume is pending releases context and track without waiting for resume', { timeout: 1000 }, async () => {
  const r = cardCapture({ initial: 'suspended', holdResume: true })
  const start = r.microphone.start()
  try {
    for (let index = 0; index < 8; index++) await Promise.resolve()
    assert.equal(r.context().resumed, 1)
    r.microphone.stop()
    assert.equal(await start, false)
    assert.equal(r.live(), 0)
    assert.equal(r.context().state, 'closed')
    assert.equal(r.losses(), 0)
  } finally {
    r.context().finishResume?.()
    r.microphone.stop()
  }
})

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Microphone, type MicrophoneParts } from '../src/renderer/microphone'

function openingFailure(when: 'opening' | 'connect' | 'never') {
  let live = true, closed = false, losses = 0
  const chunks: number[] = []
  const parts: MicrophoneParts = {
    async getUserMedia() {
      return { getTracks: () => [{ readyState: live ? 'live' : 'ended', stop() { live = false } }] } as unknown as MediaStream
    },
    async openTap(onChunk, onFailed) {
      if (when === 'opening') onFailed()
      return {
        connect() { if (when === 'connect') onFailed(); else if (when === 'never') onChunk(new Float32Array(16)) },
        close() { closed = true },
      }
    },
  }
  const microphone = new Microphone(parts, chunk => chunks.push(chunk.length), () => losses++)
  return { microphone, chunks, live: () => live, closed: () => closed, losses: () => losses }
}

for (const when of ['opening', 'connect'] as const) {
  test(`an audio context that fails during ${when} fails the start and releases capture`, async () => {
    const rig = openingFailure(when)
    try {
      await assert.rejects(rig.microphone.start(), { name: 'MicrophoneLost' })
      assert.equal(rig.live(), false)
      assert.equal(rig.closed(), true)
      assert.equal(rig.losses(), 0, 'an unopened capture fails start instead of reporting an old recording lost')
    } finally { rig.microphone.stop() }
  })
}

test('a working capture still starts, sends samples, and releases resources on stop', async () => {
  const rig = openingFailure('never')
  assert.equal(await rig.microphone.start(), true)
  assert.deepEqual(rig.chunks, [16])
  assert.equal(rig.live(), true)
  assert.equal(rig.closed(), false)
  rig.microphone.stop()
  assert.equal(rig.live(), false)
  assert.equal(rig.closed(), true)
  assert.equal(rig.losses(), 0)
})

for (const when of ['permission', 'tap'] as const) {
  test(`stopping while ${when} is opening releases the delayed resources without restarting capture`, async () => {
    let resolve!: () => void
    const gate = new Promise<void>(done => { resolve = done })
    let live = true, closed = false, connected = false
    const microphone = new Microphone({
      async getUserMedia() {
        if (when === 'permission') await gate
        return { getTracks: () => [{ stop() { live = false } }] } as unknown as MediaStream
      },
      async openTap() {
        if (when === 'tap') await gate
        return { connect() { connected = true }, close() { closed = true } }
      },
    }, () => {})
    const start = microphone.start()
    await Promise.resolve()
    microphone.stop()
    resolve()
    assert.equal(await start, false)
    assert.equal(live, false)
    assert.equal(connected, false)
    assert.equal(closed, when === 'tap')
  })
}

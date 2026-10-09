import assert from 'node:assert/strict'
import test from 'node:test'
import { setLanguage } from '../src/core/language'
import { Session, type AudioSource } from '../src/core/session'
import { SpeedTests, type SpeedTestDeps } from '../src/main/speedTests'

setLanguage('en')

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 400 && !done(); i++) await tick(2)
  assert.ok(done(), 'timed out')
}

/** A second of speech. The microphone's tail (what is still on its way when it stops) takes longer than the card's settle below. */
class Mic implements AudioSource {
  onLevel?: (level: number) => void
  sampleCount = 16_000
  async start() {}
  samples(from: number, to: number) { return new Float32Array(Math.max(0, Math.min(to, this.sampleCount) - from)).fill(0.1) }
  async finishSamples() { await tick(50); return this.samples(0, this.sampleCount) }
  cancel() {}
}

/**
 * The real Session, and the helper's queue as the order things are posted
 * to it: the helper runs them one at a time in that order. Pasting takes a
 * moment, as in satz (120 ms there, against 2 s of settle), and the card has
 * to stay closed longer than that before a waiting test starts (20 ms here).
 * The settle is shorter than the microphone's tail, so it cannot hide a test
 * started too early.
 */
function setup(deps: Partial<SpeedTestDeps> = {}) {
  const queue: string[] = []
  const session = new Session({
    makeSource: () => new Mic(),
    transcribe: async () => { queue.push('transcribe'); await tick(5); return 'Hallo' },
    replacements: () => [],
    missing: () => null,
    endpointMissing: () => false,
    triggerMode: () => 'tap',
    deliver: async () => { await tick(5); return { pasted: true } },
  })
  const tests = new SpeedTests({
    phase: () => session.phase.kind,
    measure: async id => { queue.push(`measure ${id}`); return 'done' as const },
    inUse: () => 'A',
    isReady: () => true,
    use: () => {},
    localChosen: () => true,
    warmUp: id => queue.push(`warmUp ${id}`),
    log: () => {},
    ...deps,
  }, 20)
  session.onChange = () => tests.sessionChanged()
  return { session, tests, queue, done: () => { session.dispose(); tests.dispose() } }
}

test('with no dictation under way, a speed test starts at once', t => {
  const { tests, queue, done } = setup()
  t.after(done)
  tests.request('B')
  assert.deepEqual(queue, ['measure B'])
})

test("a download that arrives while the user speaks is measured after that dictation's text, not ahead of it", async t => {
  const { session, tests, queue, done } = setup()
  t.after(done)
  session.press(); await until(() => session.phase.kind === 'listening')
  tests.arrived('B')
  assert.equal(tests.isWaiting('B'), true)
  // Finishing: the tail, then the text. A test started here (the microphone
  // is closed) went into the queue first, and the text waited for it.
  session.press()
  await until(() => session.phase.kind === 'idle')
  assert.deepEqual(queue, ['transcribe'])
  await until(() => queue.length === 2)
  assert.deepEqual(queue, ['transcribe', 'measure B'])
  assert.equal(tests.isWaiting('B'), false)
})

test('paused, the recording so far is sent after its tail: the test waits for it and for the end of the dictation', async t => {
  const { session, tests, queue, done } = setup()
  t.after(done)
  session.press(); await until(() => session.phase.kind === 'listening')
  tests.request('B')
  session.toggleMicrophone()
  assert.equal(session.phase.kind, 'paused')
  await until(() => queue.length === 1)
  await tick(100)
  assert.deepEqual(queue, ['transcribe'])
  session.press()
  await until(() => session.phase.kind === 'idle')
  await until(() => queue.length === 2)
  assert.deepEqual(queue, ['transcribe', 'measure B'])
})

test('the next dictation, asked for while one is being written, goes ahead of the test as well', async t => {
  const { session, tests, queue, done } = setup()
  t.after(done)
  session.press(); await until(() => session.phase.kind === 'listening')
  tests.request('B')
  session.press()
  session.press()
  assert.equal(session.phase.kind, 'finishing')
  // The card closes before the paste, and the next dictation starts after it.
  await until(() => queue.length === 1 && session.phase.kind === 'listening')
  await tick(100)
  assert.deepEqual(queue, ['transcribe'])
  session.press()
  await until(() => queue.length === 3)
  assert.deepEqual(queue, ['transcribe', 'transcribe', 'measure B'])
})

test('asked for twice while waiting, a model is measured once', async t => {
  const { session, tests, queue, done } = setup()
  t.after(done)
  session.press(); await until(() => session.phase.kind === 'listening')
  tests.request('B')
  tests.request('B')
  session.press()
  await until(() => queue.length === 2)
  await tick(100)
  assert.deepEqual(queue, ['transcribe', 'measure B'])
})

test('a download beside a model in use that is on the computer: measured, nothing else', t => {
  const { tests, queue, done } = setup()
  t.after(done)
  tests.arrived('B')
  assert.deepEqual(queue, ['measure B'])
})

test('the model in use arrives: loaded as the one in use before its test, so the test keeps it', t => {
  const { tests, queue, done } = setup({ isReady: () => false })
  t.after(done)
  tests.arrived('A')
  assert.deepEqual(queue, ['warmUp A', 'measure A'])
  // With another provider chosen it stays out of memory: the test lets it go.
  const other = setup({ isReady: () => false, localChosen: () => false })
  t.after(other.done)
  other.tests.arrived('A')
  assert.deepEqual(other.queue, ['measure A'])
})

test('the model in use is not on the computer: the download becomes it and works right away', t => {
  let inUse = 'A'
  const { tests, queue, done } = setup({ inUse: () => inUse, isReady: id => id !== 'A', use: id => { inUse = id } })
  t.after(done)
  tests.arrived('B')
  assert.equal(inUse, 'B')
  assert.deepEqual(queue, ['warmUp B', 'measure B'])
})

test('a download while Local is only looked at: it may become Local\'s model, never the provider, and stays out of memory', t => {
  let inUse = 'A'
  const used: string[] = []
  const { tests, queue, done } = setup({ inUse: () => inUse, isReady: id => id !== 'A', use: id => { used.push(id); inUse = id }, localChosen: () => false })
  t.after(done)
  tests.arrived('B')
  // `use` sets Local's model and nothing else (main.ts); no warm-up, as no dictation goes to it.
  assert.deepEqual(used, ['B'])
  assert.deepEqual(queue, ['measure B'])
})

test('one test at a time: the second waits for the first, and a dictation begun meanwhile goes ahead of it', async t => {
  const finish: (() => void)[] = []
  const { session, tests, queue, done } = setup({
    measure: id => new Promise(resolve => { queue.push(`measure ${id}`); finish.push(() => resolve('done')) }),
  })
  t.after(done)
  tests.request('B')
  tests.request('C')
  assert.deepEqual(queue, ['measure B'])
  assert.equal(tests.isWaiting('C'), true)
  session.press(); await until(() => session.phase.kind === 'listening')
  finish.shift()!()
  await tick(5)
  // B is done, but the user is speaking: C waits for the dictation.
  assert.deepEqual(queue, ['measure B'])
  session.press()
  await until(() => queue.length === 3)
  assert.deepEqual(queue, ['measure B', 'transcribe', 'measure C'])
})

test('a test that gave way to a dictation is asked again once that dictation is over', async t => {
  let first = true
  const { session, tests, queue, done } = setup({
    measure: async id => { queue.push(`measure ${id}`); if (first) { first = false; return 'deferred' } return 'done' },
  })
  t.after(done)
  session.press(); await until(() => session.phase.kind === 'listening')
  tests.request('B')
  session.press()
  // B ran, gave way (as if a dictation had come in), and was put back, not lost.
  await until(() => queue.length === 3)
  assert.deepEqual(queue, ['transcribe', 'measure B', 'measure B'])
})

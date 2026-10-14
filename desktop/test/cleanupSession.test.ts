import { afterEach, mock, test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { reasonText } from '../src/core/cleanup'
import { runCleanup } from '../src/core/cleanupRequest'
import { deferred, disposeAll, flush, phase, setup, settle } from './sessionHarness'

/*
 * Cleanup in the session: after every recording is written, before the
 * paste. The card says "Räumt auf" meanwhile and behaves as while writing;
 * whatever goes wrong, the original is pasted.
 */

afterEach(() => disposeAll())

const said = 'ähm also der build ist äh gefailed weil the tests are flaky'
const cleaned = 'Also, der Build ist gefailed, weil the tests are flaky.'

/** A stand-in for the provider on 127.0.0.1, answering `content` after `delay` ms. */
async function standIn(content: string, delay = 0) {
  let asked = 0
  const server = createServer((request, response) => {
    request.resume()
    request.on('end', () => {
      asked++
      setTimeout(() => {
        response.writeHead(200, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ choices: [{ message: { content } }] }))
      }, delay)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  return {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    get asked() { return asked },
    close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }),
  }
}

/** The session's cleanup through the real request code, as main.ts wires it, to a Custom provider at the stand-in. */
const through = (origin: string, timeout?: number) => async (text: string) => {
  const result = await runCleanup({ provider: 'custom', base: origin, model: 'stand-in', key: null, level: 'light', customPrompt: '', vocabulary: [], text }, fetch as never, { timeout })
  return result.kind === 'cleaned' ? { text: result.text, outcome: 'ok' } : { text, outcome: reasonText(result.reason, result.status) }
}

test('cleanup on: the card says it cleans up, the cleaned text is pasted, and the history gets the original', async () => {
  const gate = deferred<{ text: string; outcome: string }>()
  const asked: string[] = []
  const { session, sources, delivered, cleanups } = setup([said], { cleanup: text => { asked.push(text); return gate.promise } })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(session.phase, { kind: 'finishing', cleaning: true })
  assert.deepEqual(asked, [said], 'exactly what would be pasted')
  assert.deepEqual(delivered, [], 'nothing pasted while it is cleaned up')
  gate.resolve({ text: cleaned, outcome: 'ok' }); await settle()
  assert.deepEqual(delivered, [cleaned])
  assert.deepEqual(cleanups, [{ original: said, outcome: 'ok' }])
  assert.equal(phase(session), 'idle')
})

test('cleanup on, through a stand-in server: the request code\'s answer is what is pasted', async () => {
  const server = await standIn(cleaned)
  try {
    const { session, sources, delivered, cleanups } = setup([said], { cleanup: through(server.origin) })
    session.press(); await settle()
    sources[0].say()
    session.press()
    for (let i = 0; i < 50 && delivered.length === 0; i++) await settle()
    assert.deepEqual(delivered, [cleaned])
    assert.deepEqual(cleanups, [{ original: said, outcome: 'ok' }])
    assert.equal(server.asked, 1)
  } finally { await server.close() }
})

test('a failed cleanup pastes the original, the history has the reason, and the card says so for 3 seconds', async () => {
  mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  try {
    const { session, sources, delivered, cleanups } = setup([said], { cleanup: async text => ({ text, outcome: 'Key rejected' }) })
    session.press(); await flush()
    sources[0].say()
    session.press(); await flush()
    assert.deepEqual(delivered, [said])
    assert.deepEqual(cleanups, [{ original: said, outcome: 'Key rejected' }])
    assert.deepEqual(session.phase, { kind: 'notCleaned', reason: 'Key rejected' })
    mock.timers.tick(2900); await flush()
    assert.equal(phase(session), 'notCleaned')
    mock.timers.tick(200); await flush()
    assert.equal(phase(session), 'idle')
  } finally { mock.timers.reset() }
})

test('a cleanup that is too slow pastes the original with "Too slow"', async () => {
  const server = await standIn(cleaned, 1500)
  try {
    const { session, sources, delivered, cleanups } = setup([said], { cleanup: through(server.origin, 0.2) })
    session.press(); await settle()
    sources[0].say()
    session.press()
    for (let i = 0; i < 100 && delivered.length === 0; i++) await settle()
    assert.deepEqual(delivered, [said])
    assert.deepEqual(cleanups, [{ original: said, outcome: 'Too slow' }])
    assert.equal(phase(session), 'notCleaned')
  } finally { await server.close() }
})

test('an answer the guard rejects (a told joke) pastes the original with "Answer rejected"', async () => {
  const server = await standIn('Why did the build fail? Because nobody wanted to fix the flaky tests! Here is another one for you.')
  try {
    const { session, sources, delivered, cleanups } = setup([said], { cleanup: through(server.origin) })
    session.press(); await settle()
    sources[0].say()
    session.press()
    for (let i = 0; i < 50 && delivered.length === 0; i++) await settle()
    assert.deepEqual(delivered, [said])
    assert.deepEqual(cleanups, [{ original: said, outcome: 'Answer rejected' }])
    assert.equal(phase(session), 'notCleaned')
  } finally { await server.close() }
})

test('a cleanup that throws still pastes the original', async () => {
  const { session, sources, delivered, cleanups } = setup([said], { cleanup: async () => { throw new Error('boom') } })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.deepEqual(delivered, [said])
  assert.deepEqual(cleanups, [{ original: said, outcome: 'Provider error' }])
})

test('discarded while cleaning up: the late answer is dropped, and the text can still come back', async () => {
  const gate = deferred<{ text: string; outcome: string }>()
  const { session, sources, delivered } = setup([said], { cleanup: () => gate.promise })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.equal(phase(session), 'finishing')
  session.discard()
  assert.equal(phase(session), 'discarded')
  gate.resolve({ text: cleaned, outcome: 'ok' }); await settle()
  assert.deepEqual(delivered, [], 'the late answer is not pasted')
  assert.equal(phase(session), 'discarded')
  session.undoDiscard(); await settle()
  assert.equal(phase(session), 'paused')
  assert.equal(session.plainText().trim(), said)
})

test('the shortcut while cleaning up queues the next dictation, as while writing', async () => {
  const gate = deferred<{ text: string; outcome: string }>()
  const { session, sources, delivered } = setup([said, 'zweites diktat'], { cleanup: text => (text === said ? gate.promise : Promise.resolve({ text, outcome: 'ok' })) })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  session.press(); await settle() // pressed during "Räumt auf"
  assert.equal(phase(session), 'finishing')
  assert.equal(sources.length, 1)
  gate.resolve({ text: cleaned, outcome: 'ok' }); await settle()
  assert.deepEqual(delivered, [cleaned])
  assert.equal(sources.length, 2, 'the next one began once the text was out')
  assert.equal(phase(session), 'listening')
})

test('a text that only reached the clipboard says that, not why it was not cleaned up', async () => {
  const history: unknown[] = []
  const { session, sources } = setup([said], {
    cleanup: async text => ({ text, outcome: 'Too slow' }),
    deliver: async (_text, cleanup) => { history.push(cleanup); return { pasted: false, reason: 'no window' } },
  })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.equal(phase(session), 'clipboard')
  assert.deepEqual(history, [{ original: said, outcome: 'Too slow' }], 'the history still knows why')
})

test('cleanup off: no call, and the text goes out as it always did', async () => {
  let calls = 0
  const { session, sources, delivered, cleanups } = setup([said], { cleanup: async text => { calls++; return { text: cleaned, outcome: 'ok' } }, cleansText: () => false })
  session.press(); await settle()
  sources[0].say()
  session.press(); await settle()
  assert.equal(calls, 0)
  assert.deepEqual(delivered, [said])
  assert.deepEqual(cleanups, [undefined], 'nothing about cleanup in the history')
  assert.equal(phase(session), 'idle')
})

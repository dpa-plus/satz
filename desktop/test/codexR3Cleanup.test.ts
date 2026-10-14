import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { cleanupProviders } from '../src/core/cleanupProviders'
import { parseAnswer, runCleanup, type CleanupJob } from '../src/core/cleanupRequest'
import { readHistory } from '../src/core/history'
import { setLanguage } from '../src/core/language'
import { Cleaner, type CleanupSettings } from '../src/main/cleanup'

/*
 * Codex bug hunt, third pass, the cleanup parts on Windows/Linux: a malformed
 * Gemini answer, what a provider's error text may reach in the log, a
 * cleanup that is cancelled, and a history file with a null in it. Nothing
 * here reaches a provider: the stand-ins are on 127.0.0.1 or in memory.
 */

setLanguage('en')
const said = 'ähm also der build ist äh gefailed weil the tests are flaky'
const cleaned = 'Also, der Build ist gefailed, weil the tests are flaky.'

// MARK: - A malformed answer is an unreadable one

test('Gemini: parts that are not a list make the answer unreadable instead of throwing', () => {
  for (const parts of [{ text: cleaned }, cleaned, 5, true]) {
    assert.equal(parseAnswer('google', { candidates: [{ content: { parts } }] }), undefined, JSON.stringify(parts))
  }
  // The other nested shapes: a candidate or its content that is not an object, a part that is not one, a text that is none.
  assert.equal(parseAnswer('google', { candidates: ['x'] }), undefined)
  assert.equal(parseAnswer('google', { candidates: [null] }), undefined)
  assert.equal(parseAnswer('google', { candidates: [{ content: 'x' }] }), undefined)
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [5] } }] }), undefined)
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [null] } }] }), undefined)
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ text: { deep: 1 } }] } }] }), undefined)
  assert.equal(parseAnswer('google', { candidates: 'x' }), undefined)
})

test('Gemini: the shapes a real answer has still read', () => {
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ text: 'Hal' }, { text: 'lo.' }] }, finishReason: 'STOP' }] })!.text, 'Hallo.')
  // No content at all (a blocked answer) and no candidates at all are answers with nothing in them.
  assert.deepEqual([parseAnswer('google', { candidates: [{ finishReason: 'SAFETY' }] })!.text, parseAnswer('google', { candidates: [{ finishReason: 'SAFETY' }] })!.refused], ['', true])
  assert.equal(parseAnswer('google', { candidates: [] })!.text, '')
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ text: 'thinking', thought: true }, { text: 'Hallo.' }] } }] })!.text, 'Hallo.')
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ inlineData: {} }, { text: 'Hallo.' }] } }] })!.text, 'Hallo.', 'a part without text is skipped')
})

test('Anthropic and OpenAI: nested shapes that are not the ones they send are unreadable too', () => {
  assert.equal(parseAnswer('anthropic', { content: 'x' }), undefined)
  assert.equal(parseAnswer('anthropic', { content: [5] }), undefined)
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'text', text: { a: 1 } }] }), undefined)
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'thinking', thinking: 'hm' }, { type: 'text', text: 'Hallo.' }], stop_reason: 'end_turn' })!.text, 'Hallo.')
  assert.equal(parseAnswer('openai', { choices: ['x'] }), undefined)
  assert.equal(parseAnswer('openai', { choices: [{ message: 'x' }] }), undefined)
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: { a: 1 } } }] }), undefined)
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: [5] } }] }), undefined)
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: 'Hallo.' } }] })!.text, 'Hallo.')
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: [{ type: 'text', text: 'Hal' }, 'lo.'] } }] })!.text, 'Hallo.')
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: null, refusal: 'No.' } }] })!.refused, true)
})

/** A Cleaner whose network is `fetcher`, on a scratch folder. */
function cleanerWith(fetcher: typeof fetch, settings: Partial<CleanupSettings> = {}, keys: Record<string, string> = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-cleanup-r3-'))
  const logs: string[] = []
  const instance = new Cleaner({
    dir,
    settings: provider => ({ provider: provider ?? 'custom', model: 'stand-in', address: 'http://127.0.0.1:9/v1', level: 'light', customPrompt: '', vocabulary: [], ...settings }),
    readAccount: account => keys[account] ?? null,
    fetcher,
    log: message => logs.push(message),
    changed: () => {},
  })
  return { instance, dir, logs }
}
const reply = (body: unknown, status = 200) => (async () => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status })) as unknown as typeof fetch

test('a malformed Gemini answer ends the cleanup as a provider error, and the original is kept (it used to reject)', async () => {
  const { instance } = cleanerWith(reply({ candidates: [{ content: { parts: { text: 'Malformed synthetic answer' } } }] }), { provider: 'google', model: 'gemini-synthetic', address: '' }, { google: 'KEY' })
  const run = await instance.run(said)
  assert.equal(run.text, said)
  assert.equal(run.outcome, 'Provider error')
  assert.equal(run.code, 'provider-error')
})

test('runCleanup: a parser that throws on a shape nobody foresaw still fails the cleanup instead of throwing', async () => {
  const job: CleanupJob = { provider: 'google', base: 'http://127.0.0.1:9/v1beta', model: 'm', key: 'K', level: 'light', customPrompt: '', vocabulary: [], text: said }
  // An answer is plain data, so only a getter further up its prototype chain can throw while it is read: the shape that gets past every check.
  Object.defineProperty(Object.prototype, 'candidates', { get() { throw new TypeError('surprise') }, configurable: true })
  try {
    const result = await runCleanup(job, (async () => new Response('{}', { status: 200 })) as never)
    assert.equal(result.kind, 'failed')
    assert.equal(result.kind === 'failed' && result.reason, 'providerError')
  } finally { delete (Object.prototype as { candidates?: unknown }).candidates }
})

// MARK: - What the log may hold

const echo = (key: string) => `Invalid input: ${said}. Account ${key}`

test('a provider\'s error text is never logged: not the dictation, not the key; the status and its type and code are', async () => {
  const key = 'SYNTHETICVALIDKEY123'
  const bodies: unknown[] = [
    { error: { message: echo(key), type: 'invalid_request_error', code: 'invalid_api_key', param: said } },
    { error: { code: 400, message: echo(key), status: 'INVALID_ARGUMENT', details: [{ reason: echo(key) }] } },
    { type: 'error', error: { type: 'invalid_request_error', message: echo(key) } },
    { error: echo(key) },
    { message: echo(key) },
    echo(key),
    `<html>${echo(key)}</html>`,
    { error: { message: echo(key), type: echo(key), code: said, status: `${key}` } },
  ]
  for (const body of bodies) {
    const { instance, logs } = cleanerWith(reply(body, 400), {}, { 'custom-cleanup': key })
    const run = await instance.run(said)
    assert.equal(run.text, said)
    const log = logs.join('\n')
    assert.ok(!log.includes(key), log)
    assert.ok(!log.includes('gefailed') && !log.includes('flaky') && !log.includes('Invalid input'), log)
    assert.match(log, /cleanup: custom answered 400/)
  }
  // The allowlisted fields do come through, so a failure can still be told apart.
  const { instance, logs } = cleanerWith(reply({ error: { message: echo(key), type: 'invalid_request_error', code: 'invalid_api_key' } }, 400), {}, { 'custom-cleanup': key })
  await instance.run(said)
  assert.match(logs.join('\n'), /cleanup: custom answered 400: type=invalid_request_error, code=invalid_api_key/)
  const gemini = cleanerWith(reply({ error: { code: 400, message: echo(key), status: 'INVALID_ARGUMENT' } }, 400), { provider: 'google', model: 'gemini-synthetic', address: '' }, { google: key })
  await gemini.instance.run(said)
  assert.match(gemini.logs.join('\n'), /cleanup: google answered 400: code=400, status=INVALID_ARGUMENT/)
})

test('a field that is long or has spaces is not a code: it is dropped from the log line', async () => {
  const { instance, logs } = cleanerWith(reply({ error: { type: 'x'.repeat(200), code: 'two words', status: 'ok_status' } }, 422))
  await instance.run(said)
  const log = logs.join('\n')
  assert.match(log, /answered 422: status=ok_status(\n|$)/)
  assert.ok(!log.includes('xxxxxxxx') && !log.includes('two words'))
})

test('a request that fails before an answer comes back logs no text from the network layer', async () => {
  const key = 'SECRET-KEY-0123456789'
  const quoting = (async () => {
    const error = new TypeError(`Headers.append: "Bearer ${key}" is an invalid header value.`)
    ;(error as { cause?: unknown }).cause = Object.assign(new Error(`proxy said: ${said}`), { code: 'ECONNREFUSED' })
    throw error
  }) as unknown as typeof fetch
  const { instance, logs } = cleanerWith(quoting, {}, { 'custom-cleanup': key })
  const run = await instance.run(said)
  assert.equal(run.outcome, 'Not reachable')
  assert.equal(run.text, said)
  const log = logs.join('\n')
  assert.ok(!log.includes(key) && !log.includes('flaky') && !log.includes('proxy said'), log)
  assert.match(log, /cleanup: custom answered nothing: TypeError ECONNREFUSED/)
})

test('a 400 that names a field still gets the request without it (the provider\'s words are read, only never logged)', async () => {
  const seen: Record<string, unknown>[] = []
  const fetcher = (async (_url: string, init: { body: string }) => {
    seen.push(JSON.parse(init.body))
    return seen.length === 1
      ? new Response(JSON.stringify({ error: { message: 'Unsupported parameter: temperature is not allowed here', type: 'invalid_request_error' } }), { status: 400 })
      : new Response(JSON.stringify({ choices: [{ message: { content: cleaned } }] }), { status: 200 })
  }) as unknown as typeof fetch
  const { instance, logs } = cleanerWith(fetcher)
  const run = await instance.run(said)
  assert.equal(run.outcome, 'ok')
  assert.equal(seen.length, 2)
  assert.ok('temperature' in seen[0] && !('temperature' in seen[1]))
  assert.ok(!logs.join('\n').includes('Unsupported parameter'))
})

// MARK: - A cancelled cleanup

interface Seen { url?: string }
async function standIn(answerTo: (seen: Seen) => { status: number; body: unknown; delay?: number }) {
  const seen: Seen[] = []
  const server = createServer((request, response) => {
    request.on('data', () => {})
    request.on('end', () => {
      seen.push({ url: request.url })
      const answer = answerTo(seen[seen.length - 1])
      setTimeout(() => { response.writeHead(answer.status, { 'content-type': 'application/json' }); response.end(JSON.stringify(answer.body)) }, answer.delay ?? 0)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  return { origin, seen, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}
const chat = (content: string) => ({ choices: [{ message: { role: 'assistant', content } }] })
const speeds = (dir: string) => fs.existsSync(path.join(dir, 'cleanup-speeds.json'))

test('Cleaner.run with a signal that is aborted already sends nothing (not even a list of models) and returns the original as aborted', async () => {
  const server = await standIn(() => ({ status: 200, body: chat(cleaned) }))
  try {
    for (const settings of [{ provider: 'custom', model: 'stand-in' }, { provider: 'ollama', model: '' }] as const) {
      const { instance, dir, logs } = cleanerWith(fetch, { ...settings, address: `${server.origin}/v1` })
      const stop = new AbortController()
      stop.abort()
      const run = await instance.run(said, { signal: stop.signal })
      assert.equal(run.text, said)
      assert.equal(run.outcome, 'Cancelled')
      assert.equal(run.code, 'aborted')
      assert.equal(run.reason, undefined)
      assert.equal(run.rejected, false)
      assert.equal(run.seconds, undefined)
      assert.equal(server.seen.length, 0, `${settings.provider}: nothing was sent`)
      assert.equal(speeds(dir), false)
      assert.ok(!logs.join('\n').includes('flaky'))
    }
  } finally { await server.close() }
})

test('Cleaner.run aborted while the request is out: back at once with the original, no measurement, not the dictation\'s cleanup', async () => {
  const server = await standIn(() => ({ status: 200, body: chat(cleaned), delay: 400 }))
  try {
    const { instance, dir } = cleanerWith(fetch, { address: `${server.origin}/v1` })
    const stop = new AbortController()
    const running = instance.run(said, { signal: stop.signal })
    setTimeout(() => stop.abort(), 40)
    const started = Date.now()
    const run = await running
    assert.ok(Date.now() - started < 300, 'did not wait for the answer')
    assert.equal(run.text, said)
    assert.equal(run.code, 'aborted')
    assert.equal(speeds(dir), false)
    instance.delivered(true)
    assert.equal(instance.last, null, 'a cancelled run is not the dictation\'s cleanup')
  } finally { await server.close() }
})

test('Cleaner.run: an answer that arrived anyway after the abort is not used, and not measured', async () => {
  const stop = new AbortController()
  // A fetch that ignores the signal, as a stand-in or a proxy may: the answer comes after the abort.
  const late = (async () => { stop.abort(); return new Response(JSON.stringify(chat(cleaned)), { status: 200 }) }) as unknown as typeof fetch
  const { instance, dir } = cleanerWith(late)
  const run = await instance.run(said, { signal: stop.signal })
  assert.equal(run.text, said)
  assert.equal(run.code, 'aborted')
  assert.equal(run.answer, undefined)
  assert.equal(speeds(dir), false)
  instance.delivered(true)
  assert.equal(instance.last, null)
})

test('runCleanup: aborted between a 400 and the request it asks for, the second request is not sent', async () => {
  const stop = new AbortController()
  let sent = 0
  const fetcher = (async () => {
    sent++
    stop.abort()
    return new Response(JSON.stringify({ error: { message: 'Unsupported parameter: temperature' } }), { status: 400 })
  }) as never
  const job: CleanupJob = { provider: 'custom', base: 'http://127.0.0.1:9/v1', model: 'm', key: null, level: 'light', customPrompt: '', vocabulary: [], text: said }
  const result = await runCleanup(job, fetcher, { signal: stop.signal })
  assert.equal(sent, 1)
  assert.equal(result.kind, 'failed')
  assert.equal(result.kind === 'failed' && result.seconds, undefined)
})

test('Cleaner.run aborted: "Ausprobieren" is the same (its signal), and the log has lengths only', async () => {
  const { instance, logs } = cleanerWith(fetch)
  const stop = new AbortController()
  stop.abort()
  const run = await instance.run(said, { signal: stop.signal, trying: true })
  assert.equal(run.code, 'aborted')
  const log = logs.join('\n')
  assert.match(log, /cleanup \(try\): custom .*aborted/)
  assert.ok(!log.includes('flaky'))
})

test('control: a run nobody cancels is cleaned, measured and the state of its dictation', async () => {
  const server = await standIn(() => ({ status: 200, body: chat(cleaned) }))
  try {
    const { instance, dir } = cleanerWith(fetch, { address: `${server.origin}/v1` })
    const stop = new AbortController()
    const run = await instance.run(said, { signal: stop.signal })
    assert.equal(run.outcome, 'ok')
    assert.equal(run.text, cleaned)
    assert.equal(speeds(dir), true)
    instance.delivered(true)
    assert.equal(instance.last?.original, said)
  } finally { await server.close() }
})

test('the provider table still has the stand-in\'s kind (guards the fixtures above)', () => {
  assert.equal(cleanupProviders.custom.family, 'openai')
  assert.equal(cleanupProviders.google.family, 'gemini')
})

// MARK: - A history file with something else in its list

test('history: entries that are not objects with a text are skipped, the rest read as before', () => {
  let n = 0
  const newId = () => `new-${++n}`
  const good = { id: 'keep', text: 'Hallo.', date: '2026-10-14T10:00:00Z', pasted: true, original: 'hallo', cleanup: 'ok' }
  const legacy = { text: 'old', date: '2026-10-01', pasted: true }
  const entries = readHistory([null, 7, 'text', [], undefined, true, {}, { text: 5 }, { text: null }, good, { id: 3, text: 'numeric id' }, legacy], 50, newId)
  assert.deepEqual(entries.map(entry => entry.text), ['Hallo.', 'numeric id', 'old'])
  assert.equal(entries[0].id, 'keep')
  assert.deepEqual(entries[0], good)
  assert.equal(entries[1].id, 'new-1', 'an id that is no string is made new')
  assert.equal(entries[2].id, 'new-2')
})

test('history: the limit counts the entries that are kept, not the ones that were skipped', () => {
  const list = [null, { text: 'a' }, null, { text: 'b' }, { text: 'c' }]
  assert.deepEqual(readHistory(list, 2, () => 'id').map(entry => entry.text), ['a', 'b'])
  assert.deepEqual(readHistory([null], 50, () => 'id'), [])
  assert.deepEqual(readHistory({ unexpected: true }, 50, () => 'id'), [])
})

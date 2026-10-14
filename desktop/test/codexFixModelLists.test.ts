import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createServer, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import type { ManualFetch } from '../src/core/redirect'
import { ModelLists } from '../src/main/modelLists'
import type { Provider } from '../src/core/transcriber'

/*
 * The model lists (the verifiers' remaining problem 3). A key file saved by an
 * older satz can hold a line break: the Authorization header was built from it
 * anyway, fetch refused the header and quoted it whole, and the list's error
 * line put the key into satz.log. Now the key is checked before the header is
 * built, the request keeps to the provider's own origin like every request
 * that carries a key (core/redirect.ts), and no transport error goes into the
 * log as it came.
 */

const later = () => new Promise<void>(resolve => setImmediate(resolve))
async function settle() { for (let i = 0; i < 20; i++) await later() }

function scratch() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lists-'))
  return { dir, remove: () => fs.rmSync(dir, { recursive: true, force: true }) }
}

const list = { data: [{ id: 'whisper-large-v9', name: 'Whisper' }] }

test('a key with a line break is not put into a header, and nothing of it reaches the log', async () => {
  const { dir, remove } = scratch()
  try {
    const key = 'SYNTHETIC-KEY-START\nSYNTHETIC-KEY-END'
    const logs: string[] = []
    let calls = 0
    // What Node's fetch and Electron's do with such a header: refuse it and quote it.
    const quoting: ManualFetch = async (_url, init) => {
      calls++
      throw new TypeError(`Headers.append: "${init.headers?.Authorization}" is an invalid header value.`)
    }
    let clock = Date.now()
    const lists = new ModelLists(dir, () => key, message => logs.push(message), () => {}, quoting, () => clock)
    for (const provider of ['openai', 'groq'] as const) { lists.refresh(provider); await settle() }
    assert.equal(calls, 0, 'no request was attempted')
    assert.ok(logs.length >= 2, 'it says that the list was not fetched, and why')
    for (const line of logs) {
      assert.ok(!line.includes('SYNTHETIC'), line)
      assert.match(line, /list not fetched/)
    }
    // Asked for again by every redraw of Settings, it says so once per ten minutes, not every time.
    const count = logs.length
    for (let draw = 0; draw < 10; draw++) { lists.refresh('openai'); await settle() }
    assert.equal(logs.length, count)
    clock += 11 * 60_000
    lists.refresh('openai'); await settle()
    assert.equal(logs.length, count + 1)
    // The shipped list stays what the menu shows.
    assert.ok(lists.get('openai').length > 0)
  } finally { remove() }
})

test('a transport error that quotes the request is logged without the key', async () => {
  const { dir, remove } = scratch()
  try {
    const key = 'SECRET-KEY-0123456789'
    const shapes = [
      (k: string) => `Headers.append: "Bearer ${k}" is an invalid header value.`,
      (k: string) => `proxy refused: Authorization: Bearer ${k}\nHost: api.groq.com`,
      (k: string) => `bad gateway for ${k}`,
    ]
    for (const shape of shapes) {
      const logs: string[] = []
      const quoting: ManualFetch = async () => { throw new Error(shape(key)) }
      new ModelLists(dir, () => key, message => logs.push(message), () => {}, quoting).refresh('groq')
      await settle()
      assert.equal(logs.length, 1, logs.join('\n'))
      assert.ok(!logs[0].includes(key), logs[0])
      assert.ok(!logs[0].includes('0123456789'), logs[0])
      assert.ok(!/[\u0000-\u001f]/.test(logs[0]), 'no control character in a log line')
      assert.match(logs[0], /groq list not fetched/)
    }
  } finally { remove() }
})

/** The provider's address is a fixed https one: this fetcher sends what it is asked for to a stand-in, which is told the address that was meant, and notes the addresses. */
async function standIn(answer: (meant: string, response: ServerResponse) => void) {
  const server = createServer((request, response) => { request.resume(); request.on('end', () => answer(String(request.headers['x-meant']), response)) })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const asked: { url: string; authorization?: string }[] = []
  const fetcher: ManualFetch = (url, init) => {
    asked.push({ url, authorization: init.headers?.Authorization })
    return fetch(url.replace(/^https:\/\/[^/]+/, origin), { ...init, headers: { ...init.headers, 'x-meant': url } })
  }
  return { asked, fetcher, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

test('the list request keeps to the provider\'s own origin: a redirect there is followed, a redirect elsewhere is not, and the key does not go along', async () => {
  const { dir, remove } = scratch()
  const server = await standIn((meant, response) => {
    if (meant === 'https://api.openai.com/v1/models') { response.writeHead(307, { location: '/v1/models/' }); response.end(); return }
    if (meant.startsWith('https://api.groq.com/')) { response.writeHead(307, { location: 'https://evil.example.invalid/steal' }); response.end(); return }
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify(list))
  })
  try {
    const logs: string[] = []
    let changed = 0
    const lists = new ModelLists(dir, () => 'SECRET-KEY', message => logs.push(message), () => { changed++ }, server.fetcher)
    lists.refresh('openai'); await settle()
    assert.equal(changed, 1, logs.join('\n'))
    assert.deepEqual(lists.get('openai').map(model => model.id), ['whisper-large-v9'])
    assert.deepEqual(server.asked.map(request => request.url), ['https://api.openai.com/v1/models', 'https://api.openai.com/v1/models/'], 'the redirect on the same origin was followed')
    assert.ok(server.asked.every(request => request.authorization === 'Bearer SECRET-KEY'))

    server.asked.length = 0
    lists.refresh('groq'); await settle()
    assert.equal(changed, 1, 'no list came')
    assert.deepEqual(server.asked.map(request => request.url), ['https://api.groq.com/openai/v1/models'], 'only the provider was asked, never the address in the redirect')
    assert.equal(logs.filter(line => line.includes('groq list not fetched')).length, 1)
    assert.match(logs.at(-1)!, /another origin/)
    assert.ok(!logs.join('\n').includes('SECRET-KEY'))
  } finally { await server.close(); remove() }
})

test('a provider list still arrives with an ordinary fetch, and the request carries the header the provider needs', async () => {
  const { dir, remove } = scratch()
  try {
    const seen: { url: string; headers?: Record<string, string>; redirect?: string }[] = []
    const fetcher: ManualFetch = async (url, init) => { seen.push({ url, headers: init.headers, redirect: init.redirect }); return new Response(JSON.stringify(list)) }
    const providers: [Provider, string | null][] = [['openai', 'sk-ordinary'], ['groq', 'gsk_ordinary'], ['openrouter', null]]
    for (const [provider, key] of providers) {
      new ModelLists(dir, () => key, () => {}, () => {}, fetcher).refresh(provider)
      await settle()
    }
    assert.deepEqual(seen.map(request => request.headers), [{ Authorization: 'Bearer sk-ordinary' }, { Authorization: 'Bearer gsk_ordinary' }, {}])
    assert.ok(seen.every(request => request.redirect === 'manual'))
  } finally { remove() }
})

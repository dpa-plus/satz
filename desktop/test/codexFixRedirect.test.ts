import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import http, { createServer, type IncomingHttpHeaders, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import test from 'node:test'
import { fetchWithinOrigin, MAX_REDIRECTS, RedirectRefused, type ManualFetch } from '../src/core/redirect'
import { setLanguage } from '../src/core/language'
import { transcribe, TranscriptionFailure, type TranscriberSettings } from '../src/core/transcriber'
import { encodeWAV } from '../src/core/wav'
import { makeManualFetch, type IncomingLike, type RequestLike } from '../src/main/manualFetch'

/*
 * Redirects, 14.10.2026 (the verifiers' remaining problem 5). The audit made
 * every redirect an error, so that no key crosses to another origin; that
 * also broke the ordinary one (a 307 from ".../transcriptions" to
 * ".../transcriptions/", which worked before). Now: the same origin is
 * followed, at most three times, with the same headers and body; another
 * origin is refused, and nothing is sent to it. Stand-in servers on
 * 127.0.0.1 only; no key is real.
 */

const wav = encodeWAV(new Float32Array(16_000))
const microsoft: TranscriberSettings = { provider: 'microsoft', model: '', vocabulary: [], removesFillers: true, backupAfter: null }
const noSleep = async () => {}

interface Seen { method?: string; url?: string; host?: string; headers: IncomingHttpHeaders; body: Buffer }

/** A server on 127.0.0.1 that notes every request, body included, and lets the test decide what each one gets. */
async function standIn(answer: (seen: Seen, response: ServerResponse, count: number) => void) {
  const seen: Seen[] = []
  const server = createServer((request, response) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(chunk))
    request.on('end', () => {
      seen.push({ method: request.method, url: request.url, host: request.headers.host, headers: request.headers, body: Buffer.concat(chunks) })
      answer(seen[seen.length - 1], response, seen.length)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { origin: `http://127.0.0.1:${port}`, port, seen, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

const ok = (response: ServerResponse) => { response.writeHead(200, { 'content-type': 'application/json' }); response.end('{"combinedPhrases":[{"text":"hello"}]}') }
const redirect = (response: ServerResponse, status: number, location: string) => { response.writeHead(status, { location }); response.end() }

async function rejection(work: Promise<unknown>): Promise<unknown> {
  try { await work } catch (error) { return error }
  throw new Error('did not fail')
}

// MARK: - fetchWithinOrigin

test('a redirect on the same origin is followed with the same method, headers and body (301, 302, 307 and 308)', async () => {
  for (const status of [301, 302, 307, 308]) {
    const server = await standIn((seen, response) => (seen.url === '/start' ? redirect(response, status, '/final/') : ok(response)))
    try {
      const response = await fetchWithinOrigin(fetch as ManualFetch, `${server.origin}/start`, { method: 'POST', headers: { authorization: 'Bearer SECRET', 'content-type': 'application/json' }, body: '{"audio":"xyz"}' })
      assert.equal(response.status, 200, String(status))
      assert.deepEqual(server.seen.map(seen => [seen.method, seen.url]), [['POST', '/start'], ['POST', '/final/']], String(status))
      // Both requests carry everything: the key and the audio never went anywhere but this origin.
      for (const seen of server.seen) {
        assert.equal(seen.headers.authorization, 'Bearer SECRET')
        assert.equal(seen.headers['content-type'], 'application/json')
        assert.equal(seen.body.toString(), '{"audio":"xyz"}')
      }
    } finally { await server.close() }
  }
})

test('a 303 asks for a GET: no body, no content type, and the key still only to this origin', async () => {
  const server = await standIn((seen, response) => (seen.url === '/start' ? redirect(response, 303, `${server.origin}/result`) : ok(response)))
  try {
    await fetchWithinOrigin(fetch as ManualFetch, `${server.origin}/start`, { method: 'POST', headers: { 'x-goog-api-key': 'SECRET', 'Content-Type': 'application/json' }, body: '{"a":1}' })
    assert.deepEqual(server.seen.map(seen => [seen.method, seen.url, seen.body.length]), [['POST', '/start', 7], ['GET', '/result', 0]])
    assert.equal(server.seen[1].headers['x-goog-api-key'], 'SECRET')
    assert.equal(server.seen[1].headers['content-type'], undefined)
  } finally { await server.close() }
})

test('a relative address and an absolute one on the same origin are both the same origin', async () => {
  for (const location of ['../elsewhere/', '/elsewhere/', '//127.0.0.1:PORT/elsewhere/', 'HTTP://127.0.0.1:PORT/elsewhere/']) {
    const server = await standIn((seen, response) => (seen.url === '/a/b' ? redirect(response, 307, location.replace('PORT', String(server.port))) : ok(response)))
    try {
      assert.equal((await fetchWithinOrigin(fetch as ManualFetch, `${server.origin}/a/b`, { method: 'POST', body: 'x' })).status, 200, location)
      assert.equal(server.seen[1].url, '/elsewhere/', location)
    } finally { await server.close() }
  }
})

test(`up to ${MAX_REDIRECTS} redirects are followed, the next one is refused`, async () => {
  const chain = (hops: number) => standIn((seen, response) => {
    const at = Number(seen.url!.slice(1))
    if (at < hops) redirect(response, 307, `/${at + 1}`)
    else ok(response)
  })
  const three = await chain(MAX_REDIRECTS)
  try {
    assert.equal((await fetchWithinOrigin(fetch as ManualFetch, `${three.origin}/0`, { method: 'POST', body: 'x' })).status, 200)
    assert.equal(three.seen.length, MAX_REDIRECTS + 1)
  } finally { await three.close() }
  const four = await chain(MAX_REDIRECTS + 1)
  try {
    const error = await rejection(fetchWithinOrigin(fetch as ManualFetch, `${four.origin}/0`, { method: 'POST', body: 'x' }))
    assert.ok(error instanceof RedirectRefused)
    assert.match((error as Error).message, /more than 3 times/)
    // The fourth redirect was answered but not followed.
    assert.equal(four.seen.length, MAX_REDIRECTS + 1)
  } finally { await four.close() }
  // A loop is the same thing.
  const loop = await standIn((seen, response) => redirect(response, 307, seen.url!))
  try {
    assert.ok((await rejection(fetchWithinOrigin(fetch as ManualFetch, `${loop.origin}/x`, { method: 'POST', body: 'x' }))) instanceof RedirectRefused)
    assert.equal(loop.seen.length, MAX_REDIRECTS + 1)
  } finally { await loop.close() }
})

test('a redirect to another origin is refused and nothing is sent there: another host, port or scheme', async () => {
  const server = await standIn((seen, response) => redirect(response, 307, `http://localhost:${server.port}/target${seen.url}`))
  try {
    const error = await rejection(fetchWithinOrigin(fetch as ManualFetch, `${server.origin}/start`, { method: 'POST', headers: { authorization: 'Bearer SECRET' }, body: 'audio' }))
    assert.ok(error instanceof RedirectRefused)
    assert.match((error as Error).message, /another origin/)
    // 127.0.0.1 was asked, localhost never.
    assert.deepEqual(server.seen.map(seen => seen.host?.split(':')[0]), ['127.0.0.1'])
  } finally { await server.close() }
  // The same host on another port, and http to https: other origins as well. A fetcher that says what it was asked.
  for (const target of ['http://api.example.com:8443/v1', 'https://api.example.com/v1', 'https://api.example.com:80/v1', 'http://sub.api.example.com/v1', 'http://API.EXAMPLE.COM.evil.test/v1']) {
    const asked: string[] = []
    const fetcher: ManualFetch = async url => {
      asked.push(url)
      return url === 'http://api.example.com/v1' ? new Response(null, { status: 308, headers: { location: target } }) : new Response('{}')
    }
    assert.ok((await rejection(fetchWithinOrigin(fetcher, 'http://api.example.com/v1', { method: 'POST' }))) instanceof RedirectRefused, target)
    assert.deepEqual(asked, ['http://api.example.com/v1'], target)
  }
  // The default port written out is the same origin.
  const asked: string[] = []
  const fetcher: ManualFetch = async url => { asked.push(url); return asked.length === 1 ? new Response(null, { status: 307, headers: { location: 'http://api.example.com:80/v1/' } }) : new Response('{}') }
  assert.equal((await fetchWithinOrigin(fetcher, 'http://api.example.com/v1', { method: 'POST' })).status, 200)
})

test('a redirect with no address, or one that is none, is refused; a 3xx that is no redirect is an answer', async () => {
  for (const location of [undefined, '', 'http://[bad']) {
    const fetcher: ManualFetch = async () => new Response(null, { status: 307, headers: location === undefined ? {} : { location } })
    assert.ok((await rejection(fetchWithinOrigin(fetcher, 'http://127.0.0.1:9/x', { method: 'POST' }))) instanceof RedirectRefused, String(location))
  }
  for (const status of [300, 304, 305]) {
    const fetcher: ManualFetch = async () => new Response(null, { status, headers: { location: 'http://elsewhere.test/' } })
    assert.equal((await fetchWithinOrigin(fetcher, 'http://127.0.0.1:9/x', { method: 'POST' })).status, status)
  }
})

test('every request asks its fetcher not to follow redirects by itself', async () => {
  const asked: unknown[] = []
  const fetcher: ManualFetch = async (url, init) => { asked.push(init.redirect); return url.endsWith('/a') ? new Response(null, { status: 307, headers: { location: '/b' } }) : new Response('{}') }
  await fetchWithinOrigin(fetcher, 'http://127.0.0.1:9/a', { method: 'POST' })
  assert.deepEqual(asked, ['manual', 'manual'])
})

// MARK: - transcribe()

test('transcribe follows the ordinary redirect (a trailing slash) with the key and the audio, for Microsoft and for Custom', async () => {
  setLanguage('en')
  const answers = (seen: Seen, response: ServerResponse) => (seen.url!.endsWith('/') ? ok(response) : redirect(response, 307, `${seen.url}/`))
  const server = await standIn(answers)
  try {
    assert.equal(await transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY-1', fetch as never, noSleep), 'hello')
    assert.equal(server.seen.length, 2)
    assert.equal(server.seen[1].url, '/speechtotext/transcriptions:transcribe?api-version=2025-10-15/')
    for (const seen of server.seen) {
      assert.equal(seen.headers['ocp-apim-subscription-key'], 'KEY-1')
      assert.match(String(seen.headers['content-type']), /^multipart\/form-data; boundary=/)
      assert.ok(seen.body.length > wav.length, 'the audio went with it')
    }
    // The second request carries the same audio as the first.
    assert.equal(server.seen[1].body.includes(Buffer.from(wav.slice(44, 200))), true)
  } finally { await server.close() }
  const custom = await standIn((seen, response) => (seen.url === '/v1/audio/transcriptions' ? redirect(response, 308, '/v1/audio/transcriptions/') : (response.writeHead(200), response.end('{"text":"hello custom"}'))))
  try {
    assert.equal(await transcribe({ ...microsoft, provider: 'custom', customBaseURL: `${custom.origin}/v1` }, wav, 'KEY-2', fetch as never, noSleep), 'hello custom')
    assert.deepEqual(custom.seen.map(seen => [seen.method, seen.url, seen.headers.authorization]), [['POST', '/v1/audio/transcriptions', 'Bearer KEY-2'], ['POST', '/v1/audio/transcriptions/', 'Bearer KEY-2']])
  } finally { await custom.close() }
})

test('transcribe refuses a redirect to another origin as "Address redirects", after one request, and the key is in no log text', async () => {
  const server = await standIn((seen, response) => redirect(response, 307, `http://localhost:${server.port}/target${seen.url}`))
  try {
    for (const settings of [{ ...microsoft, microsoftEndpoint: server.origin }, { ...microsoft, provider: 'custom' as const, customBaseURL: server.origin }]) {
      server.seen.length = 0
      const failed = await rejection(transcribe(settings, wav, 'SECRET-KEY', fetch as never, noSleep)) as TranscriptionFailure
      assert.equal(failed.kind, 'redirected')
      assert.ok(!failed.message.includes('SECRET-KEY'))
      assert.deepEqual(server.seen.map(seen => seen.host?.split(':')[0]), ['127.0.0.1'])
      setLanguage('de')
      assert.equal(failed.short, 'Adresse leitet um')
      setLanguage('en')
      assert.equal(failed.short, 'Address redirects')
    }
  } finally { await server.close(); setLanguage('en') }
})

test('transcribe gives up on a redirect that never ends', async () => {
  const loop = await standIn((seen, response) => redirect(response, 307, seen.url!))
  try {
    const failed = await rejection(transcribe({ ...microsoft, microsoftEndpoint: loop.origin }, wav, 'KEY', fetch as never, noSleep)) as TranscriptionFailure
    assert.equal(failed.kind, 'redirected')
    assert.equal(loop.seen.length, MAX_REDIRECTS + 1)
  } finally { await loop.close() }
})

// MARK: - Electron's network stack, through makeManualFetch

/**
 * What the app gives makeManualFetch is `net.request`. This is a stand-in for
 * it over Node's http, with the same events: 'response' for an answer,
 * 'redirect' (status, method, new address) for a redirect, which without
 * followRedirect() ends the request, and abort(). Electron itself was probed
 * separately (scratchpad/f07/electron-probe).
 */
function netRequest(log: string[] = []): (options: { method: string; url: string; redirect: 'manual' }) => RequestLike {
  return options => {
    const request = new EventEmitter() as RequestLike
    const headers: Record<string, string> = {}
    let sent: http.ClientRequest | undefined
    log.push(`open ${options.method} ${options.url} ${options.redirect}`)
    request.setHeader = (name, value) => { headers[name] = value }
    request.abort = () => { log.push('abort'); sent?.destroy() }
    request.end = chunk => {
      sent = http.request(options.url, { method: options.method, headers }, answer => {
        if ([301, 302, 303, 307, 308].includes(answer.statusCode!) && answer.headers.location) {
          answer.resume()
          request.emit('redirect', answer.statusCode, options.method, new URL(answer.headers.location, options.url).href, answer.headers)
          return
        }
        request.emit('response', answer as unknown as IncomingLike)
      })
      sent.on('error', error => request.emit('error', error))
      sent.end(chunk)
    }
    return request
  }
}

test('the app\'s fetch (net.request in a stand-in) sends the form and the headers, reads the answer, and hands a redirect back', async () => {
  const server = await standIn((seen, response) => (seen.url!.endsWith('/') ? ok(response) : redirect(response, 307, `${seen.url}/`)))
  try {
    const log: string[] = []
    const fetcher = makeManualFetch(netRequest(log))
    assert.equal(await transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY-3', fetcher, noSleep), 'hello')
    assert.equal(server.seen.length, 2)
    for (const seen of server.seen) {
      assert.equal(seen.headers['ocp-apim-subscription-key'], 'KEY-3')
      assert.match(String(seen.headers['content-type']), /^multipart\/form-data; boundary=/)
      // The whole form arrived: the audio part is the WAV, byte for byte.
      assert.equal(seen.body.includes(Buffer.from(wav)), true)
      assert.match(seen.body.toString('latin1'), /name="definition"/)
    }
    // Two requests; the first was stopped at its redirect (Electron cancels it), not followed.
    const path = `${server.origin}/speechtotext/transcriptions:transcribe?api-version=2025-10-15`
    assert.deepEqual(log, [`open POST ${path} manual`, 'abort', `open POST ${path}/ manual`])
  } finally { await server.close() }
  // JSON stays JSON: its own content type is kept.
  const json = await standIn((_, response) => { response.writeHead(200); response.end('{"output_text":"hi"}') })
  try {
    assert.equal(await transcribe({ provider: 'google', model: '', vocabulary: [], removesFillers: false }, wav, 'KEY-4', makeManualFetch(options => netRequest()({ ...options, url: options.url.replace(/^https:\/\/[^/]+/, json.origin) })), noSleep), 'hi')
    assert.equal(json.seen[0].headers['content-type'], 'application/json')
    assert.equal(json.seen[0].headers['x-goog-api-key'], 'KEY-4')
  } finally { await json.close() }
})

test('the app\'s fetch: a redirect to another origin sends nothing there, and the card says "Address redirects"', async () => {
  const server = await standIn((seen, response) => redirect(response, 307, `http://localhost:${server.port}/target${seen.url}`))
  try {
    const failed = await rejection(transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'SECRET-KEY', makeManualFetch(netRequest()), noSleep)) as TranscriptionFailure
    assert.equal(failed.kind, 'redirected')
    assert.deepEqual(server.seen.map(seen => seen.host?.split(':')[0]), ['127.0.0.1'])
  } finally { await server.close() }
})

test('the app\'s fetch: a discard cancels the request in flight and rejects with an AbortError, also one that was aborted before it began', async () => {
  const server = await standIn(() => { /* never answers */ })
  try {
    const log: string[] = []
    const controller = new AbortController()
    const work = makeManualFetch(netRequest(log))(`${server.origin}/x`, { method: 'POST', body: 'x', redirect: 'manual', signal: controller.signal })
    await new Promise(resolve => setTimeout(resolve, 100))
    controller.abort()
    assert.equal(((await rejection(work)) as Error).name, 'AbortError')
    assert.ok(log.includes('abort'))
    const before = log.length
    const early = AbortSignal.abort()
    assert.equal(((await rejection(makeManualFetch(netRequest(log))(`${server.origin}/x`, { method: 'POST', redirect: 'manual', signal: early }))) as Error).name, 'AbortError')
    assert.equal(log.length, before, 'nothing was opened')
  } finally { await server.close() }
})

test('the app\'s fetch: a connection that fails or breaks off is an error, an empty answer an empty body', async () => {
  const fetcher = makeManualFetch(netRequest())
  assert.ok(await rejection(fetcher('http://127.0.0.1:1/x', { method: 'POST', body: 'x', redirect: 'manual' })))
  const empty = await standIn((_, response) => { response.writeHead(204); response.end() })
  try {
    const answer = await fetcher(`${empty.origin}/x`, { method: 'GET', redirect: 'manual' })
    assert.equal(answer.status, 204)
    assert.equal(await answer.text(), '')
  } finally { await empty.close() }
  // A fake that breaks off the answer.
  const breaking = makeManualFetch(() => {
    const request = new EventEmitter() as RequestLike
    request.setHeader = () => {}
    request.abort = () => {}
    request.end = () => {
      const answer = new EventEmitter() as IncomingLike
      answer.statusCode = 200
      answer.headers = {}
      request.emit('response', answer)
      answer.emit('data', Buffer.from('{"te'))
      answer.emit('aborted')
    }
    return request
  })
  assert.match(((await rejection(breaking('http://127.0.0.1:1/x', { method: 'POST', redirect: 'manual' }))) as Error).message, /closed before the answer was complete/)
})

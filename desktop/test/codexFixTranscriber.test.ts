import assert from 'node:assert/strict'
import { createServer, type IncomingHttpHeaders, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import test from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { setLanguage } from '../src/core/language'
import {
  googleBody, googleInlineLimit, googleText, makeRequest, microsoftDefinition, transcribe, TranscriptionFailure, type TranscriberSettings,
} from '../src/core/transcriber'
import { encodeWAV } from '../src/core/wav'

/*
 * Codex's hunt of 14.10.2026, desktop side of the provider findings: F07
 * (a discarded dictation must stop its requests), and section 4 (keys with
 * control characters, redirects, Google's storage, parser, model id and size,
 * Microsoft's style). Stand-in servers on 127.0.0.1 only; no key is real.
 */

const wav = encodeWAV(new Float32Array(16_000))
const microsoft: TranscriberSettings = { provider: 'microsoft', model: '', vocabulary: [], removesFillers: true, backupAfter: null }
const google: TranscriberSettings = { provider: 'google', model: '', vocabulary: [], removesFillers: true }
const openrouter: TranscriberSettings = { provider: 'openrouter', model: '', vocabulary: [], removesFillers: false }
const noSleep = async () => {}

interface Seen { url?: string; host?: string; headers: IncomingHttpHeaders }

/** A server on 127.0.0.1 that notes every request and lets the test decide what each one gets. */
async function standIn(answer: (seen: Seen, response: ServerResponse, count: number) => void) {
  const seen: Seen[] = []
  const server = createServer((request, response) => {
    request.resume()
    request.on('end', () => {
      seen.push({ url: request.url, host: request.headers.host, headers: request.headers })
      answer(seen[seen.length - 1], response, seen.length)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return { origin: `http://127.0.0.1:${port}`, port, seen, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

/** The fixed hosts of Google and OpenRouter are reached by a fetch that sends the request to the stand-in instead. */
const reaching = (origin: string) => (async (url: string, init: RequestInit) => fetch(url.replace(/^https:\/\/[^/]+/, origin), init)) as never

async function failure(work: Promise<unknown>): Promise<TranscriptionFailure> {
  try { await work } catch (error) { return error as TranscriptionFailure }
  throw new Error('did not fail')
}

/** For code that throws at once. */
function refused(work: () => unknown): TranscriptionFailure {
  try { work() } catch (error) { return error as TranscriptionFailure }
  throw new Error('did not fail')
}

async function until(done: () => boolean, ms = 3000) {
  for (const start = Date.now(); !done(); await delay(5)) if (Date.now() - start > ms) throw new Error('timed out waiting')
}

/** What a settled-or-not call looks like after `ms`: the error it rejected with, or a word for the other cases. */
async function outcome(work: Promise<unknown>, ms: number): Promise<unknown> {
  return Promise.race([work.then(() => 'resolved', (error: unknown) => error), delay(ms).then(() => 'still running')])
}

const isAbort = (value: unknown) => (value as Error | undefined)?.name === 'AbortError'

// MARK: - F07: a discarded dictation stops its requests

test('F07: a discard during the wait after a 429 ends the call at once, and no second POST goes out', async () => {
  const server = await standIn((_, response) => { response.writeHead(429, { 'retry-after': '1', 'content-type': 'application/json' }); response.end('{}') })
  try {
    const controller = new AbortController()
    const started = Date.now()
    const work = transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY', fetch as never, controller.signal)
    await until(() => server.seen.length === 1)
    controller.abort()
    const result = await outcome(work, 500)
    assert.ok(isAbort(result), `rejected with ${String(result)}`)
    // Not after the second the provider asked for.
    assert.ok(Date.now() - started < 500)
    await delay(1300)
    assert.equal(server.seen.length, 1)
  } finally { await server.close() }
})

test('F07: a discard while the request is in flight cancels it', async () => {
  const server = await standIn(() => { /* never answers */ })
  try {
    const controller = new AbortController()
    const work = transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY', fetch as never, controller.signal)
    await until(() => server.seen.length === 1)
    controller.abort()
    // An AbortError, not "timed out" and not "no connection".
    assert.ok(isAbort(await outcome(work, 500)))
  } finally { await server.close() }
})

test('F07: a signal that is aborted already sends nothing', async () => {
  let calls = 0
  const counting = (async () => { calls++; return new Response('{}') }) as never
  const controller = new AbortController()
  controller.abort()
  for (const settings of [microsoft, google, openrouter, { ...microsoft, provider: 'custom' as const, customBaseURL: 'http://127.0.0.1:1' }])
    assert.ok(isAbort(await outcome(transcribe(settings, wav, 'KEY', counting, controller.signal), 500)))
  assert.equal(calls, 0)
})

test('F07: a discard before OpenRouter\'s backup request is due keeps the backup from going out', async () => {
  const server = await standIn(() => { /* the first request is slow for good */ })
  try {
    const controller = new AbortController()
    const work = transcribe({ ...openrouter, backupAfter: 0.4 }, wav, 'KEY', reaching(server.origin), controller.signal)
    await until(() => server.seen.length === 1)
    await delay(100)
    controller.abort()
    assert.ok(isAbort(await outcome(work, 500)))
    // Well past the 0.4 s plus the upload time at 1 Mbit/s.
    await delay(900)
    assert.equal(server.seen.length, 1)
  } finally { await server.close() }
})

test('F07: a discard after the backup went out cancels both requests', async () => {
  const server = await standIn(() => { /* neither answers */ })
  try {
    const controller = new AbortController()
    const work = transcribe({ ...openrouter, backupAfter: 0.1 }, wav, 'KEY', reaching(server.origin), controller.signal)
    await until(() => server.seen.length === 2)
    controller.abort()
    assert.ok(isAbort(await outcome(work, 500)))
  } finally { await server.close() }
})

test('F07: without a signal, and with the wait given in the old place, a call works as before', async () => {
  const answers = [new Response('{}', { status: 429, headers: { 'retry-after': '0' } }), new Response('{"text":" Hallo. "}')]
  assert.equal(await transcribe({ ...openrouter, backupAfter: null }, wav, 'KEY', (async () => answers.shift()!) as never, noSleep), 'Hallo.')
  const more = [new Response('{}', { status: 429, headers: { 'retry-after': '0' } }), new Response('{"text":"Noch einmal."}')]
  assert.equal(await transcribe({ ...openrouter, backupAfter: null }, wav, 'KEY', (async () => more.shift()!) as never, new AbortController().signal, noSleep), 'Noch einmal.')
})

// MARK: - Keys that no header can carry

test('a key with a control character is refused before anything is sent, and never reaches the failure text', async () => {
  const keys = ['sk-first-half\nsk-second-half', 'sk-first-half\r\nsk-second-half', 'sk-first-half\0sk-second-half', 'sk-first-half\tsk-second-half', 'sk-first-half\u007fsk-second-half', 'sk-first-half’sk-second-half']
  const providers: TranscriberSettings[] = [
    microsoft, google, { ...openrouter, backupAfter: null }, { ...microsoft, provider: 'custom', customBaseURL: 'http://127.0.0.1:1' }, { ...microsoft, provider: 'openai' }, { ...microsoft, provider: 'groq' },
  ]
  for (const settings of providers) {
    for (const key of keys) {
      const calls: string[] = []
      // What Electron's net.fetch and Node's fetch do with such a header: refuse it and quote it.
      const refusing = (async (_: string, init: { headers: Record<string, string> }) => {
        calls.push('fetch')
        throw new TypeError(`Headers.append: "${Object.values(init.headers).join(' ')}" is an invalid header value.`)
      }) as never
      const failed = await failure(transcribe(settings, wav, key, refusing, noSleep))
      assert.equal(failed.kind, 'unauthorized', `${settings.provider} ${JSON.stringify(key)}`)
      assert.deepEqual(calls, [], 'no request was attempted')
      for (const half of ['sk-first-half', 'sk-second-half']) {
        assert.ok(!failed.message.includes(half), failed.message)
        assert.ok(!String(failed.detail).includes(half))
      }
      setLanguage('de')
      assert.equal(failed.short, 'Schlüssel abgelehnt')
      setLanguage('en')
      assert.equal(failed.short, 'Key rejected')
    }
  }
})

test('an ordinary key, with a space or not, is still sent', async () => {
  const server = await standIn((_, response) => { response.writeHead(200, { 'content-type': 'application/json' }); response.end('{"combinedPhrases":[{"text":"ok"}]}') })
  try {
    for (const key of ['0123456789abcdef0123456789abcdef', 'with space', 'ünicode-latin1']) {
      assert.equal(await transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, key, fetch as never, noSleep), 'ok')
    }
  } finally { await server.close() }
})

test('a transport error never carries the key into the failure, whichever header it was in', async () => {
  const key = 'SECRET-KEY-0123456789'
  const quoting = (shape: (key: string) => string) => (async () => {
    const error = new TypeError(shape(key))
    ;(error as { cause?: unknown }).cause = new Error(shape(key))
    throw error
  }) as never
  const shapes = [
    (k: string) => `Headers.append: "Bearer ${k}" is an invalid header value.`,
    (k: string) => `Headers.append: "${k}" is an invalid header value.`,
    (k: string) => `proxy refused: x-goog-api-key: ${k}\nOcp-Apim-Subscription-Key: ${k}`,
  ]
  for (const settings of [microsoft, google, { ...microsoft, provider: 'custom' as const, customBaseURL: 'http://127.0.0.1:1' }]) {
    for (const shape of shapes) {
      const failed = await failure(transcribe(settings, wav, key, quoting(shape), noSleep))
      assert.equal(failed.kind, 'offline')
      assert.ok(!failed.message.includes(key), failed.message)
      assert.ok(!String(failed.detail).includes('0123456789'))
      assert.ok(!/[\u0000-\u001f]/.test(failed.message), 'no control character in what is logged')
    }
  }
})

// MARK: - Redirects

/** A server that sends every request on to `localhost` at its own port: another origin. */
const redirecting = () => standIn((seen, response) => {
  response.writeHead(307, { location: `http://${seen.host!.replace('127.0.0.1', 'localhost')}/target${seen.url}` })
  response.end()
})

test('a redirect to another origin is not followed, so neither key nor audio goes there (Microsoft, Google, a Bearer provider)', async () => {
  const server = await redirecting()
  try {
    const cases: [string, () => Promise<unknown>][] = [
      ['microsoft', () => transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'SECRET-KEY', fetch as never, noSleep)],
      ['google', () => transcribe(google, wav, 'SECRET-KEY', reaching(server.origin), noSleep)],
      ['custom', () => transcribe({ ...microsoft, provider: 'custom', customBaseURL: server.origin }, wav, 'SECRET-KEY', fetch as never, noSleep)],
      ['openai', () => transcribe({ ...microsoft, provider: 'openai' }, wav, 'SECRET-KEY', reaching(server.origin), noSleep)],
    ]
    for (const [name, run] of cases) {
      server.seen.length = 0
      const failed = await failure(run())
      // Named for what it is, not as a lost connection.
      assert.equal(failed.kind, 'redirected', name)
      assert.ok(!failed.message.includes('SECRET-KEY'))
      assert.deepEqual(server.seen.map(seen => seen.host?.split(':')[0]), ['127.0.0.1'], name)
    }
    setLanguage('de')
    assert.equal(new TranscriptionFailure('redirected').short, 'Adresse leitet um')
    setLanguage('en')
    assert.equal(new TranscriptionFailure('redirected').short, 'Address redirects')
  } finally { await server.close() }
})

test('every provider asks its fetch for redirect "manual": net.fetch forwards Authorization on a redirect, Node\'s fetch a key header (core/redirect.ts judges it)', async () => {
  const asked = async (settings: TranscriberSettings) => {
    const calls: Record<string, unknown>[] = []
    const answering = (async (_: string, init: Record<string, unknown>) => { calls.push(init); return new Response('{"text":"x"}') }) as never
    await transcribe(settings, wav, 'KEY', answering, noSleep).catch(() => {})
    return calls.map(init => init.redirect)
  }
  assert.deepEqual(await asked({ ...microsoft, microsoftEndpoint: 'http://127.0.0.1:9' }), ['manual'])
  assert.deepEqual(await asked(google), ['manual'])
  assert.deepEqual(await asked({ ...microsoft, provider: 'openai' }), ['manual'])
  assert.deepEqual(await asked({ ...microsoft, provider: 'groq' }), ['manual'])
  assert.deepEqual(await asked({ ...openrouter, backupAfter: null }), ['manual'])
  assert.deepEqual(await asked({ ...microsoft, provider: 'custom', customBaseURL: 'http://127.0.0.1:9' }), ['manual'])
})

// MARK: - Google

const step = (type: string, ...texts: string[]) => ({ type, content: texts.map(text => ({ type: 'text', text })) })

test('Google: the interaction is not stored', () => {
  const body = googleBody(google, wav) as Record<string, unknown>
  assert.equal(body.store, false)
  assert.equal(JSON.parse(makeRequest(google, wav, 'KEY').body as string).store, false)
})

test('Google: a typed model id loses the "models/" of Google\'s own lists', () => {
  const model = (id: string) => (googleBody({ ...google, model: id }, wav) as { model: string }).model
  assert.equal(model('models/gemini-3.5-transcribe'), 'gemini-3.5-transcribe')
  assert.equal(model('  models/gemini-4-transcribe '), 'gemini-4-transcribe')
  assert.equal(model('gemini-3.5-transcribe'), 'gemini-3.5-transcribe')
  assert.equal(model(''), 'gemini-3.5-transcribe')
  // Nothing left of the id: the default, not an empty model.
  assert.equal(model('models/'), 'gemini-3.5-transcribe')
})

test('Google: thought steps are not speech, and only the first candidate is read', () => {
  assert.equal(googleText({ steps: [step('thought', 'internal thought'), step('model_output', 'spoken words')] }), 'spoken words')
  assert.equal(googleText({ steps: [step('thought', 'only thinking')] }), '')
  assert.equal(googleText({ candidates: [{ content: { parts: [{ text: 'first alternative' }] } }, { content: { parts: [{ text: 'second alternative' }] } }] }), 'first alternative')
  // A first candidate without words (blocked) hands over to the next.
  assert.equal(googleText({ candidates: [{ content: { parts: [] } }, { content: { parts: [{ text: 'second alternative' }] } }] }), 'second alternative')
  assert.equal(googleText({ candidates: [{ content: { parts: [{ audioTranscription: { transcription: 'Als Objekt.' } }, { text: 'Und Text.' }] } }] }), 'Als Objekt. Und Text.')
})

test('Google: the "outputs" list is read, as on the Mac', () => {
  assert.equal(googleText({ outputs: [{ type: 'text', text: 'spoken words' }] }), 'spoken words')
  assert.equal(googleText({ outputs: [] }), '')
})

test('Google: words that come in two places are said once', () => {
  assert.equal(googleText({ output_text: 'Hallo Welt.', steps: [step('model_output', 'Hallo Welt.')] }), 'Hallo Welt.')
  assert.equal(googleText({ steps: [step('model_output', 'Hallo Welt.')], outputs: [{ type: 'text', text: 'Hallo Welt.' }], output_text: 'Hallo Welt.' }), 'Hallo Welt.')
  assert.equal(googleText({ output_text: 'Hallo Welt.', candidates: [{ content: { parts: [{ text: 'Hallo Welt.' }] } }] }), 'Hallo Welt.')
  // The steps stay in front: they are the documented answer.
  assert.equal(googleText({ output_text: 'The copy.', steps: [step('model_output', 'The original.')] }), 'The original.')
  // An answer that has the places but no words in any of them is silence.
  assert.equal(googleText({ output_text: '', steps: [step('model_output')] }), '')
  assert.equal(googleText({ id: 'x' }), undefined)
})

test('Google: the size limit counts the JSON as sent, word list, escapes and multi-byte letters included', () => {
  const words = (word: string) => Array.from({ length: 1000 }, () => word.repeat(100))
  const sent = (settings: TranscriberSettings, bytes: number) => makeRequest(settings, new Uint8Array(bytes), 'KEY')
  // Codex's case: 1000 words of 100 letters made a 20,036,534-byte body from 14,950,000 bytes of audio.
  assert.equal((refused(() => sent({ ...google, vocabulary: words('x') }, 14_950_000))).kind, 'tooLarge')
  // Every quote is two bytes in JSON, every ä two in UTF-8.
  assert.equal((refused(() => sent({ ...google, vocabulary: words('"') }, 14_940_000))).kind, 'tooLarge')
  assert.equal((refused(() => sent({ ...google, vocabulary: words('ä') }, 14_940_000))).kind, 'tooLarge')
  // The same audio without the list still goes: it is the word list that tips it.
  assert.ok(Buffer.byteLength(sent(google, 14_940_000).body as string) <= googleInlineLimit)
  // To the byte: the largest recording whose body fits is sent, three bytes more is not.
  const settings = { ...google, vocabulary: words('ä') }
  const shell = Buffer.byteLength(JSON.stringify(googleBody(settings, new Uint8Array(0))))
  const largest = 3 * Math.floor((googleInlineLimit - shell) / 4)
  assert.equal(Buffer.byteLength(sent(settings, largest).body as string), shell + (largest / 3) * 4)
  assert.ok(Buffer.byteLength(sent(settings, largest).body as string) <= googleInlineLimit)
  assert.equal((refused(() => sent(settings, largest + 3))).kind, 'tooLarge')
})

// MARK: - Microsoft

test('Microsoft: the transcribe style goes only to MAI-Transcribe 2', () => {
  const mode = (model: string, removesFillers = true) => (microsoftDefinition({ ...microsoft, model, removesFillers }) as { enhancedMode?: Record<string, unknown> }).enhancedMode
  assert.deepEqual(mode(''), { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } })
  assert.deepEqual(mode('mai-transcribe-2', false), { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'verbatim' } })
  assert.deepEqual(mode('MAI-Transcribe-2'), { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } })
  // Any other model typed in by hand is named, nothing more.
  assert.deepEqual(mode('mai-transcribe-1.5'), { enabled: true, model: 'mai-transcribe-1.5' })
  assert.deepEqual(mode('some-other-enhanced-model'), { enabled: true, model: 'some-other-enhanced-model' })
  assert.equal(mode('azure-speech'), undefined)
})

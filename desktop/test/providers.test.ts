import assert from 'node:assert/strict'
import { createServer, type IncomingHttpHeaders } from 'node:http'
import type { AddressInfo } from 'node:net'
import test from 'node:test'
import { setLanguage } from '../src/core/language'
import { choiceFor, models } from '../src/core/models'
import {
  googleBody, googleInlineLimit, googleText, hasCleanMode, makeRequest, microsoftDefinition, microsoftHost, microsoftModel, microsoftRegions, microsoftText,
  providers, transcribe, TranscriptionFailure, type TranscriberSettings,
} from '../src/core/transcriber'
import { encodeWAV } from '../src/core/wav'

/*
 * The Microsoft and Google requests, against a stand-in server on this
 * computer that checks the exact path, headers and body, and answers with the
 * shapes the documentation shows. The real services were never called: no key.
 */

const wav = encodeWAV(new Float32Array(16_000))
const microsoft: TranscriberSettings = { provider: 'microsoft', model: '', vocabulary: ['Kubernetes', 'Klammer auf'], removesFillers: true }
const google: TranscriberSettings = { provider: 'google', model: '', vocabulary: ['Kubernetes', 'Klammer auf'], removesFillers: true }

interface Seen { method?: string; url?: string; headers: IncomingHttpHeaders; body: Buffer }

/** A server on 127.0.0.1 that records every request and answers with `reply`. */
async function standIn(reply: (seen: Seen, count: number) => { status: number; body: string; headers?: Record<string, string> }) {
  const seen: Seen[] = []
  const server = createServer((request, response) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(chunk))
    request.on('end', () => {
      seen.push({ method: request.method, url: request.url, headers: request.headers, body: Buffer.concat(chunks) })
      const answer = reply(seen[seen.length - 1], seen.length)
      response.writeHead(answer.status, { 'content-type': 'application/json', ...answer.headers })
      response.end(answer.body)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  return { origin, seen, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

/** Google's host is fixed, so the stand-in is reached by a fetch that notes the real address and sends the request to it instead. */
const redirecting = (origin: string, asked: string[]) => (async (url: string, init: RequestInit) => {
  asked.push(url)
  return fetch(url.replace('https://generativelanguage.googleapis.com', origin), init)
}) as never

const noSleep = async () => {}

/** A form's part names; the DOM typings in this project lack the iterators. */
const partsOf = (form: FormData) => [...(form as unknown as { keys(): Iterable<string> }).keys()]

async function failure(work: Promise<unknown>): Promise<TranscriptionFailure> {
  try { await work } catch (error) { return error as TranscriptionFailure }
  throw new Error('did not fail')
}

// MARK: - The provider list

test('Microsoft and Google are providers with their own key, default model and menu', () => {
  assert.equal(providers.microsoft.defaultModel, 'mai-transcribe-2')
  assert.equal(providers.google.defaultModel, 'gemini-3.5-transcribe')
  assert.equal(providers.google.baseURL, 'https://generativelanguage.googleapis.com/v1beta')
  assert.deepEqual(models.microsoft.map(model => model.id), ['mai-transcribe-2', 'azure-speech'])
  assert.deepEqual(models.google.map(model => model.id), ['gemini-3.5-transcribe'])
  // Prices per hour, and the promotion said in the facts line.
  const mai = choiceFor(models.microsoft, 'mai-transcribe-2')!
  assert.deepEqual([mai.name, mai.maker, mai.dollarsPerHour, mai.errorRate], ['MAI-Transcribe 2', 'Microsoft', 0.10, 2.0])
  assert.match(mai.note!.de, /bis 31\.12\.2026.*0,36 \$/)
  assert.match(mai.note!.en, /until 31 Dec 2026.*\$0\.36/)
  assert.equal(choiceFor(models.microsoft, 'azure-speech')!.dollarsPerHour, 0.36)
  const gemini = models.google[0]
  assert.deepEqual([gemini.name, gemini.maker, gemini.dollarsPerHour], ['Gemini 3.5 Transcribe', 'Google', 0.30])
  assert.match(gemini.note!.en, /free-tier key.*improve its products/)
  for (const choice of [...models.microsoft, ...models.google]) assert.doesNotMatch(JSON.stringify(choice), /—/)
})

test('the clean switch is for MAI-Transcribe 2 wherever it runs, and for Gemini', () => {
  assert.equal(hasCleanMode('microsoft', ''), true)
  assert.equal(hasCleanMode('microsoft', 'mai-transcribe-2'), true)
  assert.equal(hasCleanMode('microsoft', 'azure-speech'), false)
  assert.equal(hasCleanMode('openrouter', 'microsoft/mai-transcribe-2'), true)
  assert.equal(hasCleanMode('openrouter', 'microsoft/mai-transcribe-1.5'), false)
  assert.equal(hasCleanMode('google', ''), true)
  assert.equal(hasCleanMode('groq', ''), false)
})

// MARK: - Microsoft

test('Microsoft: the host comes from the region, an own address wins, and nothing but https leaves this computer', () => {
  assert.equal(microsoftHost(undefined, undefined), 'https://northeurope.api.cognitive.microsoft.com')
  assert.deepEqual(microsoftRegions.map(region => region.id), ['northeurope', 'eastus', 'westus', 'westus2', 'centralindia', 'southeastasia'])
  for (const region of microsoftRegions) assert.equal(microsoftHost(region.id, ''), `https://${region.id}.api.cognitive.microsoft.com`)
  assert.equal(microsoftHost('eastus', '  https://my-speech.cognitiveservices.azure.com/speechtotext/x?y=1  '), 'https://my-speech.cognitiveservices.azure.com')
  // Pasted without the scheme, as the portal shows it.
  assert.equal(microsoftHost('eastus', 'my-speech.cognitiveservices.azure.com'), 'https://my-speech.cognitiveservices.azure.com')
  assert.equal(microsoftHost('eastus', 'http://127.0.0.1:9999'), 'http://127.0.0.1:9999')
  assert.equal(microsoftHost('eastus', 'http://speech.example.com'), null)
  assert.equal(microsoftHost('eastus', 'ftp://speech.example.com'), null)
  assert.equal(microsoftHost('eastus', 'https://'), null)
  // A region that cannot be one never becomes part of an address.
  assert.equal(microsoftHost('evil.example.com/x', ''), null)
  assert.equal(microsoftHost('East US', ''), null)
})

test('Microsoft: the request is a multipart POST to transcriptions:transcribe with the key in Ocp-Apim-Subscription-Key', async () => {
  const request = makeRequest({ ...microsoft, microsoftRegion: 'northeurope' }, wav, 'KEY')
  assert.equal(request.url, 'https://northeurope.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15')
  assert.deepEqual(request.headers, { 'Ocp-Apim-Subscription-Key': 'KEY' })
  assert.ok(request.body instanceof FormData)
  const form = request.body as FormData
  assert.deepEqual(partsOf(form), ['audio', 'definition'])
  const audio = form.get('audio') as File
  assert.equal(audio.type, 'audio/wav')
  assert.deepEqual(new Uint8Array(await audio.arrayBuffer()), wav)
  assert.equal(typeof form.get('definition'), 'string')
  assert.deepEqual(JSON.parse(form.get('definition') as string), {
    enhancedMode: { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } },
    phraseList: { phrases: ['Kubernetes', 'Klammer auf'] },
  })
  assert.equal(makeRequest({ ...microsoft, microsoftRegion: 'westus2' }, wav, 'KEY').url, 'https://westus2.api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15')
  assert.equal(makeRequest({ ...microsoft, microsoftRegion: 'westus2', microsoftEndpoint: 'https://r.cognitiveservices.azure.com/' }, wav, 'KEY').url,
    'https://r.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15')
})

test('Microsoft: "Füllwörter weglassen" is the transcribe style; Azure Speech is plain fast transcription; no locales unless a language is fixed', () => {
  assert.equal(microsoftDefinition({ ...microsoft, removesFillers: false }).enhancedMode && (microsoftDefinition({ ...microsoft, removesFillers: false }).enhancedMode as any).modelOptions.transcribeStyle, 'verbatim')
  // No vocabulary, no phrase list; no language, no locales.
  assert.deepEqual(microsoftDefinition({ ...microsoft, vocabulary: [] }), { enhancedMode: { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } } })
  assert.deepEqual(microsoftDefinition({ ...microsoft, model: 'azure-speech' }), { phraseList: { phrases: ['Kubernetes', 'Klammer auf'] } })
  assert.deepEqual((microsoftDefinition({ ...microsoft, language: 'de' }) as any).locales, ['de-DE'])
  assert.deepEqual((microsoftDefinition({ ...microsoft, language: 'en' }) as any).locales, ['en-US'])
  assert.equal(microsoftModel('azure-speech'), null)
  assert.equal(microsoftModel('MAI-Transcribe-2'), 'MAI-Transcribe-2')
  assert.equal(microsoftModel('mai-transcribe-3'), 'mai-transcribe-3')
})

test('Microsoft: an unusable address fails before anything is sent', () => {
  assert.throws(() => makeRequest({ ...microsoft, microsoftEndpoint: 'http://speech.example.com' }, wav, 'KEY'), (error: TranscriptionFailure) => error.kind === 'server')
})

test('Microsoft against the stand-in: the multipart body arrives whole, the text of combinedPhrases comes back', async () => {
  const server = await standIn(() => ({ status: 200, body: JSON.stringify({
    durationMilliseconds: 1000,
    combinedPhrases: [{ text: 'Hallo Welt. Das ist ein Test.' }],
    phrases: [{ offsetMilliseconds: 0, durationMilliseconds: 1000, text: 'Hallo Welt. Das ist ein Test.', words: [], locale: 'de-DE', confidence: 0.9 }],
  }) }))
  try {
    const text = await transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY', fetch as never, noSleep)
    assert.equal(text, 'Hallo Welt. Das ist ein Test.')
    assert.equal(server.seen.length, 1)
    const [seen] = server.seen
    assert.equal(seen.method, 'POST')
    assert.equal(seen.url, '/speechtotext/transcriptions:transcribe?api-version=2025-10-15')
    assert.equal(seen.headers['ocp-apim-subscription-key'], 'KEY')
    assert.equal(seen.headers.authorization, undefined)
    assert.match(seen.headers['content-type'] as string, /^multipart\/form-data; boundary=/)
    // Parsed by the same rules any server would use.
    const form = await new Response(new Uint8Array(seen.body), { headers: { 'content-type': seen.headers['content-type'] as string } }).formData()
    assert.deepEqual(partsOf(form), ['audio', 'definition'])
    const audio = form.get('audio') as File
    assert.equal(audio.name, 'speech.wav')
    assert.equal(audio.type, 'audio/wav')
    assert.deepEqual(new Uint8Array(await audio.arrayBuffer()), wav)
    assert.deepEqual(JSON.parse(form.get('definition') as string), {
      enhancedMode: { enabled: true, model: 'MAI-Transcribe-2', modelOptions: { transcribeStyle: 'clean' } },
      phraseList: { phrases: ['Kubernetes', 'Klammer auf'] },
    })
  } finally { await server.close() }
})

test('Microsoft: the answers it documents are read, in pieces joined, and silence is empty rather than an error', () => {
  assert.equal(microsoftText({ combinedPhrases: [{ text: 'Eins.' }, { text: 'Zwei.' }] }), 'Eins. Zwei.')
  assert.equal(microsoftText({ combinedPhrases: [], phrases: [] }), '')
  assert.equal(microsoftText({ combinedPhrases: [{ text: '' }] }), '')
  assert.equal(microsoftText({ phrases: [{ text: 'Nur Phrasen.' }] }), 'Nur Phrasen.')
  assert.equal(microsoftText({}), undefined)
  assert.equal(microsoftText(null), undefined)
})

test('Microsoft: errors are named, and the two likeliest mistakes say so', async () => {
  const settings = (origin: string): TranscriberSettings => ({ ...microsoft, microsoftEndpoint: origin, attempts: 3 })
  const run = async (status: number, body: string, headers?: Record<string, string>) => {
    const server = await standIn(() => ({ status, body, headers }))
    try {
      const failed = await failure(transcribe(settings(server.origin), wav, 'KEY', fetch as never, noSleep))
      return { failed, requests: server.seen.length }
    } finally { await server.close() }
  }
  const unauthorized = await run(401, JSON.stringify({ error: { code: '401', message: 'Access denied due to invalid subscription key or wrong API endpoint.' } }))
  assert.equal(unauthorized.failed.kind, 'keyOrRegion')
  assert.equal(unauthorized.requests, 1)
  setLanguage('de')
  assert.equal(unauthorized.failed.short, 'Schlüssel oder Region falsch')
  setLanguage('en')
  assert.equal(unauthorized.failed.short, 'Key or region wrong')
  assert.equal((await run(403, '{}')).failed.kind, 'keyOrRegion')
  // Throttled: asked three times, then "busy".
  const busy = await run(429, '{}', { 'retry-after': '0' })
  assert.deepEqual([busy.failed.kind, busy.requests], ['rateLimited', 3])
  assert.equal((await run(413, '')).failed.kind, 'tooLarge')
  assert.equal((await run(400, JSON.stringify({ code: 'InvalidRequest', message: 'The audio is too long. Maximum is 2 hours.' }))).failed.kind, 'tooLarge')
  const other = await run(500, JSON.stringify({ code: 'InternalError', message: 'Something broke.' }))
  assert.deepEqual([other.failed.kind, other.failed.status, other.failed.detail], ['server', 500, 'Something broke.'])
  assert.equal((await run(400, JSON.stringify({ code: 'InvalidRequest', message: 'definition is not valid JSON' }))).failed.kind, 'server')
  // An answer that is no answer.
  assert.equal((await run(200, 'not json')).failed.kind, 'unreadableResponse')
  assert.equal((await run(200, '{"somethingElse":true}')).failed.kind, 'unreadableResponse')
  setLanguage('en')
})

test('Microsoft: an empty answer for speech is empty text, which the session treats as "not understood"', async () => {
  const server = await standIn(() => ({ status: 200, body: JSON.stringify({ durationMilliseconds: 0, combinedPhrases: [], phrases: [] }) }))
  try {
    assert.equal(await transcribe({ ...microsoft, microsoftEndpoint: server.origin }, wav, 'KEY', fetch as never, noSleep), '')
  } finally { await server.close() }
})

// MARK: - Google

test('Google: the request is JSON to /v1beta/interactions with the key in x-goog-api-key', () => {
  const request = makeRequest(google, wav, 'KEY')
  assert.equal(request.url, 'https://generativelanguage.googleapis.com/v1beta/interactions')
  assert.deepEqual(request.headers, { 'x-goog-api-key': 'KEY', 'Content-Type': 'application/json' })
  assert.equal(typeof request.body, 'string')
  assert.deepEqual(JSON.parse(request.body as string), {
    model: 'gemini-3.5-transcribe',
    input: [{ type: 'audio', data: Buffer.from(wav).toString('base64'), mime_type: 'audio/wav' }],
    generation_config: { transcription_config: { language_codes: [], custom_vocabulary: ['Kubernetes', 'Klammer auf'], mode: 'smart' } },
    // One recording, answered once: Google need not keep the interaction.
    store: false,
  })
})

test('Google: "smart" only with "Füllwörter weglassen", no empty vocabulary, a fixed language only when one is set', () => {
  const config = (settings: TranscriberSettings) => (googleBody(settings, wav).generation_config.transcription_config) as Record<string, unknown>
  assert.equal('mode' in config({ ...google, removesFillers: false }), false)
  assert.equal(config({ ...google, removesFillers: true }).mode, 'smart')
  assert.equal('custom_vocabulary' in config({ ...google, vocabulary: [] }), false)
  assert.deepEqual(config({ ...google, language: 'de' }).language_codes, ['de-DE'])
  assert.deepEqual(config(google).language_codes, [])
  // Up to 1000 terms; the list is kept as it is.
  assert.equal((config({ ...google, vocabulary: Array.from({ length: 1200 }, (_, i) => `w${i}`) }).custom_vocabulary as string[]).length, 1000)
})

test('Google: every shape the documentation shows is read; an answer with no text is silence, anything else unreadable', () => {
  const step = (...content: object[]) => ({ type: 'model_output', content })
  assert.equal(googleText({ steps: [step({ type: 'text', text: 'Hallo Welt.' })] }), 'Hallo Welt.')
  assert.equal(googleText({ steps: [{ type: 'user_input', content: [{ type: 'audio' }] }, step({ type: 'text', text: 'Eins.' }, { type: 'text', text: ' Zwei. ' })] }), 'Eins. Zwei.')
  assert.equal(googleText({ steps: [step({ type: 'output_text', text: 'Auch so.' })] }), 'Auch so.')
  assert.equal(googleText({ output_text: 'Der SDK-Weg.' }), 'Der SDK-Weg.')
  assert.equal(googleText({ candidates: [{ content: { parts: [{ audioTranscription: 'Alter Weg.' }] } }] }), 'Alter Weg.')
  assert.equal(googleText({ candidates: [{ content: { parts: [{ audioTranscription: { text: 'Als Objekt.' } }, { text: 'Und Text.' }] } }] }), 'Als Objekt. Und Text.')
  assert.equal(googleText({ steps: [step()] }), '')
  assert.equal(googleText({ steps: [] }), '')
  assert.equal(googleText({ candidates: [{ content: { parts: [] } }] }), '')
  assert.equal(googleText({ error: 'x' }), undefined)
  assert.equal(googleText('text'), undefined)
  assert.equal(googleText(null), undefined)
})

test('Google against the stand-in: exact address, key header and JSON body; the documented answer is read', async () => {
  const server = await standIn(() => ({ status: 200, body: JSON.stringify({
    id: 'v1_abc', status: 'completed', steps: [{ type: 'user_input', content: [{ type: 'audio', mime_type: 'audio/wav' }] }, { type: 'model_output', content: [{ type: 'text', text: 'Hallo Welt.' }] }],
  }) }))
  const asked: string[] = []
  try {
    const text = await transcribe({ ...google, removesFillers: false, vocabulary: ['Kubernetes'] }, wav, 'KEY', redirecting(server.origin, asked), noSleep)
    assert.equal(text, 'Hallo Welt.')
    // The address satz asked for, before the stand-in took its place.
    assert.deepEqual(asked, ['https://generativelanguage.googleapis.com/v1beta/interactions'])
    const [seen] = server.seen
    assert.equal(seen.method, 'POST')
    assert.equal(seen.url, '/v1beta/interactions')
    assert.equal(seen.headers['x-goog-api-key'], 'KEY')
    assert.equal(seen.headers.authorization, undefined)
    assert.equal(seen.headers['content-type'], 'application/json')
    const body = JSON.parse(seen.body.toString('utf8'))
    assert.deepEqual(Object.keys(body), ['model', 'input', 'generation_config', 'store'])
    assert.equal(body.store, false)
    assert.equal(body.model, 'gemini-3.5-transcribe')
    assert.equal(body.input.length, 1)
    assert.deepEqual([body.input[0].type, body.input[0].mime_type], ['audio', 'audio/wav'])
    assert.deepEqual(new Uint8Array(Buffer.from(body.input[0].data, 'base64')), wav)
    assert.deepEqual(body.generation_config, { transcription_config: { language_codes: [], custom_vocabulary: ['Kubernetes'] } })
  } finally { await server.close() }
})

test('Google: errors are named; a wrong key is a 400, not a 401', async () => {
  const run = async (status: number, body: string) => {
    const server = await standIn(() => ({ status, body, headers: { 'retry-after': '0' } }))
    try { return { failed: await failure(transcribe({ ...google, attempts: 2 }, wav, 'KEY', redirecting(server.origin, []), noSleep)), requests: server.seen.length } } finally { await server.close() }
  }
  const error = (code: number, status: string, message: string) => JSON.stringify({ error: { code, status, message } })
  assert.equal((await run(400, error(400, 'INVALID_ARGUMENT', 'API key not valid. Please pass a valid API key.'))).failed.kind, 'unauthorized')
  assert.equal((await run(403, error(403, 'PERMISSION_DENIED', 'Generative Language API has not been used in project 1 before.'))).failed.kind, 'unauthorized')
  assert.equal((await run(401, '')).failed.kind, 'unauthorized')
  const busy = await run(429, error(429, 'RESOURCE_EXHAUSTED', 'You exceeded your current quota.'))
  assert.deepEqual([busy.failed.kind, busy.requests], ['rateLimited', 2])
  assert.equal((await run(413, '')).failed.kind, 'tooLarge')
  assert.equal((await run(400, error(400, 'INVALID_ARGUMENT', 'Request payload size exceeds the limit: 20971520 bytes.'))).failed.kind, 'tooLarge')
  const other = await run(400, error(400, 'INVALID_ARGUMENT', 'Unknown name "mode" at generation_config.'))
  assert.deepEqual([other.failed.kind, other.failed.status, other.failed.detail], ['server', 400, 'Unknown name "mode" at generation_config.'])
  assert.equal((await run(503, error(503, 'UNAVAILABLE', 'The model is overloaded.'))).failed.kind, 'server')
  assert.equal((await run(200, '{"id":"x"}')).failed.kind, 'unreadableResponse')
})

test('Google: a recording that would pass 20 MB inline fails at once as too long, and nothing is sent', async () => {
  // 16 kHz mono 16-bit is 32 000 bytes a second: base64 makes it a third more.
  const seconds = (limit: number) => Math.floor((limit * 3) / 4 / 32_000)
  assert.ok(seconds(googleInlineLimit) >= 460 && seconds(googleInlineLimit) <= 470, `${seconds(googleInlineLimit)} s`)
  let sent = 0
  const counting = (async () => { sent++; return new Response(JSON.stringify({ steps: [{ type: 'model_output', content: [{ type: 'text', text: 'ok' }] }] })) }) as never
  const tooLong = new Uint8Array(15_000_000)
  const failed = await failure(transcribe(google, tooLong, 'KEY', counting, noSleep))
  assert.equal(failed.kind, 'tooLarge')
  setLanguage('de')
  assert.equal(failed.short, 'Zu lang für den Anbieter')
  setLanguage('en')
  assert.equal(sent, 0)
  // Just under goes out.
  assert.equal(await transcribe(google, new Uint8Array(14_800_000), 'KEY', counting, noSleep), 'ok')
  assert.equal(sent, 1)
})

test('a request needs its key, for the new providers too', async () => {
  for (const settings of [microsoft, google]) assert.equal((await failure(transcribe(settings, wav, '', fetch as never, noSleep))).kind, 'noKey')
})

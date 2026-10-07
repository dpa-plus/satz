import { test } from 'node:test'
import assert from 'node:assert/strict'
import { makeRequest, openRouterBody, providers, retryDelay, transcribe, TranscriptionFailure, type TranscriberSettings } from '../src/core/transcriber'
import { choiceFor, models } from '../src/core/models'
import { encodeWAV, decodeWAV, resample, level } from '../src/core/wav'

const openrouter: TranscriberSettings = { provider: 'openrouter', model: '', vocabulary: ['Kubernetes', 'Klammer auf'], removesFillers: true }
const wav = encodeWAV(new Float32Array(16_000))

test('OpenRouter gets JSON with clean mode and the phrase list', () => {
  const body = openRouterBody(openrouter, wav) as any
  assert.equal(body.model, 'microsoft/mai-transcribe-2')
  assert.equal(body.input_audio.format, 'wav')
  assert.equal(body.provider.options.azure.enhancedMode.modelOptions.transcribeStyle, 'clean')
  assert.deepEqual(body.provider.options.azure.phraseList.phrases, ['Kubernetes', 'Klammer auf'])
  const request = makeRequest(openrouter, wav, 'k')
  assert.equal(request.url, 'https://openrouter.ai/api/v1/audio/transcriptions')
  assert.equal(request.headers.Authorization, 'Bearer k')
})

test('other providers get a multipart upload', () => {
  const request = makeRequest({ provider: 'groq', model: '', vocabulary: [], removesFillers: true }, wav, 'k')
  assert.equal(request.url, 'https://api.groq.com/openai/v1/audio/transcriptions')
  assert.ok(request.body instanceof FormData)
  assert.equal((request.body as FormData).get('model'), 'whisper-large-v3-turbo')
})

test('a custom endpoint uses its own address', () => {
  const request = makeRequest({ provider: 'custom', model: 'm', customBaseURL: 'http://localhost:9000/v1/', vocabulary: [], removesFillers: true }, wav, 'k')
  assert.equal(request.url, 'http://localhost:9000/v1/audio/transcriptions')
})

test('the wait after a 429 comes from the header or the metadata, at most 5 s', () => {
  assert.equal(retryDelay('2', ''), 2)
  assert.equal(retryDelay(null, JSON.stringify({ error: { metadata: { retry_after_seconds: 3 } } })), 3)
  assert.equal(retryDelay('60', ''), 5)
  assert.equal(retryDelay(null, 'not json'), 2)
})

const response = (status: number, body: string, headers: Record<string, string> = {}) => new Response(body, { status, headers })

test('a 429 is retried, then the text comes back trimmed', async () => {
  const answers = [response(429, '{}', { 'retry-after': '0' }), response(200, '{"text":"  Hallo.  "}')]
  const text = await transcribe(openrouter, wav, 'k', async () => answers.shift()!, async () => {})
  assert.equal(text, 'Hallo.')
})

test('failures are named', async () => {
  const kind = async (r: Response) => {
    try { await transcribe({ ...openrouter, attempts: 1 }, wav, 'k', async () => r, async () => {}) } catch (e) { return (e as TranscriptionFailure).kind }
  }
  assert.equal(await kind(response(401, '')), 'unauthorized')
  assert.equal(await kind(response(429, '')), 'rateLimited')
  assert.equal(await kind(response(500, '{"error":{"message":"down"}}')), 'server')
  assert.equal(await kind(response(200, 'nope')), 'unreadableResponse')
  await assert.rejects(transcribe(openrouter, wav, '', async () => response(200, '{}')), (e: TranscriptionFailure) => e.kind === 'noKey')
})

test('WAV round trip, resampling and level', () => {
  const samples = new Float32Array([0, 0.5, -0.5, 1])
  const back = decodeWAV(encodeWAV(samples)).samples
  assert.equal(back.length, 4)
  assert.ok(Math.abs(back[1] - 0.5) < 0.001)
  assert.equal(resample(new Float32Array(48_000), 48_000).length, 16_000)
  assert.equal(level(new Float32Array(100)), 0)
  assert.ok(level(new Float32Array(100).fill(0.5)) > 0.8)
})

test('each model menu starts with the provider default and has no doubles', () => {
  for (const provider of ['openai', 'openrouter', 'groq'] as const) {
    assert.equal(models[provider][0].id, providers[provider].defaultModel)
    assert.equal(new Set(models[provider].map(m => m.id)).size, models[provider].length)
  }
  assert.equal(choiceFor('openrouter', 'someone/new-model'), undefined)
})

test('a second request answers when the first is slow; a rejected key fails at once', async () => {
  const later = (ms: number, status: number, body: string) => new Promise<Response>(resolve => setTimeout(() => resolve(response(status, body)), ms))
  let calls = 0
  const slowThenFast = async () => (++calls === 1 ? later(3000, 200, '{"text":"slow"}') : later(0, 200, '{"text":"fast"}'))
  const start = Date.now()
  assert.equal(await transcribe({ ...openrouter, backupAfter: 0.2 }, wav, 'k', slowThenFast, async () => {}), 'fast')
  assert.ok(Date.now() - start < 1500)
  assert.equal(calls, 2)

  calls = 0
  const rejected = async () => { calls++; return response(401, '') }
  await assert.rejects(transcribe({ ...openrouter, backupAfter: 0.5 }, wav, 'k', rejected, async () => {}), (e: TranscriptionFailure) => e.kind === 'unauthorized')
  await new Promise(resolve => setTimeout(resolve, 700))
  assert.equal(calls, 1)
})

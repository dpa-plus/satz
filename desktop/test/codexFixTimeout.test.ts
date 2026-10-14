import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import test from 'node:test'
import { makeRequest, requestTimeout, transcribe, TranscriptionFailure, type TranscriberSettings } from '../src/core/transcriber'
import { encodeWAV } from '../src/core/wav'

/*
 * The total time one request may take (the verifiers' problem 3 on the Mac,
 * and the same sum here): the base timeout plus a second for every TWO
 * seconds of audio. The timer runs over the upload and the answer, so with a
 * second per four, five minutes of speech got 105 s and a line below about
 * 0.7 Mbit/s failed a dictation that was only slow. The Mac allows the same
 * (Transcriber.Settings.timeout(for:)).
 */

const microsoft: TranscriberSettings = { provider: 'microsoft', model: '', vocabulary: [], removesFillers: true, backupAfter: null }
/** 16 kHz, 16 bit, mono: 32,000 bytes a second after the 44-byte header. */
const seconds = (count: number) => new Uint8Array(44 + count * 32_000)

test('the budget is the base plus a second per two seconds of audio: five minutes get 180 s, not 105', () => {
  assert.equal(requestTimeout(30, seconds(0).length), 30_000)
  assert.equal(requestTimeout(30, seconds(10).length), 35_000)
  assert.equal(requestTimeout(30, seconds(300).length), 180_000)
  assert.equal(requestTimeout(undefined, seconds(300).length), 180_000, 'the base is 30 s unless set')
  assert.equal(requestTimeout(10, seconds(60).length), 40_000)
  // Less than a header is no audio, never a negative budget.
  assert.equal(requestTimeout(30, 10), 30_000)
})

test('every provider\'s request carries that budget', () => {
  const wav = seconds(300)
  for (const settings of [microsoft, { ...microsoft, provider: 'google' as const }, { ...microsoft, provider: 'openai' as const }, { ...microsoft, provider: 'openrouter' as const },
    { ...microsoft, provider: 'custom' as const, customBaseURL: 'http://127.0.0.1:9' }]) {
    assert.equal(makeRequest(settings, wav, 'KEY').timeout, 180_000, settings.provider)
  }
  assert.equal(makeRequest({ ...microsoft, timeout: 5 }, seconds(20), 'KEY').timeout, 15_000)
})

/** A server that takes `ms` to answer. */
async function slow(ms: number) {
  const server = createServer((request, response) => {
    request.resume()
    request.on('end', () => setTimeout(() => { response.writeHead(200, { 'content-type': 'application/json' }); response.end('{"combinedPhrases":[{"text":"late but whole"}]}') }, ms))
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

test('an answer that takes longer than the base alone but less than the budget is taken; one beyond it times out', async () => {
  // One second of audio and a base of 0.1 s: the budget is 0.6 s. The old one, 0.35 s, cut the 0.45 s answer off.
  const wav = encodeWAV(new Float32Array(16_000))
  const settings = { timeout: 0.1, attempts: 1 }
  const within = await slow(450)
  try {
    assert.equal(await transcribe({ ...microsoft, ...settings, microsoftEndpoint: within.origin }, wav, 'KEY', fetch as never), 'late but whole')
  } finally { await within.close() }
  const beyond = await slow(1200)
  try {
    const failed = await transcribe({ ...microsoft, ...settings, microsoftEndpoint: beyond.origin }, wav, 'KEY', fetch as never).then(() => null, (error: unknown) => error)
    assert.ok(failed instanceof TranscriptionFailure)
    assert.equal((failed as TranscriptionFailure).kind, 'timedOut')
  } finally { await beyond.close() }
})

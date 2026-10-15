import assert from 'node:assert/strict'
import test from 'node:test'
import { parseAnswer, runCleanup } from '../src/core/cleanupRequest'
import type { CleanupProviderId } from '../src/core/cleanupProviders'

const original = 'bitte schreibe morgen eine kurze nachricht an max'
const partial = 'Bitte schreibe morgen eine kurze Nachricht.'
const malformed: [CleanupProviderId, unknown][] = [
  ['custom', { choices: [{ message: { content: [{ text: partial }, { text: 17 }] }, finish_reason: 'stop' }] }],
  ['anthropic', { content: [{ type: 'text', text: partial }, { type: 'text', text: 17 }], stop_reason: 'end_turn' }],
  ['google', { candidates: [{ content: { parts: [{ text: partial }, { text: 17 }] }, finishReason: 'STOP' }] }],
]

test('a malformed text part invalidates the whole answer in every provider family', () => {
  for (const [provider, body] of malformed) assert.equal(parseAnswer(provider, body), undefined, provider)
})

test('a malformed part never becomes a shortened cleaned dictation at any preset', async () => {
  for (const [provider, body] of malformed) for (const level of ['punctuation', 'light', 'smooth', 'polished'] as const) {
    const result = await runCleanup({ provider, base: 'http://127.0.0.1:9/v1', model: 'stand-in', key: null,
      level, customPrompt: '', vocabulary: [], text: original }, async () => new Response(JSON.stringify(body)))
    assert.equal(result.kind, 'failed', `${provider} ${level}`)
    if (result.kind === 'failed') assert.equal(result.reason, 'providerError', `${provider} ${level}`)
  }
})

test('valid multipart answers keep all text and skip provider thinking', () => {
  assert.equal(parseAnswer('custom', { choices: [{ message: { content: ['Hallo ', { type: 'text', text: 'Welt.' }] } }] })?.text, 'Hallo Welt.')
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'thinking', thinking: 'ignored' }, { type: 'text', text: 'Hallo ' }, { type: 'text', text: 'Welt.' }] })?.text, 'Hallo Welt.')
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ thought: true, text: 'ignored' }, { text: 'Hallo ' }, { text: 'Welt.' }] } }] })?.text, 'Hallo Welt.')
})

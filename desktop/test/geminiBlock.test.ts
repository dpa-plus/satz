import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import type { CleanupJob } from '../src/core/cleanupRequest'
import { parseAnswer, runCleanup } from '../src/core/cleanupRequest'
import { setLanguage } from '../src/core/language'
import { Cleaner } from '../src/main/cleanup'

/*
 * The Mac turns a Gemini answer that carries a block into "Antwort verweigert"
 * and pastes the original (CleanupRequest.parse, `refused`); Windows and Linux
 * took the text of a blocked answer, or called a block with no candidate at
 * all an unreadable answer. Both now say the same: refused, original kept.
 * Everything here is made up and goes to a function, never to a provider.
 */

setLanguage('en')
const said = 'ähm also der build ist äh gefailed weil the tests are flaky'
const cleaned = 'Also, der Build ist gefailed, weil the tests are flaky.'
const blocks = ['SAFETY', 'BLOCKLIST', 'PROHIBITED_CONTENT', 'SPII', 'RECITATION']

const answer = (finishReason: string | undefined, text = cleaned) => ({
  candidates: [{ content: { parts: [{ text }] }, ...(finishReason ? { finishReason } : {}) }],
  usageMetadata: { promptTokenCount: 120, candidatesTokenCount: 30 },
})

const scratch: string[] = []
afterEach(() => { for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })

// MARK: - Reading the answer

test('Gemini: a candidate that stopped for a block is refused, even when it carries a good-looking text', () => {
  for (const reason of blocks) {
    const parsed = parseAnswer('google', answer(reason))
    assert.equal(parsed?.refused, true, reason)
    assert.equal(parsed?.truncated, false, reason)
  }
})

test('Gemini: the ordinary ends are not refused, and a cut-off answer is still only cut off', () => {
  for (const reason of ['STOP', 'MAX_TOKENS', 'OTHER', 'FINISH_REASON_UNSPECIFIED', undefined]) {
    assert.equal(parseAnswer('google', answer(reason))?.refused, false, String(reason))
  }
  assert.deepEqual([parseAnswer('google', answer('MAX_TOKENS'))?.refused, parseAnswer('google', answer('MAX_TOKENS'))?.truncated], [false, true])
  // A word that only looks like one: the match is exact.
  assert.equal(parseAnswer('google', answer('safety'))?.refused, false)
  assert.equal(parseAnswer('google', answer('NOT_SAFETY'))?.refused, false)
})

test('Gemini: a prompt that was blocked has no candidate and the reason in promptFeedback: refused, not unreadable', () => {
  for (const blockReason of ['SAFETY', 'BLOCKLIST', 'PROHIBITED_CONTENT', 'OTHER', 'IMAGE_SAFETY']) {
    const parsed = parseAnswer('google', { promptFeedback: { blockReason }, usageMetadata: { promptTokenCount: 120 } })
    assert.deepEqual(parsed, { text: '', refused: true, truncated: false, inputTokens: 120, outputTokens: undefined }, blockReason)
  }
  // Whatever else the body holds: a candidate with text, an empty list.
  assert.equal(parseAnswer('google', { promptFeedback: { blockReason: 'SAFETY' }, ...answer('STOP') })?.refused, true)
  assert.equal(parseAnswer('google', { promptFeedback: { blockReason: 'SAFETY', safetyRatings: [] }, candidates: [] })?.refused, true)
})

test('Gemini: a promptFeedback without a block changes nothing, and one that is no object is ignored', () => {
  const ratings = [{ category: 'HARM_CATEGORY_HARASSMENT', probability: 'NEGLIGIBLE' }]
  assert.equal(parseAnswer('google', { promptFeedback: { safetyRatings: ratings }, ...answer('STOP') })?.text, cleaned)
  assert.equal(parseAnswer('google', { promptFeedback: { safetyRatings: ratings }, ...answer('STOP') })?.refused, false)
  assert.equal(parseAnswer('google', { promptFeedback: { blockReason: null }, ...answer('STOP') })?.refused, false)
  assert.equal(parseAnswer('google', { promptFeedback: {}, ...answer('STOP') })?.refused, false)
  assert.equal(parseAnswer('google', { promptFeedback: 'SAFETY', ...answer('STOP') })?.refused, false)
  assert.equal(parseAnswer('google', { promptFeedback: ['SAFETY'], ...answer('STOP') })?.refused, false)
  // Without a block and without candidates it is still no answer at all.
  assert.equal(parseAnswer('google', { promptFeedback: { safetyRatings: ratings } }), undefined)
  assert.equal(parseAnswer('google', {}), undefined)
})

test('the other families do not take Gemini\'s words for a block', () => {
  const foreign = { promptFeedback: { blockReason: 'SAFETY' }, finishReason: 'SAFETY' }
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: cleaned }, ...foreign }], ...foreign })?.refused, false)
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'text', text: cleaned }], ...foreign })?.refused, false)
})

// MARK: - The whole cleanup

const job = (base: string): CleanupJob => ({ provider: 'google', base, model: 'gemini-3.5-flash-lite', key: 'KEY', level: 'light', customPrompt: '', vocabulary: [], text: said })
const reply = (body: unknown) => (async () => new Response(JSON.stringify(body), { status: 200 })) as unknown as typeof fetch

test('runCleanup: every block ends as "answer refused" with nothing to show, the guard never judging the text', async () => {
  // A text the guard would accept, so only the block can be what turns it down.
  const cases: [string, unknown][] = [
    ...blocks.map((reason): [string, unknown] => [`finishReason ${reason}`, answer(reason)]),
    ['blockReason SAFETY with no candidate', { promptFeedback: { blockReason: 'SAFETY' } }],
    ['blockReason BLOCKLIST with no candidate', { promptFeedback: { blockReason: 'BLOCKLIST' }, usageMetadata: { promptTokenCount: 120 } }],
  ]
  for (const [name, body] of cases) {
    const result = await runCleanup(job('http://127.0.0.1:9/v1beta'), reply(body) as never)
    assert.equal(result.kind, 'failed', name)
    assert.equal(result.kind === 'failed' && result.reason, 'answerRefused', name)
    assert.equal(result.kind === 'failed' && result.answer, undefined, name)
  }
  // The same text with a normal end is cleaned: the block is what decided.
  const fine = await runCleanup(job('http://127.0.0.1:9/v1beta'), reply(answer('STOP')) as never)
  assert.equal(fine.kind === 'cleaned' && fine.text, cleaned)
})

test('Cleaner: a blocked Gemini answer pastes the original and says "Answer refused", with the stable code', async () => {
  for (const body of [answer('RECITATION'), answer('SPII'), { promptFeedback: { blockReason: 'PROHIBITED_CONTENT' } }]) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-gemini-block-'))
    scratch.push(dir)
    const cleaner = new Cleaner({
      dir,
      settings: provider => ({ provider: provider ?? 'google', model: 'gemini-synthetic', address: '', level: 'light', customPrompt: '', vocabulary: [] }),
      readAccount: account => (account === 'google' ? 'KEY' : null),
      fetcher: reply(body),
      log() {}, changed() {},
    })
    const run = await cleaner.run(said, { provider: 'google' })
    assert.equal(run.text, said, 'the original is what gets pasted')
    assert.equal(run.outcome, 'Answer refused')
    assert.equal(run.code, 'answer-refused')
    assert.equal(run.answer, undefined)
    assert.equal(run.rejected, false)
  }
})

import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createServer, type IncomingHttpHeaders } from 'node:http'
import type { AddressInfo } from 'node:net'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { guard, systemPrompt, wrap } from '../src/core/cleanup'
import { cleanupProviders } from '../src/core/cleanupProviders'
import {
  buildRequest, cleanupTimeout, maxTokens, openRouterReasoning, parseAnswer, reasonForStatus, runCleanup, thinkingRoom, withoutRefused, type CleanupJob,
} from '../src/core/cleanupRequest'
import { setLanguage } from '../src/core/language'
import { Cleaner, cleanupState, cleanupTryState, parseOpenRouterList, type CleanupSettings } from '../src/main/cleanup'

/*
 * The cleanup requests of every family, against a stand-in server on this
 * computer that checks the address, headers and body. Only OpenRouter was
 * called for real (14.10.2026); nothing here reaches a provider.
 */

setLanguage('en')
const text = 'ähm also der build ist äh gefailed weil the tests are flaky'
const job = (change: Partial<CleanupJob> = {}): CleanupJob => ({
  provider: 'openrouter', base: cleanupProviders.openrouter.address!, model: 'google/gemini-3.5-flash-lite', key: 'KEY', level: 'light', customPrompt: '',
  vocabulary: ['ACON'], text, ...change,
})

// MARK: - Building

test('OpenAI-compatible: chat completions, Bearer key, temperature 0, max_tokens, the turns, and OpenRouter\'s extras', () => {
  const request = buildRequest(job())
  assert.equal(request.url, 'https://openrouter.ai/api/v1/chat/completions')
  assert.deepEqual(request.headers, { 'Content-Type': 'application/json', Authorization: 'Bearer KEY' })
  const body = request.body as { messages: { role: string; content: string }[] } & Record<string, unknown>
  assert.equal(body.model, 'google/gemini-3.5-flash-lite')
  assert.equal(body.temperature, 0)
  // Without a live list this model thinks at "minimal": its answer gets room for that.
  assert.equal(body.max_tokens, maxTokens(text, 2000))
  assert.equal(body.stream, false)
  assert.deepEqual(body.usage, { include: true })
  assert.deepEqual(body.provider, { sort: 'latency' })
  // Without a live list, what the rule gave for the catalog.
  assert.deepEqual(body.reasoning, { effort: 'minimal' })
  assert.equal(body.messages.length, 8)
  assert.deepEqual(body.messages[0], { role: 'system', content: systemPrompt('light', ['ACON']) })
  assert.deepEqual(body.messages[7], { role: 'user', content: wrap(text) })
})

test('room for the answer: twice the dictation and 200, and 2000 more where the model may think, at most 8000', () => {
  assert.equal(maxTokens('x'.repeat(450)), 2 * 100 + 200)
  assert.equal(maxTokens('x'.repeat(450), 2000), 2 * 100 + 200 + 2000)
  assert.equal(maxTokens('x'.repeat(100_000)), 8000)
  assert.equal(maxTokens('x'.repeat(100_000), 2000), 8000)
  // Counted in Unicode scalars: 450 emoji are 450 characters, not 900 UTF-16 units.
  assert.equal(maxTokens('😀'.repeat(450)), 2 * 100 + 200)
})

test('room for thinking: 2000 more tokens wherever the request does not switch thinking fully off', () => {
  const room = (change: Partial<CleanupJob>) => {
    const request = buildRequest(job(change))
    const body = request.body as Record<string, unknown> & { generationConfig?: { maxOutputTokens: number } }
    const limit = (body.max_tokens ?? body.max_completion_tokens ?? body.generationConfig?.maxOutputTokens) as number
    return limit - maxTokens(text)
  }
  const at = (provider: CleanupJob['provider'], model: string, change: Partial<CleanupJob> = {}) => room({ provider, base: cleanupProviders[provider].address ?? 'http://127.0.0.1:5000/v1', model, ...change })
  // Off: no room. OpenRouter's "enabled: false" and effort "none", reasoning_effort "none", Anthropic's and DeepSeek's disabled, Gemini's budget 0.
  assert.equal(room({ reasoning: null }), 0, 'OpenRouter: a model the live list lacks is asked to stop thinking')
  assert.equal(room({ reasoning: { supported_efforts: ['none', 'low'] } }), 0, 'OpenRouter: effort none')
  assert.equal(room({ model: 'qwen/qwen3.8-27b' }), 0, 'OpenRouter: the catalog says {enabled: false}')
  assert.equal(at('openai', 'gpt-6-luna'), 0)
  assert.equal(at('mistral', 'mistral-small-latest'), 0)
  assert.equal(at('groq', 'qwen/qwen3.8-27b'), 0)
  assert.equal(at('anthropic', 'claude-haiku-5-5'), 0)
  assert.equal(at('anthropic', 'claude-haiku-9-typed'), 0, 'a typed Claude id gets Haiku\'s extras')
  assert.equal(at('deepseek', 'deepseek-flash'), 0)
  assert.equal(at('google', 'gemini-2.5-pro'), 0, 'a typed 2.5 gets thinkingBudget 0')
  assert.equal(at('ollama', 'qwen3.8:8b'), 0)
  // On: room. OpenRouter with any other effort, "low" and "minimal", Anthropic's output_config, Gemini's thinkingLevel, ids nothing is known about.
  assert.equal(room({ reasoning: { supported_efforts: ['low', 'high'], mandatory: true } }), 2000, 'OpenRouter: effort low')
  assert.equal(room({}), 2000, 'OpenRouter, no list: the catalog says minimal')
  assert.equal(room({ model: 'x-ai/grok-4.7' }), 2000, 'OpenRouter, no list: the catalog says low')
  assert.equal(at('openai', 'gpt-6.1-sol'), 2000, 'reasoning_effort low, it cannot stop')
  assert.equal(at('groq', 'openai/gpt-oss-120b'), 2000)
  assert.equal(at('cerebras', 'gpt-oss-120b'), 2000)
  assert.equal(at('xai', 'grok-4.7'), 2000)
  assert.equal(at('anthropic', 'claude-sonnet-5-5'), 2000, 'output_config')
  assert.equal(at('google', 'gemini-3.5-flash-lite'), 2000, 'thinkingLevel')
  assert.equal(at('google', 'gemini-5-ultra'), 2000, 'a typed id gets thinkingLevel minimal')
  assert.equal(at('azure', 'my-deployment'), 2000, 'a deployment nothing is known about')
  assert.equal(at('lmstudio', 'qwen-local'), 2000)
  assert.equal(at('custom', 'm'), 2000)
  // The rule on its own: a body with none of the markers thinks.
  assert.equal(thinkingRoom({}), 2000)
  assert.equal(thinkingRoom({ reasoning_effort: 'none' }), 0)
  assert.equal(thinkingRoom({ reasoning_effort: 'low' }), 2000)
  assert.equal(thinkingRoom({ thinking: { type: 'disabled' } }), 0)
  assert.equal(thinkingRoom({ thinkingConfig: { thinkingBudget: 0 } }), 0)
  assert.equal(thinkingRoom({ thinkingConfig: { thinkingLevel: 'low' } }), 2000)
  assert.equal(thinkingRoom({ reasoning: { enabled: false } }), 0)
  assert.equal(thinkingRoom({ reasoning: { effort: 'minimal' } }), 2000)
})

test('room for thinking is no more than 8000 in all, and costs nothing: the guard still throws out a runaway answer', () => {
  const long = 'x'.repeat(30_000)
  const body = buildRequest(job({ text: long })).body
  assert.equal(body.max_tokens, 8000)
  const runaway = 'Sure! Here is a very long reply that has nothing to do with what was said, and goes on and on about the weather and the news of the day.'
  assert.equal(guard('ähm also der build ist äh gefailed weil the tests are flaky', runaway, 'light'), false)
})

test('OpenRouter\'s reasoning rule, from the live list', () => {
  assert.deepEqual(openRouterReasoning({ supported_efforts: ['none', 'low'], mandatory: true }), { effort: 'none' })
  assert.deepEqual(openRouterReasoning({ supported_efforts: ['low', 'high'], mandatory: false }), { enabled: false })
  assert.deepEqual(openRouterReasoning({ supported_efforts: ['high', 'low', 'minimal'], mandatory: true }), { effort: 'minimal' })
  assert.deepEqual(openRouterReasoning({ supported_efforts: ['xhigh', 'medium'], mandatory: true }), { effort: 'medium' })
  assert.deepEqual(openRouterReasoning(null), { enabled: false }, 'a model the list does not have')
  assert.deepEqual(openRouterReasoning(undefined, cleanupProviders.openrouter.models.find(model => model.id === 'z-ai/glm-5.3')), { effort: 'low' }, 'no list: the catalog')
  assert.deepEqual(buildRequest(job({ model: 'some/new-model', reasoning: null })).body.reasoning, { enabled: false })
  assert.deepEqual(buildRequest(job({ reasoning: { supported_efforts: ['none'] } })).body.reasoning, { effort: 'none' })
})

test('OpenRouter\'s thinking: a live entry without reasoning facts is "no metadata", the catalog only counts when there is no list at all', () => {
  const reasoningOf = (reasoning: CleanupJob['reasoning'], model = 'z-ai/glm-5.3') => buildRequest(job({ model, reasoning })).body.reasoning
  // A listed model with nothing about reasoning, or an empty object: off, not the catalog's "low".
  assert.deepEqual(reasoningOf(null), { enabled: false })
  assert.deepEqual(reasoningOf({}), { enabled: false })
  assert.deepEqual(reasoningOf({ supported_efforts: [] }), { enabled: false })
  // No list at all: the catalog's value.
  assert.deepEqual(reasoningOf(undefined), { effort: 'low' })
  assert.deepEqual(reasoningOf(undefined, 'google/gemini-3.5-flash-lite'), { effort: 'minimal' })
  // Mandatory with no effort known: the least there is.
  assert.deepEqual(reasoningOf({ mandatory: true }), { effort: 'low' })
  assert.deepEqual(reasoningOf({ supported_efforts: [], mandatory: true }), { effort: 'low' })
  assert.deepEqual(reasoningOf({ supported_efforts: ['high', 'xhigh'], mandatory: true }), { effort: 'high' })
  assert.deepEqual(reasoningOf({ supported_efforts: ['medium'], mandatory: false }), { enabled: false })
  assert.deepEqual(reasoningOf({ supported_efforts: ['none', 'low'], mandatory: true }), { effort: 'none' })
})

test('a request sent again gets its limit again: the switch that kept the model from thinking may be the field that went', () => {
  const ollama = buildRequest(job({ provider: 'ollama', base: 'http://localhost:11434/v1', model: 'qwen3.8:8b', key: null }))
  assert.equal(ollama.body.max_tokens, maxTokens(text))
  assert.equal(withoutRefused(ollama, 'Unrecognized request argument supplied: reasoning_effort', new Set(), text)!.body.max_tokens, maxTokens(text, 2000))
  // OpenRouter\'s "off" turned into "low" thinks.
  const off = buildRequest(job({ model: 'z-ai/glm-5.3', reasoning: null }))
  assert.equal(off.body.max_tokens, maxTokens(text))
  assert.equal(withoutRefused(off, 'reasoning is mandatory', new Set(), text)!.body.max_tokens, maxTokens(text, 2000))
  // Gemini without its thinkingConfig; the field is maxOutputTokens there.
  const gemini = buildRequest(job({ provider: 'google', base: cleanupProviders.google.address!, model: 'gemini-2.5-pro' }))
  assert.equal((gemini.body.generationConfig as { maxOutputTokens: number }).maxOutputTokens, maxTokens(text))
  assert.equal((withoutRefused(gemini, 'Unknown name "thinkingBudget"', new Set(), text)!.body.generationConfig as { maxOutputTokens: number }).maxOutputTokens, maxTokens(text, 2000))
  // OpenAI and Azure keep their own name; Anthropic\'s dropped thinking field.
  const luna = buildRequest(job({ provider: 'openai', base: cleanupProviders.openai.address!, model: 'gpt-6-luna' }))
  const next = withoutRefused(luna, 'Unrecognized request argument: reasoning_effort', new Set(), text)!
  assert.equal(next.body.max_completion_tokens, maxTokens(text, 2000))
  assert.equal('max_tokens' in next.body, false)
  const claude = buildRequest(job({ provider: 'anthropic', base: cleanupProviders.anthropic.address!, model: 'claude-haiku-5-5' }))
  assert.equal(withoutRefused(claude, 'thinking: extra inputs are not permitted', new Set(), text)!.body.max_tokens, maxTokens(text, 2000))
  // The request it came from is untouched, and a caller that gives no text keeps the limit.
  assert.equal(luna.body.max_completion_tokens, maxTokens(text))
  assert.equal(withoutRefused(luna, 'reasoning_effort', new Set())!.body.max_completion_tokens, maxTokens(text))
})

test('a 400 that names reasoning: "off" becomes "low" once, any other value goes, once', () => {
  const said = 'Reasoning is mandatory for this endpoint and cannot be disabled'
  const bodyOf = (reasoning: CleanupJob['reasoning']) => buildRequest(job({ model: 'z-ai/glm-5.3', reasoning }))
  const off = bodyOf(null)
  assert.deepEqual(off.body.reasoning, { enabled: false })
  const dropped = new Set<string>()
  const low = withoutRefused(off, said, dropped)!
  assert.deepEqual(low.body.reasoning, { effort: 'low' })
  assert.equal(withoutRefused(low, said, dropped), null, 'once')
  // Any other reasoning value: the same request without it.
  for (const facts of [{ supported_efforts: ['none'] }, { supported_efforts: ['minimal', 'low'], mandatory: true }, { mandatory: true }]) {
    const sent = bodyOf(facts)
    assert.ok('reasoning' in sent.body)
    const set = new Set<string>()
    const next = withoutRefused(sent, 'Unsupported parameter: reasoning', set)!
    assert.equal('reasoning' in next.body, false, JSON.stringify(sent.body.reasoning))
    assert.equal(next.body.usage !== undefined && next.body.temperature === 0, true, 'the rest stays')
    assert.equal(withoutRefused(next, 'Unsupported parameter: reasoning', set), null, 'once')
  }
  // A 400 that does not name it changes nothing.
  assert.equal(withoutRefused(off, 'model is overloaded', new Set()), null)
  // The request itself is not touched.
  assert.deepEqual(off.body.reasoning, { enabled: false })
})

test('stand-in: OpenRouter\'s effort that a 400 refuses is sent once more without reasoning', async () => {
  const server = await standIn((_seen, count) => count === 1
    ? { status: 400, body: { error: { message: 'reasoning.effort is not supported by this model' } } }
    : { status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') })
  try {
    // OpenRouter's address is fixed, so the stand-in gets the requests through the fetch.
    const sent: Record<string, unknown>[] = []
    const redirect = ((_url: string, init: { body: string }) => {
      sent.push(JSON.parse(init.body))
      return fetch(`${server.origin}/v1/chat/completions`, init as never)
    }) as never
    const result = await runCleanup(job({ model: 'z-ai/glm-5.3', reasoning: { supported_efforts: ['low'], mandatory: true } }), redirect)
    assert.equal(result.kind, 'cleaned')
    assert.equal(sent.length, 2)
    assert.deepEqual(sent[0].reasoning, { effort: 'low' })
    assert.equal('reasoning' in sent[1], false)
  } finally { await server.close() }
})

test('the catalog\'s fallbacks are what the rule gave on 14.10.', () => {
  const fallback = Object.fromEntries(cleanupProviders.openrouter.models.map(model => [model.id.split('/')[1], JSON.stringify(model.reasoning)]))
  const off = JSON.stringify({ enabled: false }), none = JSON.stringify({ effort: 'none' }), low = JSON.stringify({ effort: 'low' })
  for (const id of ['qwen3.8-27b', 'deepseek-v4.1-flash', 'claude-haiku-5.5', 'minimax-m3', 'kimi-k3', 'deepseek-v4-pro-0813']) assert.equal(fallback[id], off, id)
  for (const id of ['gpt-6-luna', 'gpt-6-sol', 'mistral-large-4-0']) assert.equal(fallback[id], none, id)
  assert.equal(fallback['gemini-3.5-flash-lite'], JSON.stringify({ effort: 'minimal' }))
  for (const id of ['glm-5.3', 'gemini-3.8-flash', 'claude-sonnet-5.5', 'gpt-6.1-sol', 'gemini-4-argon', 'claude-opus-5.5', 'grok-4.7']) assert.equal(fallback[id], low, id)
})

test('OpenAI and Azure: max_completion_tokens, no temperature for GPT-6, Azure\'s key in api-key', () => {
  const openai = buildRequest(job({ provider: 'openai', base: 'https://api.openai.com/v1', model: 'gpt-6-luna' }))
  assert.equal(openai.url, 'https://api.openai.com/v1/chat/completions')
  // reasoning_effort "none": thinking is off, no room for it.
  assert.equal(openai.body.max_completion_tokens, maxTokens(text))
  assert.equal('max_tokens' in openai.body, false)
  assert.equal('temperature' in openai.body, false)
  assert.equal(openai.body.reasoning_effort, 'none')
  assert.equal(buildRequest(job({ provider: 'openai', base: 'https://api.openai.com/v1', model: 'gpt-6.1-sol' })).body.reasoning_effort, 'low')
  const azure = buildRequest(job({ provider: 'azure', base: 'https://mine.openai.azure.com/openai/v1', model: 'my-luna' }))
  assert.equal(azure.url, 'https://mine.openai.azure.com/openai/v1/chat/completions')
  assert.deepEqual(azure.headers, { 'Content-Type': 'application/json', 'api-key': 'KEY' })
  assert.equal(azure.body.model, 'my-luna')
  // A deployment nothing is known about may think.
  assert.equal(azure.body.max_completion_tokens, maxTokens(text, 2000))
  assert.equal('temperature' in azure.body, false)
})

test('the others: their extras, and no Authorization header without a key', () => {
  const groq = buildRequest(job({ provider: 'groq', base: cleanupProviders.groq.address!, model: 'openai/gpt-oss-120b' })).body
  assert.equal(groq.reasoning_effort, 'low')
  assert.equal(groq.include_reasoning, false)
  assert.equal(groq.temperature, 0)
  assert.equal(groq.max_tokens, maxTokens(text, 2000), 'gpt-oss thinks at "low"')
  const cerebras = buildRequest(job({ provider: 'cerebras', base: cleanupProviders.cerebras.address!, model: 'gpt-oss-120b' })).body
  assert.equal(cerebras.reasoning_format, 'hidden')
  const deepseek = buildRequest(job({ provider: 'deepseek', base: cleanupProviders.deepseek.address!, model: 'deepseek-flash' }))
  assert.equal(deepseek.url, 'https://api.deepseek.com/chat/completions')
  assert.deepEqual(deepseek.body.thinking, { type: 'disabled' })
  assert.equal('reasoning_effort' in deepseek.body, false)
  assert.equal(buildRequest(job({ provider: 'mistral', base: cleanupProviders.mistral.address!, model: 'mistral-small-latest' })).body.reasoning_effort, 'none')
  assert.equal(buildRequest(job({ provider: 'xai', base: cleanupProviders.xai.address!, model: 'grok-4.7' })).body.reasoning_effort, 'low')
  const ollama = buildRequest(job({ provider: 'ollama', base: 'http://localhost:11434/v1', model: 'qwen3.8:8b', key: null }))
  assert.deepEqual(ollama.headers, { 'Content-Type': 'application/json' })
  assert.equal(ollama.body.reasoning_effort, 'none')
  const lmstudio = buildRequest(job({ provider: 'lmstudio', base: 'http://localhost:1234/v1', model: 'm', key: null })).body
  assert.equal('reasoning_effort' in lmstudio, false)
  const custom = buildRequest(job({ provider: 'custom', base: 'http://127.0.0.1:5000/v1', model: 'm', key: null }))
  assert.equal(custom.headers.Authorization, undefined)
  assert.equal(buildRequest(job({ provider: 'custom', base: 'http://127.0.0.1:5000/v1', model: 'm', key: 'K' })).headers.Authorization, 'Bearer K')
})

test('Anthropic: messages, x-api-key and the version, the system prompt apart, thinking off, no sampling parameters', () => {
  const request = buildRequest(job({ provider: 'anthropic', base: cleanupProviders.anthropic.address!, model: 'claude-haiku-5-5' }))
  assert.equal(request.url, 'https://api.anthropic.com/v1/messages')
  assert.deepEqual(request.headers, { 'x-api-key': 'KEY', 'anthropic-version': '2023-06-01', 'content-type': 'application/json' })
  const body = request.body as { messages: { role: string }[] } & Record<string, unknown>
  assert.equal(body.system, systemPrompt('light', ['ACON']))
  assert.equal(body.max_tokens, maxTokens(text), 'thinking disabled: no room for it')
  assert.deepEqual(body.thinking, { type: 'disabled' })
  for (const field of ['temperature', 'top_p', 'top_k', 'stream']) assert.equal(field in body, false, field)
  assert.deepEqual(body.messages.map(message => message.role), ['user', 'assistant', 'user', 'assistant', 'user', 'assistant', 'user'])
  assert.deepEqual(buildRequest(job({ provider: 'anthropic', base: cleanupProviders.anthropic.address!, model: 'claude-sonnet-5-5' })).body.output_config, { effort: 'low' })
  // A typed id gets Haiku's extras.
  assert.deepEqual(buildRequest(job({ provider: 'anthropic', base: cleanupProviders.anthropic.address!, model: 'claude-haiku-6' })).body.thinking, { type: 'disabled' })
})

test('Gemini: generateContent, x-goog-api-key, systemInstruction, model turns, and the thinking per model', () => {
  const request = buildRequest(job({ provider: 'google', base: cleanupProviders.google.address!, model: 'gemini-3.5-flash-lite' }))
  assert.equal(request.url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent')
  assert.deepEqual(request.headers, { 'x-goog-api-key': 'KEY', 'Content-Type': 'application/json' })
  const body = request.body as { systemInstruction: unknown; contents: { role: string; parts: { text: string }[] }[]; generationConfig: Record<string, unknown> }
  assert.deepEqual(body.systemInstruction, { parts: [{ text: systemPrompt('light', ['ACON']) }] })
  assert.deepEqual(body.contents.map(turn => turn.role), ['user', 'model', 'user', 'model', 'user', 'model', 'user'])
  assert.equal(body.contents[6].parts[0].text, wrap(text))
  assert.deepEqual(body.generationConfig, { temperature: 0, maxOutputTokens: maxTokens(text, 2000), thinkingConfig: { thinkingLevel: 'minimal' } })
  const config = (model: string) => (buildRequest(job({ provider: 'google', base: cleanupProviders.google.address!, model })).body.generationConfig as Record<string, unknown>).thinkingConfig
  assert.deepEqual(config('gemini-4-argon'), { thinkingLevel: 'low' })
  assert.deepEqual(config('gemini-2.5-pro'), { thinkingBudget: 0 }, 'a typed 2.5')
  assert.deepEqual(config('gemini-5-ultra'), { thinkingLevel: 'minimal' }, 'any other typed id')
})

test('a 400 naming a field sends the request again without it; OpenRouter\'s "off" becomes "low"', () => {
  const groq = buildRequest(job({ provider: 'groq', base: cleanupProviders.groq.address!, model: 'openai/gpt-oss-120b' }))
  const dropped = new Set<string>()
  const next = withoutRefused(groq, 'property \'include_reasoning\' is unsupported', dropped)!
  assert.equal('include_reasoning' in next.body, false)
  assert.equal(next.body.reasoning_effort, 'low')
  assert.equal(withoutRefused(next, 'property \'include_reasoning\' is unsupported', dropped), null, 'once per field')
  assert.equal(withoutRefused(groq, 'model overloaded', new Set()), null)
  const unknown = buildRequest(job({ model: 'some/new-model', reasoning: null }))
  assert.deepEqual(withoutRefused(unknown, 'Reasoning is mandatory for this endpoint', new Set())!.body.reasoning, { effort: 'low' })
  const gemini = buildRequest(job({ provider: 'google', base: cleanupProviders.google.address!, model: 'gemini-3.5-flash-lite' }))
  const plain = withoutRefused(gemini, 'Invalid JSON payload received. Unknown name "thinkingLevel"', new Set())!
  assert.deepEqual(plain.body.generationConfig, { temperature: 0, maxOutputTokens: maxTokens(text, 2000) })
})

// MARK: - Reading

test('answers: OpenAI\'s string and parts, its refusal, OpenRouter\'s cost, Anthropic\'s text items, Gemini without thought parts', () => {
  assert.deepEqual(parseAnswer('openrouter', { choices: [{ message: { content: 'Hallo.' } }], usage: { prompt_tokens: 500, completion_tokens: 20, cost: 0.00012 } }),
    { text: 'Hallo.', refused: false, truncated: false, inputTokens: 500, outputTokens: 20, dollars: 0.00012 })
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: [{ type: 'text', text: 'Hal' }, { type: 'text', text: 'lo.' }] } }] })!.text, 'Hallo.')
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: null, refusal: 'I can\'t help with that.' } }] })!.refused, true)
  assert.equal(parseAnswer('openai', { choices: [{ message: { content: 'x', refusal: null } }] })!.refused, false)
  assert.deepEqual(parseAnswer('anthropic', { content: [{ type: 'thinking', thinking: '…' }, { type: 'text', text: 'Hallo ' }, { type: 'text', text: 'Welt.' }], stop_reason: 'end_turn', usage: { input_tokens: 800, output_tokens: 30 } }),
    { text: 'Hallo Welt.', refused: false, truncated: false, inputTokens: 800, outputTokens: 30 })
  assert.equal(parseAnswer('anthropic', { content: [], stop_reason: 'refusal' })!.refused, true)
  assert.deepEqual(parseAnswer('google', { candidates: [{ content: { parts: [{ text: 'thinking about it', thought: true }, { text: 'Hallo Welt.' }] } }], usageMetadata: { promptTokenCount: 450, candidatesTokenCount: 12 } }),
    { text: 'Hallo Welt.', refused: false, truncated: false, inputTokens: 450, outputTokens: 12 })
  assert.equal(parseAnswer('openai', { error: 'x' }), undefined)
  assert.equal(parseAnswer('anthropic', { choices: [] }), undefined)
})

test('answers that hit max_tokens are marked cut off, in each family\'s words', () => {
  assert.equal(parseAnswer('openrouter', { choices: [{ message: { content: 'Hal' }, finish_reason: 'length' }] })!.truncated, true)
  assert.equal(parseAnswer('openrouter', { choices: [{ message: { content: 'Hallo.' }, finish_reason: 'stop' }] })!.truncated, false)
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'text', text: 'Hal' }], stop_reason: 'max_tokens' })!.truncated, true)
  assert.equal(parseAnswer('anthropic', { content: [{ type: 'text', text: 'Hallo.' }], stop_reason: 'end_turn' })!.truncated, false)
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ text: 'Hal' }] }, finishReason: 'MAX_TOKENS' }] })!.truncated, true)
  assert.equal(parseAnswer('google', { candidates: [{ content: { parts: [{ text: 'Hallo.' }] }, finishReason: 'STOP' }] })!.truncated, false)
})

test('statuses become the short reasons', () => {
  assert.deepEqual([401, 403, 402, 404, 429, 400, 422, 500, 503].map(status => reasonForStatus(status)),
    ['keyRejected', 'keyRejected', 'noCredit', 'modelNotFound', 'tooManyRequests', 'refused', 'refused', 'providerError', 'providerError'])
  assert.equal(reasonForStatus(429, '{"error":{"code":"insufficient_quota"}}'), 'noCredit')
  // Google's answer to a key it does not know.
  const wrongGoogleKey = '{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}'
  assert.equal(reasonForStatus(400, wrongGoogleKey), 'keyRejected')
  assert.equal(reasonForStatus(400, '{"error":{"message":"Invalid value at contents[0]"}}'), 'refused')
})

test('timeouts: 6 s and the answer at 40 tokens a second in the cloud, at most 30; 20 s and 15 a second on this computer, at most 60', () => {
  const short = 'x'.repeat(450) // 100 tokens, 95 out at "light"
  const model = 'google/gemini-3.5-flash-lite'
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model, text: short, level: 'light' }), 6 + 95 / 40)
  assert.equal(cleanupTimeout({ provider: 'ollama', base: 'http://localhost:11434/v1', model: 'qwen3.8:8b', text: short, level: 'light' }), 20 + 95 / 15)
  assert.equal(cleanupTimeout({ provider: 'custom', base: 'http://127.0.0.1:5000/v1', model: 'm', text: short, level: 'polished' }), 20 + 100 / 15)
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model, text: 'x'.repeat(100_000), level: 'light' }), 30)
  assert.equal(cleanupTimeout({ provider: 'lmstudio', base: 'http://localhost:1234/v1', model: 'm', text: 'x'.repeat(100_000), level: 'light' }), 60)
})

test('timeouts: never less than three times the seconds the model took, still at most 30 s in the cloud and 60 s here', () => {
  const short = 'x'.repeat(450)
  // Grok 4.7 took 4.6 s (6.5 s at the 90th percentile): the plain rule gives 8.4 s, three times its time 13.8 s.
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model: 'x-ai/grok-4.7', text: short, level: 'light' }), 3 * 4.6)
  assert.equal(cleanupTimeout({ provider: 'xai', base: 'https://api.x.ai/v1', model: 'grok-4.7', text: short, level: 'light' }), 3 * 4.6)
  // A fast model keeps the plain rule; a model typed by hand has no catalog time and keeps it too.
  assert.equal(cleanupTimeout({ provider: 'cerebras', base: 'https://api.cerebras.ai/v1', model: 'qwen-3.8-27b', text: short, level: 'light' }), 6 + 95 / 40)
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model: 'new/model', text: short, level: 'light' }), 6 + 95 / 40)
  // An Azure deployment counts as the 1.5 s of the catalog's typed row.
  assert.equal(cleanupTimeout({ provider: 'azure', base: 'https://mine.openai.azure.com/openai/v1', model: 'my-luna', text: short, level: 'light' }), 6 + 95 / 40)
  // The caps stay: a slow model on a long dictation is cut at 30 s, a local one at 60 s.
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model: 'x-ai/grok-4.7', text: 'x'.repeat(100_000), level: 'light' }), 30)
  // The characters are Unicode scalars: 450 emoji are as long as 450 letters.
  assert.equal(cleanupTimeout({ provider: 'openrouter', base: 'https://openrouter.ai/api/v1', model: 'google/gemini-3.5-flash-lite', text: '😀'.repeat(450), level: 'light' }), 6 + 95 / 40)
})

// MARK: - Against a stand-in server

interface Seen { method?: string; url?: string; headers: IncomingHttpHeaders; body: Record<string, unknown> }

/** A server on 127.0.0.1 that records every request and answers with `reply` (or not at all). */
async function standIn(reply: (seen: Seen, count: number) => { status: number; body: unknown; delay?: number }) {
  const seen: Seen[] = []
  const server = createServer((request, response) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(chunk))
    request.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8')
      seen.push({ method: request.method, url: request.url, headers: request.headers, body: raw ? JSON.parse(raw) : {} })
      const answer = reply(seen[seen.length - 1], seen.length)
      setTimeout(() => {
        response.writeHead(answer.status, { 'content-type': 'application/json' })
        response.end(typeof answer.body === 'string' ? answer.body : JSON.stringify(answer.body))
      }, answer.delay ?? 0)
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  return { origin, seen, close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections() }) }
}

const chat = (content: string, extra: Record<string, unknown> = {}) => ({ choices: [{ message: { role: 'assistant', content } }], ...extra })

test('stand-in: a cleaned answer comes back cleaned, with its time and OpenRouter-style cost', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.', { usage: { prompt_tokens: 500, completion_tokens: 20, cost: 0.0002 } }) }))
  try {
    const result = await runCleanup(job({ provider: 'custom', base: `${server.origin}/v1`, model: 'stand-in', key: null }), fetch as never)
    assert.equal(result.kind, 'cleaned')
    if (result.kind !== 'cleaned') return
    assert.equal(result.text, 'Also, der Build ist gefailed, weil the tests are flaky.')
    assert.equal(result.changed, true)
    assert.equal(result.dollars, 0.0002)
    assert.ok(result.seconds >= 0)
    assert.equal(server.seen[0].method, 'POST')
    assert.equal(server.seen[0].url, '/v1/chat/completions')
    assert.equal(server.seen[0].headers.authorization, undefined, 'no key, no header')
    assert.equal((server.seen[0].body.messages as unknown[]).length, 8)
  } finally { await server.close() }
})

test('stand-in: an answer that is not the dictation is rejected by the guard, and an empty one is said as such', async () => {
  let answer = 'Sure! Here is a joke: why did the build fail? Because the tests were flaky, of course, and nobody fixed them.'
  const server = await standIn(() => ({ status: 200, body: chat(answer) }))
  try {
    const rejected = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null }), fetch as never)
    assert.equal(rejected.kind === 'failed' && rejected.reason, 'rejected')
    assert.equal(rejected.kind === 'failed' && rejected.answer, answer, 'Ausprobieren shows what came back')
    answer = '<think>nothing to say</think>'
    const empty = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null }), fetch as never)
    assert.equal(empty.kind === 'failed' && empty.reason, 'empty')
  } finally { await server.close() }
})

test('stand-in: statuses, a refusal, a server that does not answer in time and one that is not there', async () => {
  for (const [status, reason] of [[401, 'keyRejected'], [402, 'noCredit'], [404, 'modelNotFound'], [429, 'tooManyRequests'], [500, 'providerError'], [418, 'refused']] as const) {
    const server = await standIn(() => ({ status, body: { error: { message: 'nope' } } }))
    try {
      const result = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: 'SECRET' }), fetch as never)
      assert.equal(result.kind === 'failed' && result.reason, reason, String(status))
      assert.equal(result.kind === 'failed' && result.status, status)
      assert.equal(server.seen[0].headers.authorization, 'Bearer SECRET')
    } finally { await server.close() }
  }
  const refusing = await standIn(() => ({ status: 200, body: { choices: [{ message: { content: null, refusal: 'No.' } }] } }))
  try {
    const result = await runCleanup(job({ provider: 'custom', base: refusing.origin, model: 'm', key: null }), fetch as never)
    assert.equal(result.kind === 'failed' && result.reason, 'answerRefused')
  } finally { await refusing.close() }
  const slow = await standIn(() => ({ status: 200, body: chat('too late'), delay: 1500 }))
  try {
    const result = await runCleanup(job({ provider: 'custom', base: slow.origin, model: 'm', key: null }), fetch as never, { timeout: 0.2 })
    assert.equal(result.kind === 'failed' && result.reason, 'tooSlow')
  } finally { await slow.close() }
  // A port nothing listens on.
  const gone = await standIn(() => ({ status: 200, body: {} }))
  await gone.close()
  const result = await runCleanup(job({ provider: 'custom', base: gone.origin, model: 'm', key: null }), fetch as never)
  assert.equal(result.kind === 'failed' && result.reason, 'unreachable')
})

test('stand-in: a 400 that names an extra field is answered by the same request without it', async () => {
  const server = await standIn((seen, count) => count === 1
    ? { status: 400, body: { error: { message: 'Unrecognized request argument supplied: reasoning_effort' } } }
    : { status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') })
  try {
    const result = await runCleanup(job({ provider: 'ollama', base: server.origin, model: 'qwen3.8:8b', key: null }), fetch as never)
    assert.equal(result.kind, 'cleaned')
    assert.equal(server.seen.length, 2)
    assert.equal(server.seen[0].body.reasoning_effort, 'none')
    assert.equal('reasoning_effort' in server.seen[1].body, false)
    // Thinking was switched off by the field that went: the second request has room for it.
    assert.equal(server.seen[0].body.max_tokens, maxTokens(text))
    assert.equal(server.seen[1].body.max_tokens, maxTokens(text, 2000))
  } finally { await server.close() }
})

test('stand-in: Anthropic and Gemini answers through the real request code', async () => {
  const anthropic = await standIn(() => ({ status: 200, body: { content: [{ type: 'text', text: 'Also, der Build ist gefailed, weil the tests are flaky.' }], stop_reason: 'end_turn', usage: { input_tokens: 900, output_tokens: 25 } } }))
  try {
    const result = await runCleanup(job({ provider: 'anthropic', base: anthropic.origin, model: 'claude-haiku-5-5' }), fetch as never)
    assert.equal(result.kind, 'cleaned')
    assert.equal(anthropic.seen[0].url, '/messages')
    assert.equal(anthropic.seen[0].headers['x-api-key'], 'KEY')
    assert.equal(anthropic.seen[0].headers['anthropic-version'], '2023-06-01')
  } finally { await anthropic.close() }
  const gemini = await standIn(() => ({ status: 200, body: { candidates: [{ content: { parts: [{ text: 'hmm', thought: true }, { text: 'Also, der Build ist gefailed, weil the tests are flaky.' }] } }] } }))
  try {
    const result = await runCleanup(job({ provider: 'google', base: gemini.origin, model: 'gemini-3.5-flash-lite' }), fetch as never)
    assert.equal(result.kind === 'cleaned' && result.text, 'Also, der Build ist gefailed, weil the tests are flaky.')
    assert.equal(gemini.seen[0].url, '/models/gemini-3.5-flash-lite:generateContent')
    assert.equal(gemini.seen[0].headers['x-goog-api-key'], 'KEY')
  } finally { await gemini.close() }
})

test('stand-in: an answer cut off by max_tokens is never pasted, in all three families', async () => {
  const long = 'ähm also ich wollte fragen ob wir das meeting am montag nein am dienstag machen können und kannst du mir sagen wer noch kommt und bring bitte die unterlagen für das projekt mit damit wir alles besprechen können'
  // The first two thirds only: the guard alone lets this through at "Leicht".
  const cut = 'Also, ich wollte fragen, ob wir das Meeting am Dienstag machen können, und kannst du mir sagen, wer noch kommt'
  assert.equal(guard(long, cut, 'light'), true, 'the guard cannot tell')
  const families = [
    ['custom', { choices: [{ message: { content: cut }, finish_reason: 'length' }] }],
    ['anthropic', { content: [{ type: 'text', text: cut }], stop_reason: 'max_tokens' }],
    ['google', { candidates: [{ content: { parts: [{ text: cut }] }, finishReason: 'MAX_TOKENS' }] }],
  ] as const
  for (const [provider, body] of families) {
    const server = await standIn(() => ({ status: 200, body }))
    try {
      const result = await runCleanup(job({ provider, base: server.origin, model: provider === 'google' ? 'gemini-3.5-flash-lite' : 'm', text: long }), fetch as never)
      assert.equal(result.kind === 'failed' && result.reason, 'cutOff', provider)
      assert.equal(result.kind === 'failed' && result.answer, cut, 'Ausprobieren shows what came back')
    } finally { await server.close() }
  }
})

test('stand-in: Google\'s 400 for a wrong key reads "Key rejected", and nothing is sent again', async () => {
  const server = await standIn(() => ({ status: 400, body: { error: { code: 400, message: 'API key not valid. Please pass a valid API key.', status: 'INVALID_ARGUMENT', details: [{ reason: 'API_KEY_INVALID' }] } } }))
  try {
    const result = await runCleanup(job({ provider: 'google', base: server.origin, model: 'gemini-3.5-flash-lite' }), fetch as never)
    assert.equal(result.kind === 'failed' && result.reason, 'keyRejected')
    assert.equal(server.seen.length, 1)
  } finally { await server.close() }
})

test('a cleanup cancelled before it starts sends nothing', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') }))
  try {
    const cancelled = new AbortController()
    cancelled.abort()
    const result = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null }), fetch as never, { signal: cancelled.signal })
    assert.equal(result.kind, 'failed')
    assert.equal(result.kind === 'failed' && result.seconds, undefined, 'not a measurement')
    assert.equal(server.seen.length, 0)
  } finally { await server.close() }
})

// MARK: - The main process's part

/** Read through a function: after `assert.equal(last, null)` the compiler would take the field for null for good. */
const lastOriginal = (c: Cleaner) => c.last?.original

function cleaner(server: string, settings: Partial<CleanupSettings> = {}, keys: Record<string, string> = {}, options: { onlyThisComputer?: boolean } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-cleanup-'))
  const logs: string[] = []
  const instance = new Cleaner({
    dir,
    settings: provider => ({ provider: provider ?? 'custom', model: 'stand-in', address: `${server}/v1`, level: 'light', customPrompt: '', vocabulary: [], ...settings }),
    readAccount: account => keys[account] ?? null,
    fetcher: fetch,
    log: message => logs.push(message),
    changed: () => {},
    ...options,
  })
  return { instance, dir, logs }
}

test('the cleaner: the text cleaned, the run measured on disk, and neither text nor key in the log', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') }))
  try {
    const { instance, dir, logs } = cleaner(server.origin, {}, { 'custom-cleanup': 'SECRET-KEY' })
    const run = await instance.run(text)
    assert.equal(run.outcome, 'ok')
    assert.equal(run.text, 'Also, der Build ist gefailed, weil the tests are flaky.')
    assert.equal(server.seen[0].headers.authorization, 'Bearer SECRET-KEY')
    const speeds = JSON.parse(fs.readFileSync(path.join(dir, 'cleanup-speeds.json'), 'utf8'))
    assert.equal(speeds['custom|stand-in'].length, 1)
    assert.equal(instance.measured('custom')['stand-in'].length, 1)
    const log = logs.join('\n')
    assert.doesNotMatch(log, /SECRET-KEY|gefailed|flaky/)
    assert.match(log, /cleanup: custom stand-in, ok after/)
    // The state shows a run once its dictation was delivered with cleanup.
    assert.equal(instance.last, null)
    instance.delivered(true)
    assert.equal(lastOriginal(instance), text)
  } finally { await server.close() }
})

test('the cleaner: what is missing is said before anything is sent', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('x') }))
  try {
    assert.equal((await cleaner(server.origin, { provider: 'anthropic' }).instance.run(text)).outcome, 'No key')
    assert.equal((await cleaner(server.origin, { address: '' }).instance.run(text)).outcome, 'No address')
    assert.equal((await cleaner(server.origin, { address: 'http://example.com/v1' }).instance.run(text)).outcome, 'No address', 'http only to this computer')
    assert.equal((await cleaner(server.origin, { model: '' }).instance.run(text)).outcome, 'No model')
    assert.equal((await cleaner(server.origin, { level: 'custom', customPrompt: '  ' }).instance.run(text)).outcome, 'No prompt')
    // Nothing with letters in it: pasted as it is, not sent.
    assert.deepEqual(await cleaner(server.origin).instance.run('…').then(run => [run.outcome, run.text]), ['ok', '…'])
    assert.equal(server.seen.length, 0)
  } finally { await server.close() }
})

test('the cleaner in test mode sends nothing past this computer', async () => {
  const { instance, logs } = cleaner('http://127.0.0.1:9', { provider: 'openrouter', model: '' }, { openrouter: 'K' }, { onlyThisComputer: true })
  let asked = false
  ;(instance as unknown as { deps: { fetcher: typeof fetch } }).deps.fetcher = (async () => { asked = true; throw new Error('must not be called') }) as never
  const run = await instance.run(text)
  assert.equal(run.outcome, 'Not reachable')
  assert.equal(asked, false)
  assert.match(logs.join('\n'), /test mode sends nothing to openrouter/)
})

test('the cleaner: Ollama without a chosen model takes the first one installed', async () => {
  const server = await standIn(seen => seen.url === '/v1/models'
    ? { status: 200, body: { object: 'list', data: [{ id: 'qwen3.8:8b' }, { id: 'gemma4:4b' }] } }
    : { status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') })
  try {
    const run = await cleaner(server.origin, { provider: 'ollama', model: '' }).instance.run(text)
    assert.equal(run.outcome, 'ok')
    assert.equal(run.model, 'qwen3.8:8b')
    assert.equal(server.seen.at(-1)!.body.model, 'qwen3.8:8b')
  } finally { await server.close() }
})

test('the cleaner: "Ausprobieren" cancelled while Ollama lists its models sends no chat request and records no time', async () => {
  const server = await standIn(seen => seen.url === '/v1/models'
    ? { status: 200, body: { data: [{ id: 'qwen3.8:8b' }] }, delay: 300 }
    : { status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') })
  try {
    const { instance, dir } = cleaner(server.origin, { provider: 'ollama', model: '' })
    const mine = new AbortController()
    const run = instance.run(text, { provider: 'ollama', signal: mine.signal, trying: true })
    setTimeout(() => mine.abort(), 50)
    const result = await run
    assert.notEqual(result.outcome, 'ok')
    assert.equal(server.seen.some(seen => seen.url === '/v1/chat/completions'), false)
    assert.equal(fs.existsSync(path.join(dir, 'cleanup-speeds.json')), false)
  } finally { await server.close() }
})

test('OpenRouter\'s list: prices per token become per million, reasoning facts kept', () => {
  const list = parseOpenRouterList({ data: [
    { id: 'google/gemini-3.5-flash-lite', pricing: { prompt: '0.0000003', completion: '0.0000025' }, reasoning: { supported_efforts: ['minimal', 'low'], mandatory: true } },
    { id: 'free/model', pricing: { prompt: '0', completion: '0' } },
    { id: 'odd/model' },
  ] })
  assert.ok(Math.abs(list['google/gemini-3.5-flash-lite'].input! - 0.3) < 1e-9)
  assert.ok(Math.abs(list['google/gemini-3.5-flash-lite'].output! - 2.5) < 1e-9)
  assert.deepEqual(list['google/gemini-3.5-flash-lite'].reasoning, { supported_efforts: ['minimal', 'low'], mandatory: true })
  assert.deepEqual([list['free/model'].input, list['free/model'].reasoning], [0, null])
  assert.equal(list['odd/model'].input, undefined)
})

// MARK: - The text the model gets, and the order of what is missing

test('the model gets the dictation without the line breaks and spaces at its ends, and they come back on the answer', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Erster Punkt, zweiter Punkt.') }))
  try {
    const result = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null, vocabulary: [], text: '\nerster punkt zweiter punkt\n' }), fetch as never)
    assert.equal(result.kind === 'cleaned' && result.text, '\nErster Punkt, zweiter Punkt.\n')
    const messages = server.seen[0].body.messages as { role: string; content: string }[]
    assert.equal(messages.at(-1)!.content, '<dictation>\nerster punkt zweiter punkt\n</dictation>')
    // The budget is for the trimmed text: 27 characters, 6 tokens.
    assert.equal(server.seen[0].body.max_tokens, maxTokens('erster punkt zweiter punkt', 2000))
  } finally { await server.close() }
  // Spaces at the ends go to the model's side only: they are not given back.
  const spaced = await standIn(() => ({ status: 200, body: chat('Hallo Welt.') }))
  try {
    const result = await runCleanup(job({ provider: 'custom', base: spaced.origin, model: 'm', key: null, vocabulary: [], text: '  hallo welt  ' }), fetch as never)
    assert.equal(result.kind === 'cleaned' && result.text, 'Hallo Welt.')
    assert.equal((spaced.seen[0].body.messages as { content: string }[]).at(-1)!.content, '<dictation>\nhallo welt\n</dictation>')
  } finally { await spaced.close() }
})

test('the guard judges the trimmed text, and a changed answer is only "changed" against the original', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('hallo welt') }))
  try {
    const same = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null, vocabulary: [], text: 'hallo welt' }), fetch as never)
    assert.equal(same.kind === 'cleaned' && same.changed, false)
    const breaks = await runCleanup(job({ provider: 'custom', base: server.origin, model: 'm', key: null, vocabulary: [], text: 'hallo welt\n' }), fetch as never)
    assert.equal(breaks.kind === 'cleaned' && breaks.text, 'hallo welt\n', 'the end of the dictation is kept')
    assert.equal(breaks.kind === 'cleaned' && breaks.changed, false)
  } finally { await server.close() }
})

test('when several things are missing, the reason is the first of: the prompt, the key, the address, the model', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('x') }))
  try {
    const reason = async (settings: Partial<CleanupSettings>, keys: Record<string, string> = {}) => (await cleaner(server.origin, settings, keys).instance.run(text)).code
    // Everything missing at once: Azure without key, address and deployment, and an empty own prompt.
    assert.equal(await reason({ provider: 'azure', address: '', model: '', level: 'custom', customPrompt: '' }), 'no-prompt')
    assert.equal(await reason({ provider: 'azure', address: '', model: '' }), 'no-key')
    assert.equal(await reason({ provider: 'azure', address: '', model: '' }, { 'azure-openai': 'K' }), 'no-address')
    assert.equal(await reason({ provider: 'azure', address: 'https://mine.openai.azure.com', model: '' }, { 'azure-openai': 'K' }), 'no-model')
    // Custom\'s key is optional: the prompt, then the address.
    assert.equal(await reason({ provider: 'custom', address: '', model: '', level: 'custom', customPrompt: ' ' }), 'no-prompt')
    assert.equal(await reason({ provider: 'custom', address: '', model: '' }), 'no-address')
    assert.equal(server.seen.length, 0)
  } finally { await server.close() }
})

// MARK: - Test mode and the state it writes

test('test mode refuses every address that is not this computer, for a dictation and for "Ausprobieren", and says so in the log', async () => {
  for (const trying of [false, true]) {
    const { instance, logs } = cleaner('http://127.0.0.1:9', { provider: 'openrouter', model: '' }, { openrouter: 'K' }, { onlyThisComputer: true })
    let asked = false
    ;(instance as unknown as { deps: { fetcher: typeof fetch } }).deps.fetcher = (async () => { asked = true; throw new Error('must not be called') }) as never
    const run = await instance.run(text, { trying })
    assert.equal(run.outcome, 'Not reachable')
    assert.equal(run.code, 'not-reachable')
    assert.equal(asked, false)
    assert.match(logs.join('\n'), /^cleanup: test mode sends nothing to openrouter$/m)
  }
})

test('test mode lets a stand-in server on this computer through, and the opt-in lifts the guard', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') }))
  try {
    const here = cleaner(server.origin, {}, {}, { onlyThisComputer: true })
    assert.equal((await here.instance.run(text)).code, 'ok')
    assert.equal(server.seen.length, 1)
    // With the guard off (--test-cleanup-remote) a remote address is asked: the fetch is told, nothing is sent anywhere.
    const remote = cleaner(server.origin, { provider: 'openrouter', model: '' }, { openrouter: 'K' }, { onlyThisComputer: false })
    const asked: string[] = []
    ;(remote.instance as unknown as { deps: { fetcher: typeof fetch } }).deps.fetcher = (async (url: string) => { asked.push(url); throw new Error('stand-in') }) as never
    assert.equal((await remote.instance.run(text)).code, 'not-reachable')
    assert.deepEqual(asked, ['https://openrouter.ai/api/v1/chat/completions'])
  } finally { await server.close() }
})

test('the state shows the last delivered dictation\'s cleanup, and none after one that was not cleaned up', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.', { usage: { cost: 0.0002 } }) }))
  try {
    const { instance } = cleaner(server.origin, {}, {})
    assert.equal(cleanupState(instance.last), null)
    await instance.run(text)
    // Not delivered yet (it could still be thrown away): not in the state.
    assert.equal(instance.last, null)
    instance.delivered(true)
    const state = cleanupState(instance.last)!
    assert.deepEqual(Object.keys(state).sort(), ['cleaned', 'model', 'original', 'outcome', 'provider', 'seconds'])
    assert.equal(state.outcome, 'ok')
    assert.equal('reason' in state, false, 'no reason on ok')
    assert.equal(state.original, text)
    assert.equal(state.cleaned, 'Also, der Build ist gefailed, weil the tests are flaky.')
    assert.equal(state.provider, 'custom')
    assert.equal(state.model, 'stand-in')
    assert.equal(typeof state.seconds, 'number')
    // The next dictation went out without cleanup: nothing from the one before.
    instance.delivered(false)
    assert.equal(instance.last, null)
    assert.equal(cleanupState(instance.last), null)
    // A "Ausprobieren" in between is no dictation.
    instance.delivered(true)
    assert.equal(lastOriginal(instance), text)
    await instance.run('x y z', { trying: true })
    instance.delivered(true)
    assert.equal(lastOriginal(instance), text, 'a try does not replace the dictation\'s run')
  } finally { await server.close() }
})

test('the state of a failed cleanup: the stable word as outcome, the short reason beside it, what the model said, and nothing made up', async () => {
  const answer = 'Sure! Here is a joke: why did the build fail? Because the tests were flaky, of course, and nobody fixed them.'
  const server = await standIn(() => ({ status: 200, body: chat(answer) }))
  try {
    setLanguage('de')
    const { instance } = cleaner(server.origin, {}, {})
    await instance.run(text)
    instance.delivered(true)
    const state = cleanupState(instance.last)!
    assert.equal(state.outcome, 'rejected')
    assert.equal(state.reason, 'Antwort verworfen')
    assert.equal(state.cleaned, answer, 'the model\'s answer, also when the guard threw it out')
    assert.equal(state.original, text)
    // Nothing came back at all: no answer.
    const down = cleaner('http://127.0.0.1:9', { provider: 'openrouter', model: '' }, { openrouter: 'K' }, { onlyThisComputer: true })
    await down.instance.run(text)
    down.instance.delivered(true)
    const none = cleanupState(down.instance.last)!
    assert.equal(none.outcome, 'not-reachable')
    assert.equal(none.reason, 'Nicht erreichbar')
    assert.equal(none.cleaned, null)
    assert.equal(none.seconds, null)
    // Other statuses carry theirs in the word.
    const refused = await standIn(() => ({ status: 422, body: { error: { message: 'nope' } } }))
    try {
      const odd = cleaner(refused.origin, {}, {})
      await odd.instance.run(text)
      odd.instance.delivered(true)
      assert.equal(cleanupState(odd.instance.last)!.outcome, 'refused-422')
      assert.equal(cleanupState(odd.instance.last)!.reason, 'Anfrage abgelehnt (422)')
    } finally { await refused.close() }
  } finally { setLanguage('en'); await server.close() }
})

test('the state of a try has the same keys: cleaned, rejected, seconds, dollars, outcome and reason', async () => {
  const server = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.', { usage: { cost: 0.0002 } }) }))
  try {
    const { instance } = cleaner(server.origin, {}, {})
    const tried = cleanupTryState(await instance.run(text, { trying: true }))
    assert.deepEqual(Object.keys(tried).sort(), ['cleaned', 'dollars', 'model', 'outcome', 'provider', 'rejected', 'seconds'])
    assert.equal(tried.outcome, 'ok')
    assert.equal(tried.rejected, false)
    assert.equal(tried.cleaned, 'Also, der Build ist gefailed, weil the tests are flaky.')
    assert.equal(tried.dollars, 0.0002)
    assert.equal(instance.last, null, 'and it is no dictation')
  } finally { await server.close() }
  const joke = await standIn(() => ({ status: 200, body: chat('Sure! Here is a joke: why did the build fail? Because the tests were flaky, of course, and nobody fixed them.') }))
  try {
    const { instance } = cleaner(joke.origin, {}, {})
    const tried = cleanupTryState(await instance.run(text, { trying: true }))
    assert.deepEqual([tried.outcome, tried.reason, tried.rejected], ['rejected', 'Answer rejected', true])
    assert.match(tried.cleaned!, /^Sure!/)
    assert.equal(tried.dollars, null)
  } finally { await joke.close() }
})

test('a run on this computer costs nothing: "0 $" beside its time, once the server says its tokens, and no cost where it does not', async () => {
  const withUsage = await standIn(seen => seen.url === '/v1/models'
    ? { status: 200, body: { data: [{ id: 'qwen3.8:8b' }] } }
    : { status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.', { usage: { prompt_tokens: 500, completion_tokens: 20 } }) })
  try {
    const run = await cleaner(withUsage.origin, { provider: 'ollama', model: 'qwen3.8:8b' }).instance.run(text, { trying: true })
    assert.equal(run.dollars, 0)
    assert.equal(cleanupTryState(run).dollars, 0)
  } finally { await withUsage.close() }
  const without = await standIn(() => ({ status: 200, body: chat('Also, der Build ist gefailed, weil the tests are flaky.') }))
  try {
    const run = await cleaner(without.origin, { provider: 'ollama', model: 'qwen3.8:8b' }).instance.run(text, { trying: true })
    assert.equal(run.dollars, undefined)
  } finally { await without.close() }
})

// MARK: - Ollama and LM Studio, and OpenRouter\'s price list

test('the models Ollama and LM Studio list: no embedding models, they answer no chat', async () => {
  const server = await standIn(() => ({ status: 200, body: { data: [{ id: 'nomic-embed-text' }, { id: 'qwen3.8:8b' }, { id: 'BGE-Embed-large' }, { id: 'gemma4:4b' }] } }))
  try {
    const { instance } = cleaner(server.origin, { provider: 'ollama', address: `${server.origin}/v1`, model: '' })
    instance.installedAt('ollama', `${server.origin}/v1`)
    await new Promise(resolve => setTimeout(resolve, 100))
    assert.deepEqual(instance.installedAt('ollama', `${server.origin}/v1`).models, ['qwen3.8:8b', 'gemma4:4b'])
    // So the first model installed, when none is chosen, is a chat model.
    const run = await cleaner(server.origin, { provider: 'lmstudio', model: '' }).instance.run(text)
    assert.equal(server.seen.at(-1)!.body.model, run.model)
    assert.equal(run.model, 'qwen3.8:8b')
  } finally { await server.close() }
})

test('OpenRouter\'s price list: not asked again within ten minutes of a failure, then asked, and kept for a day after it arrived', async () => {
  let clock = Date.parse('2026-10-14T10:00:00Z')
  const asked: number[] = []
  let reply: () => Response = () => new Response('nope', { status: 503 })
  const { instance } = (() => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-cleanup-'))
    const made = new Cleaner({
      dir, settings: () => ({ provider: 'openrouter', model: '', address: '', level: 'light', customPrompt: '', vocabulary: [] }), readAccount: () => null,
      fetcher: (async () => { asked.push(clock); return reply() }) as never, log: () => {}, changed: () => {}, now: () => clock,
    })
    return { instance: made }
  })()
  const settle = () => new Promise(resolve => setTimeout(resolve, 20))
  instance.refreshList(); await settle()
  assert.equal(asked.length, 1)
  // Every visit to Settings within ten minutes: no new request.
  clock += 9 * 60_000
  instance.refreshList(); await settle()
  assert.equal(asked.length, 1, 'backed off after the failure')
  clock += 2 * 60_000
  reply = () => new Response(JSON.stringify({ data: [{ id: 'google/gemini-3.5-flash-lite', pricing: { prompt: '0.0000003', completion: '0.0000025' } }] }), { status: 200 })
  instance.refreshList(); await settle()
  assert.equal(asked.length, 2, 'ten minutes are over')
  assert.ok(instance.livePrice('google/gemini-3.5-flash-lite'))
  clock += 3_600_000
  instance.refreshList(); await settle()
  assert.equal(asked.length, 2, 'kept for a day')
  clock += 24 * 3_600_000
  instance.refreshList(); await settle()
  assert.equal(asked.length, 3, 'a day later')
})

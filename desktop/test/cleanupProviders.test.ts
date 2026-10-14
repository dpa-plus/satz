import assert from 'node:assert/strict'
import test from 'node:test'
import {
  catalogModel, chosenModel, cleanupAccounts, cleanupBase, cleanupMissing, cleanupNeeds, cleanupProviderLabel, cleanupProviderOrder, cleanupProviders, cleanupSwitchRow,
  defaultCleanupProvider, isOnThisComputer, modelSeconds, usableAddress,
} from '../src/core/cleanupProviders'
import { buildRequest } from '../src/core/cleanupRequest'
import { providers, type Provider } from '../src/core/transcriber'

test('the cleanup providers, in the menu\'s order; Apple only on the Mac', () => {
  assert.deepEqual(cleanupProviderOrder, ['openrouter', 'openai', 'anthropic', 'google', 'groq', 'cerebras', 'mistral', 'deepseek', 'xai', 'azure', 'ollama', 'lmstudio', 'custom'])
  assert.deepEqual(Object.keys(cleanupProviders).sort(), [...cleanupProviderOrder].sort())
  assert.equal(cleanupProviders.azure.name.de, 'Microsoft Azure')
  assert.equal(cleanupProviders.custom.name.de, 'Eigener')
  assert.equal(cleanupProviders.custom.name.en, 'Custom')
})

test('the default models and addresses are the spec\'s', () => {
  const defaults = Object.fromEntries(cleanupProviderOrder.map(id => [id, cleanupProviders[id].defaultModel]))
  assert.deepEqual(defaults, {
    openrouter: 'google/gemini-3.5-flash-lite', openai: 'gpt-6-luna', anthropic: 'claude-haiku-5-5', google: 'gemini-3.5-flash-lite', groq: 'openai/gpt-oss-120b',
    cerebras: 'qwen-3.8-27b', mistral: 'mistral-small-latest', deepseek: 'deepseek-flash', xai: 'grok-4.7', azure: '', ollama: '', lmstudio: '', custom: '',
  })
  assert.equal(cleanupProviders.deepseek.address, 'https://api.deepseek.com')
  assert.equal(cleanupProviders.ollama.address, 'http://localhost:11434/v1')
  assert.equal(cleanupProviders.lmstudio.address, 'http://localhost:1234/v1')
  // Every default is the first of its menu.
  for (const id of cleanupProviderOrder) if (cleanupProviders[id].models.length) assert.equal(cleanupProviders[id].models[0].id, cleanupProviders[id].defaultModel, id)
})

test('OpenRouter offers each maker\'s current generation, in the spec\'s order', () => {
  assert.deepEqual(cleanupProviders.openrouter.models.map(model => model.id), [
    'google/gemini-3.5-flash-lite', 'qwen/qwen3.8-27b', 'deepseek/deepseek-v4.1-flash', 'anthropic/claude-haiku-5.5', 'openai/gpt-6-luna', 'z-ai/glm-5.3',
    'minimax/minimax-m3', 'mistralai/mistral-large-4-0', 'google/gemini-3.8-flash', 'moonshotai/kimi-k3', 'deepseek/deepseek-v4-pro-0813',
    'anthropic/claude-sonnet-5.5', 'openai/gpt-6-sol', 'openai/gpt-6.1-sol', 'google/gemini-4-argon', 'anthropic/claude-opus-5.5', 'x-ai/grok-4.7',
  ])
  // Older generations are gone.
  for (const old of ['google/gemini-2.5-flash-lite', 'x-ai/grok-4.3', 'openai/gpt-oss-120b']) assert.equal(catalogModel('openrouter', old), undefined)
  const haiku = catalogModel('openrouter', 'anthropic/claude-haiku-5.5')!
  assert.deepEqual([haiku.input, haiku.output, haiku.seconds, haiku.tps, haiku.tokenFactor], [0.10, 0.50, 1.6, 165, 1.7])
  for (const id of cleanupProviderOrder) for (const model of cleanupProviders[id].models) assert.doesNotMatch(JSON.stringify(model.note ?? ''), /—/)
})

test('the default cleanup provider follows transcription where it can clean up too, else OpenRouter', () => {
  const expected: Record<Provider, string> = { openrouter: 'openrouter', openai: 'openai', google: 'google', groq: 'groq', microsoft: 'openrouter', custom: 'openrouter', local: 'openrouter' }
  for (const [transcription, cleanup] of Object.entries(expected)) assert.equal(defaultCleanupProvider(transcription as Provider), cleanup, transcription)
})

test('key accounts: the shared ones are the transcription key files, the new ones are their own', () => {
  for (const id of ['openrouter', 'openai', 'google', 'groq'] as const) {
    assert.equal(cleanupProviders[id].account, id)
    assert.ok(Object.hasOwn(providers, cleanupProviders[id].account!), `${id} shares the transcription key`)
  }
  const fresh = ['anthropic', 'cerebras', 'mistral', 'deepseek', 'xai', 'azure', 'custom'] as const
  assert.deepEqual(fresh.map(id => cleanupProviders[id].account), ['anthropic', 'cerebras', 'mistral', 'deepseek', 'xai', 'azure-openai', 'custom-cleanup'])
  for (const id of fresh) assert.ok(!Object.hasOwn(providers, cleanupProviders[id].account!), `${id} has a key of its own`)
  // Microsoft's Speech key and Custom's transcription key are other files.
  assert.ok(!cleanupAccounts.includes('microsoft'))
  assert.ok(!cleanupAccounts.includes('custom'))
  assert.equal(new Set(cleanupAccounts).size, cleanupAccounts.length)
  assert.equal(cleanupProviders.ollama.account, null)
  assert.equal(cleanupProviders.lmstudio.account, null)
  assert.equal(cleanupProviders.custom.keyOptional, true)
})

test('key placeholders and pages', () => {
  assert.equal(cleanupProviders.anthropic.keyPlaceholder.en, 'sk-ant-…')
  assert.equal(cleanupProviders.anthropic.keyPage, 'https://console.anthropic.com/settings/keys')
  assert.equal(cleanupProviders.cerebras.keyPlaceholder.en, 'csk-…')
  assert.equal(cleanupProviders.mistral.keyPlaceholder.de, 'API-Schlüssel')
  assert.equal(cleanupProviders.deepseek.keyPage, 'https://platform.deepseek.com/api_keys')
  assert.equal(cleanupProviders.xai.keyPlaceholder.en, 'xai-…')
  assert.match(cleanupProviders.azure.keyNote!.de, /nicht der Speech-Schlüssel/)
  assert.equal(cleanupProviders.custom.keyPlaceholder.en, 'API key (optional)')
  // The shared ones keep their placeholders.
  assert.equal(cleanupProviders.openrouter.keyPlaceholder.en, providers.openrouter.keyPlaceholder())
  assert.equal(cleanupProviders.google.keyPlaceholder.en, providers.google.keyPlaceholder())
  for (const id of cleanupProviderOrder) { const page = cleanupProviders[id].keyPage; if (page) assert.match(page, /^https:\/\//) }
  // The Mac shows a link for every provider that has a page, the shared accounts' too (the same pages as its setup).
  assert.equal(cleanupProviders.openrouter.keyPage, 'https://openrouter.ai/settings/keys')
  assert.equal(cleanupProviders.openai.keyPage, 'https://platform.openai.com/api-keys')
  assert.equal(cleanupProviders.groq.keyPage, 'https://console.groq.com/keys')
  assert.equal(cleanupProviders.google.keyPage, 'https://aistudio.google.com/apikey')
  assert.deepEqual(cleanupProviderOrder.filter(id => !cleanupProviders[id].keyPage), ['azure', 'ollama', 'lmstudio', 'custom'])
})

test('the Google key note says "free key", as the spec does', () => {
  const note = catalogModel('google', 'gemini-3.5-flash-lite')!.note!
  assert.equal(note.en, 'With a free key Google may use the text to improve its products; with billing switched on it may not.')
  assert.equal(note.de, 'Mit einem kostenlosen Schlüssel darf Google den Text zur Verbesserung seiner Produkte nutzen, mit eingeschalteter Abrechnung nicht.')
  assert.match(catalogModel('google', 'gemini-4-argon')!.note!.en, /^Thinks briefly\. With a free key/)
  assert.equal(cleanupProviders.google.unknownModel!.note, cleanupProviders.google.models[0].note, 'a typed id gets it too')
})

test('Anthropic takes no temperature for any Claude id, typed ones included; a typed id counts like Claude', () => {
  for (const model of cleanupProviders.anthropic.models) assert.equal(model.noTemperature, true, model.id)
  assert.equal(cleanupProviders.anthropic.anyModel!.noTemperature, true)
  assert.equal(cleanupProviders.anthropic.anyModel!.tokenFactor, 1.7)
  assert.equal(buildTemperature('claude-haiku-5-5'), false)
  assert.equal(buildTemperature('claude-haiku-9-typed'), false)
})

test('the seconds a model took: the catalog\'s, or what a typed deployment is known by', () => {
  assert.equal(modelSeconds('openrouter', 'x-ai/grok-4.7'), 4.6)
  assert.equal(modelSeconds('xai', 'grok-4.7'), 4.6)
  assert.equal(modelSeconds('azure', 'my-deployment'), 1.5)
  assert.equal(modelSeconds('openrouter', 'new/model'), undefined)
  assert.equal(modelSeconds('custom', 'm'), undefined)
})

test('addresses: https anywhere, http only to this computer, the origin and path kept without a trailing slash', () => {
  assert.equal(usableAddress('https://example.com/v1/'), 'https://example.com/v1')
  assert.equal(usableAddress('example.com/v1'), 'https://example.com/v1')
  assert.equal(usableAddress('http://localhost:11434/v1'), 'http://localhost:11434/v1')
  assert.equal(usableAddress('http://127.0.0.1:9999'), 'http://127.0.0.1:9999')
  assert.equal(usableAddress('http://[::1]:1234/v1'), 'http://[::1]:1234/v1')
  assert.equal(usableAddress('http://example.com/v1'), null)
  assert.equal(usableAddress('ftp://example.com'), null)
  assert.equal(usableAddress('https://'), null)
  assert.equal(usableAddress(''), null)
  assert.equal(usableAddress(undefined), null)
  assert.equal(isOnThisComputer('http://127.0.0.1:9/v1'), true)
  assert.equal(isOnThisComputer('https://api.openai.com/v1'), false)
})

test('where requests go: fixed, a default the user may change, Azure\'s origin with /openai/v1, Custom\'s as typed', () => {
  assert.equal(cleanupBase('openrouter', 'https://evil.example'), 'https://openrouter.ai/api/v1')
  assert.equal(cleanupBase('ollama', ''), 'http://localhost:11434/v1')
  assert.equal(cleanupBase('ollama', 'http://127.0.0.1:8080/v1/'), 'http://127.0.0.1:8080/v1')
  assert.equal(cleanupBase('ollama', 'http://other.lan:11434/v1'), null)
  assert.equal(cleanupBase('azure', 'https://mine.openai.azure.com/openai/deployments/x?api-version=1'), 'https://mine.openai.azure.com/openai/v1')
  assert.equal(cleanupBase('azure', ''), null)
  assert.equal(cleanupBase('custom', 'http://127.0.0.1:5000/v1'), 'http://127.0.0.1:5000/v1')
  assert.equal(cleanupBase('custom', ''), null)
})

test('the model in use: chosen, the default, or the first installed', () => {
  assert.equal(chosenModel('openrouter', ''), 'google/gemini-3.5-flash-lite')
  assert.equal(chosenModel('openrouter', ' x-ai/grok-4.7 '), 'x-ai/grok-4.7')
  assert.equal(chosenModel('ollama', '', ['qwen3.8:8b', 'gemma4']), 'qwen3.8:8b')
  assert.equal(chosenModel('ollama', '', []), '')
  assert.equal(chosenModel('azure', ''), '')
})

test('what a provider still needs, and the words for it', () => {
  assert.deepEqual(cleanupNeeds('openrouter', { hasKey: false }), ['key'])
  assert.deepEqual(cleanupNeeds('openrouter', { hasKey: true }), [])
  assert.deepEqual(cleanupNeeds('azure', { hasKey: false }), ['key', 'address', 'model'])
  assert.deepEqual(cleanupNeeds('azure', { hasKey: true, address: 'https://mine.openai.azure.com', model: 'gpt-6-luna-prod' }), [])
  assert.deepEqual(cleanupNeeds('custom', { hasKey: false, address: 'http://127.0.0.1:5000/v1', model: 'm' }), [], 'Custom\'s key is optional')
  assert.deepEqual(cleanupNeeds('ollama', { hasKey: false, installed: [] }), ['model'])
  assert.deepEqual(cleanupNeeds('ollama', { hasKey: false, installed: ['qwen3.8:8b'] }), [])
  assert.equal(cleanupMissing(['key'], false, 'de'), 'Erst den Schlüssel eintragen.')
  assert.equal(cleanupMissing(['key', 'address'], false, 'en'), 'Enter the key and address first.')
  // The Mac's words for the empty own prompt (it ends without a full stop there, like its other messages).
  assert.equal(cleanupMissing([], true, 'de'), 'Erst den Prompt eintragen.')
  assert.equal(cleanupMissing([], true, 'en'), 'Enter the prompt first.')
  assert.equal(cleanupMissing(['key'], true, 'de'), 'Erst den Schlüssel eintragen.', 'the provider\'s need comes first')
  assert.equal(cleanupMissing([], false, 'en'), null)
})

test('looking is not switching: the menu says which is in use, the row under it offers the switch once it can work', () => {
  assert.equal(cleanupProviderLabel('openrouter', 'openrouter', 'de'), 'OpenRouter · in Benutzung')
  assert.equal(cleanupProviderLabel('openrouter', 'openrouter', 'en'), 'OpenRouter · in use')
  assert.equal(cleanupProviderLabel('anthropic', 'openrouter', 'en'), 'Anthropic')
  assert.equal(cleanupSwitchRow('openrouter', 'openrouter', 'de'), null)
  assert.deepEqual(cleanupSwitchRow('anthropic', 'openrouter', 'de'), { text: 'Aufräumen geht an OpenRouter.', button: 'Anthropic benutzen' })
  assert.deepEqual(cleanupSwitchRow('anthropic', 'openrouter', 'en'), { text: 'Cleanup goes to OpenRouter.', button: 'Use Anthropic' })
  assert.deepEqual(cleanupSwitchRow('anthropic', 'openrouter', 'de', ['key']), { text: 'Aufräumen geht an OpenRouter. Erst den Schlüssel eintragen.', button: null })
  assert.deepEqual(cleanupSwitchRow('custom', 'openrouter', 'de'), { text: 'Aufräumen geht an OpenRouter.', button: 'Eigenen benutzen' })
  assert.deepEqual(cleanupSwitchRow('openrouter', 'custom', 'de'), { text: 'Aufräumen geht an „Eigener“.', button: 'OpenRouter benutzen' })
  // Curly quotes in English too, as on the Mac.
  assert.deepEqual(cleanupSwitchRow('openrouter', 'custom', 'en'), { text: 'Cleanup goes to “Custom”.', button: 'Use OpenRouter' })
})

/** Whether a request for a typed Claude id carries a temperature: no family field says so, so look at the body. */
function buildTemperature(model: string): boolean {
  const request = buildRequest({ provider: 'anthropic', base: cleanupProviders.anthropic.address!, model, key: 'K', level: 'light', customPrompt: '', vocabulary: [], text: 'hallo welt' })
  return 'temperature' in request.body
}

test('addresses are normalised the same way on both: scheme and host in lower case, no query, no user info, no default port', () => {
  assert.equal(usableAddress('HTTPS://Example.COM/V1'), 'https://example.com/V1', 'the path keeps its case')
  assert.equal(usableAddress('http://LOCALHOST:1'), 'http://localhost:1')
  assert.equal(usableAddress('https://mine.openai.azure.com/some/path?api-version=1'), 'https://mine.openai.azure.com/some/path')
  assert.equal(usableAddress('https://user:pw@example.com/v1'), 'https://example.com/v1', 'a key never travels with user info')
  assert.equal(usableAddress('https://example.com:443/v1'), 'https://example.com/v1')
  assert.equal(usableAddress('https://example.com:8443/v1'), 'https://example.com:8443/v1')
  assert.equal(usableAddress('  example.com/v1//  '), 'https://example.com/v1')
  assert.equal(cleanupBase('azure', 'https://Mine.OpenAI.azure.com/openai/deployments/x?api-version=1'), 'https://mine.openai.azure.com/openai/v1')
})

test('a Gemini id may be typed with or without "models/", and is made safe for the address', () => {
  const url = (model: string) => buildRequest({ provider: 'google', base: cleanupProviders.google.address!, model, key: 'K', level: 'light', customPrompt: '', vocabulary: [], text: 'hallo' }).url
  assert.equal(url('gemini-3.5-flash-lite'), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent')
  assert.equal(url('models/gemini-3.5-flash-lite'), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent')
  assert.equal(url('gemini 3/x'), 'https://generativelanguage.googleapis.com/v1beta/models/gemini%203%2Fx:generateContent')
})

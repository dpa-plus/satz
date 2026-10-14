import assert from 'node:assert/strict'
import test from 'node:test'
import { localRowAction, needsMessage, providerLabel, providerNeeds, providerOrder, switchRow, useLocalModel } from '../src/core/browse'
import { providers } from '../src/core/transcriber'

test('the menu lists every provider, and the one in use says so', () => {
  assert.deepEqual([...providerOrder].sort(), Object.keys(providers).sort())
  assert.deepEqual(providerOrder.map(provider => providerLabel(provider, 'openrouter', 'de')), ['OpenRouter (in Benutzung)', 'OpenAI', 'Groq', 'Microsoft', 'Google', 'Eigener', 'Lokal'])
  assert.deepEqual(providerOrder.map(provider => providerLabel(provider, 'local', 'en')), ['OpenRouter', 'OpenAI', 'Groq', 'Microsoft', 'Google', 'Custom', 'Local (in use)'])
  assert.deepEqual(providerOrder.map(provider => providerLabel(provider, 'microsoft', 'de')).filter(label => label.includes('Benutzung')), ['Microsoft (in Benutzung)'])
})

test('showing the provider in use needs no row; showing another says where dictations go and offers the switch', () => {
  assert.equal(switchRow('openrouter', 'openrouter', 'de'), null)
  assert.deepEqual(switchRow('local', 'openrouter', 'de'), { text: 'Diktate gehen an OpenRouter.', button: 'Lokal benutzen' })
  assert.deepEqual(switchRow('local', 'openrouter', 'en'), { text: 'Dictation goes to OpenRouter.', button: 'Use Local' })
  assert.deepEqual(switchRow('openai', 'local', 'de'), { text: 'Diktate gehen an „Lokal“.', button: 'OpenAI benutzen' })
  assert.deepEqual(switchRow('custom', 'groq', 'de'), { text: 'Diktate gehen an Groq.', button: 'Eigenen benutzen' })
  assert.deepEqual(switchRow('groq', 'custom', 'en'), { text: 'Dictation goes to "Custom".', button: 'Use Groq' })
  // No em dashes in anything the page says.
  for (const shown of providerOrder) for (const inUse of providerOrder) for (const language of ['de', 'en'] as const) {
    const row = switchRow(shown, inUse, language)
    assert.doesNotMatch(`${row?.text} ${row?.button} ${providerLabel(shown, inUse, language)}`, /—/)
  }
})

test('"In use" on a local model only while Local is the provider in use', () => {
  assert.equal(localRowAction('a/turbo', 'a/turbo', true), 'in-use')
  assert.equal(localRowAction('a/small', 'a/turbo', true), 'use')
  // Local's chosen model while another provider is in use: dictations do not go to it.
  assert.equal(localRowAction('a/turbo', 'a/turbo', false), 'use')
})

test('"Use" on a local model picks it, and switches to Local only when another provider is in use', () => {
  const models = { openrouter: 'microsoft/mai-transcribe-2', local: 'a/turbo' }
  assert.deepEqual(useLocalModel('a/small', models, true), { models: { openrouter: 'microsoft/mai-transcribe-2', local: 'a/small' } })
  assert.deepEqual(useLocalModel('a/small', models, false), { models: { openrouter: 'microsoft/mai-transcribe-2', local: 'a/small' }, provider: 'local' })
  // The chosen one, pressed while another provider is in use: the explicit switch.
  assert.deepEqual(useLocalModel('a/turbo', models, false), { models, provider: 'local' })
  assert.deepEqual(models, { openrouter: 'microsoft/mai-transcribe-2', local: 'a/turbo' })
})

const facts = { hasKey: true, customBaseURL: '', model: '', microsoftRegion: 'northeurope', microsoftEndpoint: '' }

test('a provider is ready once it has what it needs: a key; Custom also an address and a model; Microsoft a region; Local its model', () => {
  for (const provider of ['openrouter', 'openai', 'groq', 'google'] as const) {
    assert.deepEqual(providerNeeds(provider, facts), [], provider)
    assert.deepEqual(providerNeeds(provider, { ...facts, hasKey: false }), ['key'], provider)
  }
  // Microsoft: the default region is a region, an own address that is none is not.
  assert.deepEqual(providerNeeds('microsoft', facts), [])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, hasKey: false }), ['key'])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftRegion: 'east us' }), ['region'])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftRegion: 'east us', microsoftEndpoint: 'https://r.cognitiveservices.azure.com' }), [])
  // Typed and refused is not "no address yet": the page says why (codexFixAddress.test.ts).
  assert.deepEqual(providerNeeds('microsoft', { ...facts, microsoftEndpoint: 'http://speech.example.com' }), ['addressRefused'])
  assert.deepEqual(providerNeeds('microsoft', { ...facts, hasKey: false, microsoftRegion: '' , microsoftEndpoint: undefined }), ['key'])
  assert.deepEqual(providerNeeds('custom', { ...facts, hasKey: false }), ['key', 'address', 'model'])
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: 'https://x.test/v1', model: ' m ' }), [])
  assert.deepEqual(providerNeeds('local', { ...facts, hasKey: false }), ['localModel'])
  assert.deepEqual(providerNeeds('local', facts), [])
})

test('what is missing is said once for everything, in both languages, without em dashes', () => {
  assert.equal(needsMessage([], 'de'), null)
  assert.equal(needsMessage(['key'], 'de'), 'Erst den Schlüssel eintragen.')
  assert.equal(needsMessage(['key'], 'en'), 'Enter the key first.')
  assert.equal(needsMessage(['region'], 'de'), 'Erst die Region wählen.')
  assert.equal(needsMessage(['region'], 'en'), 'Choose the region first.')
  assert.equal(needsMessage(['key', 'address', 'model'], 'de'), 'Erst Schlüssel, Adresse und Modell eintragen.')
  assert.equal(needsMessage(['key', 'address', 'model'], 'en'), 'Enter the key, address and model first.')
  assert.equal(needsMessage(['localModel'], 'de'), 'Erst ein Modell laden.')
  assert.equal(needsMessage(['localModel'], 'en'), 'Download a model first.')
})

test('the switch button is offered only once the provider is ready; until then the row says what is missing', () => {
  assert.deepEqual(switchRow('google', 'openrouter', 'de', ['key']), { text: 'Diktate gehen an OpenRouter. Erst den Schlüssel eintragen.', button: null })
  assert.deepEqual(switchRow('microsoft', 'local', 'en', ['key']), { text: 'Dictation goes to "Local". Enter the key first.', button: null })
  assert.deepEqual(switchRow('microsoft', 'openrouter', 'de', []), { text: 'Diktate gehen an OpenRouter.', button: 'Microsoft benutzen' })
  assert.deepEqual(switchRow('google', 'groq', 'en', []), { text: 'Dictation goes to Groq.', button: 'Use Google' })
  // Nothing to switch while the provider in use is shown, ready or not.
  assert.equal(switchRow('google', 'google', 'de', ['key']), null)
  for (const shown of providerOrder) for (const inUse of providerOrder) for (const language of ['de', 'en'] as const) {
    const row = switchRow(shown, inUse, language, ['key', 'address'])
    assert.doesNotMatch(`${row?.text} ${row?.button}`, /—/)
  }
})

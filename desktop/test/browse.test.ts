import assert from 'node:assert/strict'
import test from 'node:test'
import { localRowAction, providerLabel, providerOrder, switchRow, useLocalModel } from '../src/core/browse'
import { providers } from '../src/core/transcriber'

test('the menu lists every provider, and the one in use says so', () => {
  assert.deepEqual([...providerOrder].sort(), Object.keys(providers).sort())
  assert.deepEqual(providerOrder.map(provider => providerLabel(provider, 'openrouter', 'de')), ['OpenRouter (in Benutzung)', 'OpenAI', 'Groq', 'Eigener', 'Lokal'])
  assert.deepEqual(providerOrder.map(provider => providerLabel(provider, 'local', 'en')), ['OpenRouter', 'OpenAI', 'Groq', 'Custom', 'Local (in use)'])
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

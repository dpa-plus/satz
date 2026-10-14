import assert from 'node:assert/strict'
import test from 'node:test'
import { addressRefusal, keyRefusal } from '../src/core/browse'

/*
 * The Settings page itself (src/renderer/settings.ts), run against a stand-in
 * for the DOM and for the app: a refused key says why instead of "Konnte nicht
 * gesichert werden", and an address that is typed and refused says why, under
 * the field and in the row under the provider menu. Nothing else tests the
 * page; this is the way main.ts's handlers are tested too, only with the real
 * module in place of a look at its source.
 */

// MARK: - A DOM as small as the page needs

class FakeNode {
  /** The page assigns whatever it likes to an element (className, onclick, value …). */
  [property: string]: unknown
  children: (FakeNode | string)[] = []
  attributes: Record<string, string> = {}
  constructor(readonly tag: string) {}
  append(...nodes: (FakeNode | string)[]) { this.children.push(...nodes) }
  replaceChildren(...nodes: (FakeNode | string)[]) { this.children = nodes }
  setAttribute(name: string, value: string) { this.attributes[name] = value }
  addEventListener() {}
  focus() { fake.activeElement = this }
  select() {}
}

const fake = {
  activeElement: null as FakeNode | null,
  root: new FakeNode('div'),
  documentElement: { lang: '' },
}

const everyNode = (node: FakeNode): FakeNode[] => [node, ...node.children.flatMap(child => (typeof child === 'string' ? [] : everyNode(child)))]
const textOf = (node: FakeNode): string => [typeof node.textContent === 'string' ? node.textContent : '', ...node.children.map(child => (typeof child === 'string' ? child : textOf(child)))].join('\n')
const byId = (id: string) => everyNode(fake.root).find(node => node.id === id)
const buttonNamed = (text: string) => everyNode(fake.root).find(node => node.tag === 'button' && node.textContent === text)

Object.assign(globalThis, {
  document: {
    createElement: (tag: string) => new FakeNode(tag),
    getElementById: (id: string) => (id === 'settings-page' ? fake.root : byId(id) ?? null),
    get activeElement() { return fake.activeElement },
    documentElement: fake.documentElement,
    dispatchEvent() {},
    addEventListener() {},
  },
  CustomEvent: class { constructor(readonly type: string, readonly init?: unknown) {} },
  HTMLInputElement: class {},
  HTMLTextAreaElement: class {},
})

// MARK: - A stand-in for the app

interface State { provider: string; shown: string; hasKey: boolean; language: 'de' | 'en'; customBaseURL: string; microsoftEndpoint: string; models: Record<string, string> }
const state: State = { provider: 'openrouter', shown: 'openrouter', hasKey: false, language: 'en', customBaseURL: '', microsoftEndpoint: '', models: {} }
const asked: [string, ...unknown[]][] = []
const listeners = new Map<string, (value: unknown) => void>()
let keyAnswer = true

function info() {
  return {
    prefs: {
      provider: state.provider, models: state.models, customBaseURL: state.customBaseURL, microsoftRegion: 'northeurope', microsoftEndpoint: state.microsoftEndpoint, words: [], triggerMode: 'tap',
      language: state.language, spokenLanguage: null, replacements: [], usesReplacements: true, removesFillers: true, keepsOnClipboard: false, historyLimit: 50, pausesMedia: true,
      cleansText: false, cleanupLevel: 'light', cleanupPrompt: '', cleanupProvider: null, cleanupModels: {}, cleanupAddresses: {},
    },
    // The cleanup section below the provider: off, nothing to say about addresses or keys.
    cleanup: { inUse: 'openrouter', shown: 'openrouter', hasKey: false, inUseHasKey: false, prices: {}, samples: {}, installed: { state: 'ok', models: [], fetched: 0 }, inUseInstalled: { state: 'ok', models: [], fetched: 0 } },
    shown: state.shown, hasKey: state.hasKey, keyboard: 'right Ctrl', shortcutWorks: true, wayland: false, platform: 'linux', history: [], startAtLogin: false, spokenLanguage: 'en',
    models: [{ id: 'm', name: 'M', maker: 'Maker' }],
    local: { inUse: 'onnx-community/whisper-large-v3-turbo', models: [], germanErrors: {}, machine: 'test', version: '0.0.0' },
  }
}

;(globalThis as { window?: unknown }).window = {
  satz: {
    send() {},
    on: (channel: string, listener: (value: unknown) => void) => { listeners.set(channel, listener) },
    invoke: async (channel: string, ...args: unknown[]) => {
      asked.push([channel, ...args])
      if (channel === 'settings:get') { state.shown = String(args[0] ?? state.provider); return info() }
      if (channel === 'settings:store-key') { if (keyAnswer) state.hasKey = true; return keyAnswer }
      return undefined
    },
  },
}

const later = () => new Promise<void>(resolve => setTimeout(resolve, 0))
async function settle() { for (let i = 0; i < 10; i++) await later() }
/** Draws the page again from `state`, the way a changed model list does. */
async function reload() { listeners.get('models:changed')!(undefined); await settle() }
/** Picks a provider in the menu, the way a user does: it only shows it, and forgets the last problem. */
async function show(provider: string) {
  const menu = byId('provider')!
  menu.value = provider
  await (menu.onchange as () => void)()
  await settle()
}

test('the page loads against the stand-in', async () => {
  require('../src/renderer/settings')
  await settle()
  assert.ok(byId('key'), 'the key field is there while there is no key')
})

// MARK: - Keys

test('a key with a line break is refused on the page, with the reason, before the app is asked', async () => {
  for (const language of ['en', 'de'] as const) {
    state.language = language
    state.hasKey = false
    await reload()
    asked.length = 0
    const field = byId('key')!
    field.value = 'sk-or-first-half\nsk-or-second-half'
    await (buttonNamed(language === 'de' ? 'Sichern' : 'Save')!.onclick as () => Promise<void>)()
    await settle()
    assert.deepEqual(asked.filter(([channel]) => channel === 'settings:store-key'), [], 'the app was not asked to save it')
    const page = textOf(fake.root)
    assert.ok(page.includes(keyRefusal('a\nb', language)!), page)
    assert.ok(!page.includes('Konnte nicht gesichert werden') && !page.includes('Could not be saved'), 'not the generic line')
    assert.ok(!page.includes('first-half'), 'the key is not on the page')
    assert.ok(byId('key'), 'the field stays, for the key to be pasted again')
    assert.equal(fake.activeElement, byId('key'), 'with the cursor in it')
  }
  assert.match(keyRefusal('a\nb', 'en')!, /line break/)
})

test('a good key is saved, the reason goes away, and a key the app itself refuses still gets the generic line', async () => {
  state.language = 'en'
  state.hasKey = false
  await reload()
  byId('key')!.value = 'sk-or-fine'
  asked.length = 0
  await (buttonNamed('Save')!.onclick as () => Promise<void>)()
  await settle()
  assert.deepEqual(asked.filter(([channel]) => channel === 'settings:store-key'), [['settings:store-key', 'sk-or-fine', 'openrouter']])
  // The refusal itself, not the words: the cleanup prompt on the page says "Keep line breaks".
  assert.ok(!textOf(fake.root).includes(keyRefusal('a\nb', 'en')!))
  assert.ok(textOf(fake.root).includes('Key saved'))
  // The app says no for another reason (a full disk): the generic line, as before.
  state.hasKey = false
  keyAnswer = false
  await reload()
  byId('key')!.value = 'sk-or-fine'
  await (buttonNamed('Save')!.onclick as () => Promise<void>)()
  await settle()
  assert.ok(textOf(fake.root).includes('Could not be saved.'))
  keyAnswer = true
})

// MARK: - Addresses

const refusal = (language: 'de' | 'en') => addressRefusal(language)

test('Custom: an address that is typed and refused says why under the field, in both languages', async () => {
  for (const language of ['en', 'de'] as const) {
    Object.assign(state, { provider: 'custom', hasKey: true, language, customBaseURL: 'http://example.com/v1', models: { custom: 'whisper-1' } })
    await show('custom')
    await reload()
    const errors = everyNode(fake.root).filter(node => node.className === 'error').map(node => node.textContent)
    assert.deepEqual(errors, [refusal(language)], language)
  }
})

test('Custom: an address on the own network, or https, or none yet, gets no error', async () => {
  for (const customBaseURL of ['http://192.168.1.20:11434/v1', 'http://whisper.local:9000/v1', 'https://example.com/v1', '']) {
    Object.assign(state, { provider: 'custom', hasKey: true, language: 'en', customBaseURL, models: { custom: 'whisper-1' } })
    await show('custom')
    await reload()
    assert.deepEqual(everyNode(fake.root).filter(node => node.className === 'error').map(node => node.textContent), [], customBaseURL)
  }
})

test('Custom, looked at while another provider is in use: the row under the menu says why, not "Enter the address first"', async () => {
  Object.assign(state, { provider: 'openrouter', hasKey: true, language: 'en', customBaseURL: 'ftp://example.com/v1', models: { custom: 'whisper-1' } })
  await show('custom')
  const row = everyNode(fake.root).find(node => String(node.className).includes('switch-provider'))!
  assert.equal(textOf(row).replace(/\s+/g, ' ').trim(), `Dictation goes to OpenRouter. ${refusal('en')}`)
  assert.equal(byId('use-provider'), undefined, 'no button to switch to an address that cannot be used')
  // Nothing typed yet: the old words.
  state.customBaseURL = ''
  await reload()
  const empty = everyNode(fake.root).find(node => String(node.className).includes('switch-provider'))!
  assert.equal(textOf(empty).replace(/\s+/g, ' ').trim(), 'Dictation goes to OpenRouter. Enter the address first.')
})

test('Microsoft: its own address follows the rule, and the hint says why in the same words', async () => {
  Object.assign(state, { provider: 'microsoft', hasKey: true, language: 'de', microsoftEndpoint: 'http://speech.example.com', customBaseURL: '' })
  await show('microsoft')
  assert.deepEqual(everyNode(fake.root).filter(node => node.className === 'error').map(node => node.textContent), [refusal('de')])
  state.microsoftEndpoint = 'http://speech.lan:9000'
  await reload()
  assert.deepEqual(everyNode(fake.root).filter(node => node.className === 'error').map(node => node.textContent), [])
})

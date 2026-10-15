import assert from 'node:assert/strict'
import test from 'node:test'

/*
 * Codex bug hunt, third pass, on the Settings page (src/renderer/settings.ts)
 * run against a stand-in for the DOM and the app, as codexFixSettingsPage
 * does: DS-R3-01 (a "Ausprobieren" result under another provider, model,
 * level, prompt or sample), a Try that stays busy when the app throws, and the
 * line under the cleanup switch when the history keeps nothing.
 */

// MARK: - A DOM as small as the page needs, with parents

class FakeNode {
  [property: string]: unknown
  children: (FakeNode | string)[] = []
  parent: FakeNode | null = null
  attributes: Record<string, string> = {}
  style: Record<string, string> = {}
  constructor(readonly tag: string) {}
  get childNodes() { return this.children }
  append(...nodes: (FakeNode | string)[]) {
    for (const node of nodes) if (typeof node !== 'string') node.parent = this
    this.children.push(...nodes)
  }
  replaceChildren(...nodes: (FakeNode | string)[]) {
    for (const child of this.children) if (typeof child !== 'string') child.parent = null
    this.children = []
    this.append(...nodes)
  }
  replaceWith(node: FakeNode) {
    const parent = this.parent
    if (!parent) return
    parent.children[parent.children.indexOf(this)] = node
    node.parent = parent
    this.parent = null
  }
  remove() {
    const parent = this.parent
    if (!parent) return
    parent.children = parent.children.filter(child => child !== this)
    this.parent = null
  }
  setAttribute(name: string, value: string) { this.attributes[name] = value }
  addEventListener() {}
  focus() { fake.activeElement = this }
  select() {}
}

const fake = { activeElement: null as FakeNode | null, root: new FakeNode('div'), documentElement: { lang: '' } }

const everyNode = (node: FakeNode): FakeNode[] => [node, ...node.children.flatMap(child => (typeof child === 'string' ? [] : everyNode(child)))]
const textOf = (node: FakeNode): string => [typeof node.textContent === 'string' ? node.textContent : '', ...node.children.map(child => (typeof child === 'string' ? child : textOf(child)))].join('\n')
const byId = (id: string) => everyNode(fake.root).find(node => node.id === id)

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
  confirm: () => true,
})

// MARK: - A stand-in for the app

type Prefs = Record<string, unknown>
const basePrefs = (): Prefs => ({
  provider: 'openrouter', models: {}, customBaseURL: '', microsoftRegion: 'northeurope', microsoftEndpoint: '', words: [], triggerMode: 'tap',
  language: 'en', spokenLanguage: 'en', replacements: [], usesReplacements: true, removesFillers: true, keepsOnClipboard: false, historyLimit: 50, pausesMedia: false,
  cleansText: true, cleanupLevel: 'light', cleanupPrompt: '', cleanupProvider: 'openrouter', cleanupModels: {}, cleanupAddresses: {},
})
let prefs = basePrefs()
let asked: [string, ...unknown[]][] = []
/** The "cleanup:try" calls that have not been answered, in order. */
let tries: { args: unknown[]; resolve(value: unknown): void; reject(error: unknown): void }[] = []
const listeners = new Map<string, (value: unknown) => void>()

function info(shownProvider: unknown, shownCleanup: unknown) {
  const shown = typeof shownCleanup === 'string' ? shownCleanup : String(prefs.cleanupProvider)
  return {
    prefs: structuredClone(prefs),
    history: [],
    cleanup: {
      inUse: prefs.cleanupProvider, shown, hasKey: true, inUseHasKey: true, prices: {}, samples: {},
      installed: shown === 'ollama' ? { state: 'ok', models: ['qwen3.8:8b'] } : null, inUseInstalled: null,
    },
    shown: typeof shownProvider === 'string' ? shownProvider : prefs.provider, hasKey: true, wayland: false, platform: 'linux', startAtLogin: false, spokenLanguage: 'en',
    models: [{ id: 'm', name: 'M', maker: 'Maker' }],
    local: { inUse: 'onnx-community/whisper-large-v3-turbo', models: [], germanErrors: {}, machine: 'test', version: '0.0.0' },
  }
}

;(globalThis as { window?: unknown }).window = {
  satz: {
    send() {},
    on: (channel: string, listener: (value: unknown) => void) => { listeners.set(channel, listener) },
    invoke: (channel: string, ...args: unknown[]) => {
      asked.push([channel, ...args])
      switch (channel) {
        case 'settings:get': return Promise.resolve(info(args[0], args[1]))
        case 'settings:update': Object.assign(prefs, args[0]); return Promise.resolve(structuredClone(prefs))
        case 'history:set-limit': prefs.historyLimit = args[0]; return Promise.resolve()
        case 'history:get': return Promise.resolve({ entries: [], limit: prefs.historyLimit })
        case 'cleanup:try': return new Promise((resolve, reject) => { tries.push({ args, resolve, reject }) })
        default: return Promise.resolve(undefined)
      }
    },
  },
}

const later = () => new Promise<void>(resolve => setTimeout(resolve, 0))
async function settle() { for (let i = 0; i < 10; i++) await later() }

/** The page, loaded anew with these preferences: every module-level state of settings.ts starts over. */
async function open(change: Prefs = {}) {
  prefs = { ...basePrefs(), ...change }
  asked = []
  tries = []
  fake.root = new FakeNode('div')
  fake.activeElement = null
  const file = require.resolve('../src/renderer/settings')
  delete require.cache[file]
  require('../src/renderer/settings')
  await settle()
}

const calls = (channel: string) => asked.filter(([name]) => name === channel)
const tryButton = () => byId('cleanup-try-button')!
const isTrying = () => textOf(tryButton()).includes('Cancel')
const shownResult = () => byId('cleanup-try-result')
const page = () => textOf(fake.root)

/** Clicks a button and lets the page run on: a click on Try returns the promise of the whole Try, which is not over until the test answers it. */
async function press(id: string) { void Promise.resolve((byId(id)!.onclick as () => unknown)()).catch(() => {}); await settle() }
/** Chooses an entry of a menu, the way a user does. */
async function choose(id: string, value: string) {
  const menu = byId(id)!
  menu.value = value
  await (menu.onchange as () => unknown)()
  await settle()
}
/** Types into a field the way the browser reports it: the value changes, then the event. */
async function type(id: string, value: string) {
  const field = byId(id)!
  field.value = value
  await (field.oninput as () => unknown)()
  await settle()
}
const answer = (text: string, extra: Record<string, unknown> = {}) => ({ outcome: 'ok', answer: text, rejected: false, seconds: 1, cancelled: false, ...extra })

/** A Try that has finished with this answer. */
async function tried(text = 'Synthetic answer from provider A', extra: Record<string, unknown> = {}) {
  const index = tries.length
  await press('cleanup-try-button')
  assert.equal(tries.length, index + 1, 'the app was asked once more')
  tries[index].resolve(answer(text, extra))
  await settle()
  assert.ok(shownResult(), 'the answer is shown')
  assert.match(page(), new RegExp(text))
}

// MARK: - DS-R3-01: the result and the page have to agree

test('DS-R3-01: a Try that is still running is cancelled when another provider is shown, and its late answer never appears', async () => {
  await open()
  await press('cleanup-try-button')
  assert.deepEqual(tries[0].args.slice(1), ['openrouter'])
  assert.equal(isTrying(), true)
  await choose('cleanup-provider', 'groq')
  assert.equal(calls('cleanup:cancel-try').length, 1, 'the app was told to stop')
  assert.equal(isTrying(), false)
  assert.equal(shownResult(), undefined)
  tries[0].resolve(answer('Synthetic answer from provider A'))
  await settle()
  assert.equal(shownResult(), undefined)
  assert.ok(!page().includes('Synthetic answer from provider A'), 'not under Groq')
})

test('DS-R3-01: a result is taken away when the provider shown changes', async () => {
  await open()
  await tried()
  await choose('cleanup-provider', 'groq')
  assert.equal(shownResult(), undefined)
  assert.ok(!page().includes('Synthetic answer from provider A'))
  // Back where it was made: still no old answer.
  await choose('cleanup-provider', 'openrouter')
  assert.equal(shownResult(), undefined)
})

test('DS-R3-01: a result is taken away when the model changes', async () => {
  await open()
  await tried()
  await choose('cleanup-model', 'qwen/qwen3.8-27b')
  assert.deepEqual(prefs.cleanupModels, { openrouter: 'qwen/qwen3.8-27b' })
  assert.equal(shownResult(), undefined)
})

test('DS-R3-01: a result is taken away when a model id is typed in (the page is not drawn again for that)', async () => {
  await open({ cleanupProvider: 'custom', cleanupAddresses: { custom: 'https://example.org/v1' }, cleanupModels: { custom: 'first' } })
  await tried()
  const field = byId('cleanup-model-id')!
  field.value = 'second'
  await (field.onchange as () => unknown)()
  await settle()
  assert.equal(shownResult(), undefined)
})

test('DS-R3-01: a result is taken away when the level changes', async () => {
  await open()
  await tried()
  const strong = byId('cleanup-level-polished')!
  await (strong.onchange as () => unknown)()
  await settle()
  assert.equal(prefs.cleanupLevel, 'polished')
  assert.equal(shownResult(), undefined)
})

test('DS-R3-01: a result is taken away when the sample is edited, and the field is not drawn again under the cursor', async () => {
  await open()
  await tried()
  const field = byId('cleanup-try')!
  await type('cleanup-try', 'A wholly different synthetic sentence')
  assert.equal(shownResult(), undefined)
  assert.equal(byId('cleanup-try'), field, 'the same field: the cursor stays in it')
  assert.equal(field.value, 'A wholly different synthetic sentence')
  assert.equal(calls('cleanup:cancel-try').length, 0, 'nothing was running')
})

test('DS-R3-01: the own prompt edited while a Try runs cancels it, and edited after it took the result away', async () => {
  await open({ cleanupLevel: 'custom', cleanupPrompt: 'Keep every word.' })
  await press('cleanup-try-button')
  assert.equal(isTrying(), true)
  await type('cleanup-prompt', 'Keep every word, and add a full stop.')
  assert.equal(calls('cleanup:cancel-try').length, 1)
  assert.equal(isTrying(), false)
  tries[0].resolve(answer('Answer to the old prompt'))
  await settle()
  assert.equal(shownResult(), undefined)
  // And a finished one.
  await tried('Answer to the new prompt')
  await type('cleanup-prompt', 'Something else entirely.')
  assert.equal(shownResult(), undefined)
  // Leaving the field saves the draft now, so no timer is left running into the next test.
  await (byId('cleanup-prompt')!.onblur as () => unknown)()
})

test('DS-R3-01: a result stays while nothing it was made from changes, also when the page is drawn again; so does a Try that runs', async () => {
  await open()
  await tried()
  listeners.get('models:changed')!(undefined)
  await settle()
  assert.ok(shownResult(), 'drawn again, still there')
  const second = await (async () => { await press('cleanup-try-button'); return tries.length })()
  assert.equal(second, 2)
  listeners.get('models:changed')!(undefined)
  await settle()
  assert.equal(isTrying(), true, 'a redraw does not cancel it')
  assert.equal(calls('cleanup:cancel-try').length, 0)
  tries[1].resolve(answer('Second answer'))
  await settle()
  assert.match(page(), /Second answer/)
})

test('DS-R3-01: a result says which provider and which model made it', async () => {
  await open({ cleanupModels: { openrouter: 'qwen/qwen3.8-27b' } })
  await tried()
  assert.equal(textOf(byId('cleanup-try-by')!), 'OpenRouter · qwen/qwen3.8-27b')
  // What the app says wins over what the page asked for (Ollama's first model is known only there).
  await open({ cleanupProvider: 'ollama' })
  await tried('From Ollama', { provider: 'ollama', model: 'qwen3.8:8b' })
  assert.equal(textOf(byId('cleanup-try-by')!), 'Ollama · qwen3.8:8b')
})

test('DS-R3-01: a failed Try is labelled too', async () => {
  await open()
  await press('cleanup-try-button')
  tries[0].resolve({ outcome: 'Too slow', rejected: false, cancelled: false })
  await settle()
  assert.match(page(), /Too slow/)
  assert.match(textOf(byId('cleanup-try-by')!), /^OpenRouter · /)
})

test('a Try that was cancelled by the user keeps no answer, as before', async () => {
  await open()
  await press('cleanup-try-button')
  await press('cleanup-try-button')
  assert.equal(calls('cleanup:cancel-try').length, 1)
  tries[0].resolve(answer('Late'))
  await settle()
  assert.equal(shownResult(), undefined)
  assert.equal(isTrying(), false)
})

// MARK: - A Try that the app could not answer

test('a Try whose call is rejected settles: the box is free again, with a line that says it failed', async () => {
  await open()
  await press('cleanup-try-button')
  assert.equal(isTrying(), true)
  tries[0].reject(new TypeError('parts.filter is not a function'))
  await settle()
  assert.equal(isTrying(), false)
  assert.notEqual(byId('cleanup-try')!.readOnly, true, 'the sample can be edited again')
  assert.match(textOf(shownResult()!), /Trying it failed\./)
  assert.ok(!page().includes('parts.filter'), 'the error\'s own words are not shown')
  // And it can be tried again.
  await press('cleanup-try-button')
  assert.equal(tries.length, 2)
  tries[1].resolve(answer('Second try'))
  await settle()
  assert.match(page(), /Second try/)
})

test('a provider change while the Try saves its prompt prevents the old request from starting', async () => {
  await open({ cleanupLevel: 'custom', cleanupPrompt: 'Keep every word.' })
  const bridge = (globalThis as unknown as { window: { satz: { invoke: (channel: string, ...args: unknown[]) => Promise<unknown> } } }).window.satz
  const real = bridge.invoke
  let release: (() => void) | undefined
  bridge.invoke = (channel, ...args) => channel === 'settings:update' && (args[0] as Prefs).cleanupPrompt
    ? new Promise(resolve => { release = () => { void real(channel, ...args).then(resolve) } })
    : real(channel, ...args)
  try {
    await type('cleanup-prompt', 'Keep every word and add punctuation.')
    await press('cleanup-try-button')
    assert.ok(release, 'the prompt save is pending')
    assert.equal(tries.length, 0)
    await choose('cleanup-provider', 'groq')
    release()
    await settle()
    const started = tries.length
    for (const pending of tries) pending.resolve(answer('Old provider answer'))
    await settle()
    assert.equal(started, 0, 'a Try for the provider left behind must never start')
    assert.equal(shownResult(), undefined)
  } finally { bridge.invoke = real }
})

test('a Try whose call is rejected says so in German too, and a rejected cancel is not an unhandled rejection', async () => {
  await open({ language: 'de' })
  await press('cleanup-try-button')
  tries[0].reject(new Error('gone'))
  await settle()
  assert.match(page(), /Das Ausprobieren ist fehlgeschlagen\./)
  // Cancel throwing in the app: nothing may escape the page.
  const bridge = (globalThis as unknown as { window: { satz: { invoke: (channel: string, ...args: unknown[]) => Promise<unknown> } } }).window.satz
  const real = bridge.invoke
  bridge.invoke = (channel, ...args) => (channel === 'cleanup:cancel-try' ? Promise.reject(new Error('no handler')) : real(channel, ...args))
  const unhandled: unknown[] = []
  const listener = (reason: unknown) => { unhandled.push(reason) }
  process.on('unhandledRejection', listener)
  try {
    await press('cleanup-try-button')
    await press('cleanup-try-button')
    await choose('cleanup-provider', 'groq')
    await settle()
  } finally { process.off('unhandledRejection', listener); bridge.invoke = real }
  assert.deepEqual(unhandled, [])
})

// MARK: - The original with the history off

const note = () => textOf(byId('cleanup-original-note')!)

test('MS3-02: with the history on, the line under the switch promises the original; with it off, it says it is not kept', async () => {
  await open({ historyLimit: 50 })
  assert.match(note(), /The original stays in the history\./)
  assert.ok(!note().includes('not kept'))
  await open({ historyLimit: 0 })
  assert.match(note(), /History is off: the original is not kept\./)
  assert.ok(!note().includes('stays in the history'))
  await open({ historyLimit: 0, language: 'de' })
  assert.match(note(), /Der Verlauf ist aus: das Original wird nicht aufbewahrt\./)
  assert.ok(!note().includes('bleibt im Verlauf'))
  await open({ historyLimit: 200, language: 'de' })
  assert.match(note(), /Das Original bleibt im Verlauf\./)
})

test('MS3-02: switching the history off or on changes the line at once', async () => {
  await open({ historyLimit: 50 })
  await choose('history-limit', '0')
  assert.equal(prefs.historyLimit, 0)
  assert.match(note(), /History is off: the original is not kept\./)
  await choose('history-limit', '10')
  assert.match(note(), /The original stays in the history\./)
})

import assert from 'node:assert/strict'
import path from 'node:path'
import { test } from 'node:test'
import vm from 'node:vm'
import { buildSync } from 'esbuild'

/**
 * Codex's third audit of 14 October 2026, I-1, the card's side: the card page
 * itself (src/renderer/card.ts, bundled as build.mjs does) against stand-ins
 * for the DOM, Web Audio and the app. A microphone that went away reads
 * "Mikrofon getrennt" / "Microphone lost" with Weitersprechen on; an audio
 * context that the system closes is told to the main process as a loss, with
 * the start it answered; the context satz closes itself is not. Fails on the
 * code before the fix.
 */

// MARK: - A DOM as small as the card needs

class FakeElement {
  [property: string]: unknown
  children: FakeElement[] = []
  textContent = ''
  innerHTML = ''
  className = ''
  title = ''
  disabled = false
  style: Record<string, string> = {}
  dataset: Record<string, string> = {}
  private classes = new Set<string>()
  classList = {
    toggle: (name: string, on?: boolean) => { if (on ?? !this.classes.has(name)) this.classes.add(name); else this.classes.delete(name) },
    contains: (name: string) => this.classes.has(name),
  }
  constructor(readonly tag: string, readonly id = '') {}
  append(...nodes: FakeElement[]) { this.children.push(...nodes) }
  replaceChildren(...nodes: FakeElement[]) { this.children = nodes }
  querySelector() { return null }
  querySelectorAll() { return [] }
  addEventListener() {}
  contains(node: unknown) { return node === this }
  getBoundingClientRect() { return { left: 0, top: 0, width: 0, height: 0 } }
  get lastElementChild(): FakeElement | null { return this.children.at(-1) ?? null }
}

const words = (node: FakeElement): string[] => [node.textContent, ...node.children.flatMap(words)].filter(Boolean)
const classes = (node: FakeElement): string[] => [node.className, ...node.children.flatMap(classes)].filter(Boolean)

class Track extends EventTarget {
  readyState: 'live' | 'ended' = 'live'
  stop() { this.readyState = 'ended' }
}

function loadCard(options: { trackEnded?: boolean } = {}) {
  const elements = new Map(['card', 'text', 'rule', 'middle', 'mic', 'eye', 'close', 'strip'].map(id => [id, new FakeElement(id === 'mic' || id === 'eye' || id === 'close' ? 'button' : 'div', id)]))
  const sent: unknown[][] = []
  const listeners = new Map<string, (value: unknown) => void>()
  const contexts: FakeAudioContext[] = []
  class FakeAudioContext extends EventTarget {
    state = 'running'
    onstatechange: (() => void) | null = null
    closedBySatz = false
    audioWorklet = { addModule: async () => {} }
    constructor() { super(); contexts.push(this) }
    createMediaStreamSource() { return { connect() {} } }
    async close() { this.closedBySatz = true; this.systemCloses() }
    /** The state goes to closed and the page is told, whoever closed it. */
    systemCloses() { this.state = 'closed'; this.onstatechange?.() }
  }
  class FakeWorkletNode { port = { onmessage: null as unknown }; onprocessorerror: (() => void) | null = null }
  const context = vm.createContext({
    window: { satz: {
      send: (channel: string, ...args: unknown[]) => { sent.push([channel, ...args]) },
      on: (channel: string, listener: (value: unknown) => void) => { listeners.set(channel, listener) },
      invoke: async () => undefined,
    } },
    document: {
      getElementById: (id: string) => elements.get(id) ?? null,
      createElement: (tag: string) => new FakeElement(tag),
      addEventListener() {},
      documentElement: { lang: '' },
    },
    navigator: { mediaDevices: { getUserMedia: async () => {
      const track = new Track()
      if (options.trackEnded) track.readyState = 'ended'
      return { getTracks: () => [track] }
    } } },
    AudioContext: FakeAudioContext,
    AudioWorkletNode: FakeWorkletNode,
    URL: { createObjectURL: () => 'blob:tap', revokeObjectURL() {} },
    Blob: class {},
    ResizeObserver: class { observe() {} },
    Node: { TEXT_NODE: 3 },
    setInterval: () => 0,
    setTimeout, queueMicrotask, Promise, Error, Object, JSON, Math, Set, Map, EventTarget, Event,
  })
  const bundle = buildSync({ entryPoints: [path.join(__dirname, '..', 'src', 'renderer', 'card.ts')], bundle: true, write: false, format: 'iife', platform: 'browser', target: 'es2023' })
  vm.runInContext(bundle.outputFiles[0].text, context)
  const middle = elements.get('middle')!, card = elements.get('card')!, mic = elements.get('mic')!
  return {
    sent, contexts,
    show(phase: Record<string, unknown>, language: 'de' | 'en' = 'en') {
      listeners.get('card:state')!({ phase, runs: [], levels: new Array(32).fill(0), showsText: true, hasRealText: false, bright: true, language })
    },
    emit(channel: string, value: unknown) { listeners.get(channel)!(value) },
    middle: () => ({ words: words(middle), classes: classes(middle) }),
    isStatus: () => card.classList.contains('status'),
    mic: () => ({ disabled: mic.disabled, title: mic.title }),
  }
}

const settle = () => new Promise(resolve => setTimeout(resolve, 0))

test('I-1 card: paused because the microphone went away reads "Microphone lost", with Continue on', () => {
  const card = loadCard()
  card.show({ kind: 'paused', lost: true })
  assert.deepEqual(card.middle().words, ['Microphone lost'])
  assert.ok(card.middle().classes.includes('warning'), 'marked as a warning')
  assert.ok(!card.middle().classes.includes('wave'), 'no wave for a microphone that is not there')
  assert.equal(card.isStatus(), true, 'wide enough for the words, as other statuses')
  assert.deepEqual(card.mic(), { disabled: false, title: 'Continue' })
  card.show({ kind: 'paused', lost: true }, 'de')
  assert.deepEqual(card.middle().words, ['Mikrofon getrennt'])
  assert.equal(card.mic().title, 'Weitersprechen')
  // An ordinary pause is as it was.
  card.show({ kind: 'paused' })
  assert.deepEqual(card.middle().words, ['Paused'])
  assert.ok(card.middle().classes.some(name => name.startsWith('wave')))
  assert.equal(card.isStatus(), false)
})

test('I-1 card: an audio context the system closes is told as lost, with the start it answered; one satz closes is not', async () => {
  const card = loadCard()
  card.emit('rec:start', 7); await settle()
  assert.deepEqual(card.sent.filter(([channel]) => channel === 'rec:started'), [['rec:started', 7]])
  card.contexts[0].systemCloses(); await settle()
  assert.deepEqual(card.sent.filter(([channel]) => channel === 'rec:lost'), [['rec:lost', 7]])
  // The next start opens a new one; stopping it closes the context, which is no loss.
  card.emit('rec:start', 8); await settle()
  assert.equal(card.contexts.length, 2)
  card.emit('rec:stop', null); await settle()
  assert.equal(card.contexts[1].closedBySatz, true)
  assert.deepEqual(card.sent.filter(([channel]) => channel === 'rec:lost'), [['rec:lost', 7]])
})

test('I-1 card: a microphone already gone when it opens fails the start in the card\'s language', async () => {
  const card = loadCard({ trackEnded: true })
  card.show({ kind: 'starting' }, 'de')
  card.emit('rec:start', 3); await settle()
  assert.deepEqual(card.sent.filter(([channel]) => channel === 'rec:started'), [['rec:started', 3, 'Mikrofon getrennt']])
  assert.equal(card.contexts[0].closedBySatz, true, 'what was opened is let go')
})

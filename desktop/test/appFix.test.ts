import assert from 'node:assert/strict'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import Module from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { PassThrough } from 'node:stream'
import { mock, test } from 'node:test'
import { shortcutHint } from '../src/core/browse'
import { HISTORY_LIMITS, KEEP_ALL } from '../src/core/historyLimits'
import { setLanguage } from '../src/core/language'
import { describe, listURL } from '../src/core/models'
import { applyReplacements, standardReplacements } from '../src/core/replacements'
import { fit, germanFunctionWords, lowerFirstWordIfSafe } from '../src/core/textFitting'
import { Session } from '../src/core/session'
import { ClipboardHandback, type ClipboardPort } from '../src/main/clipboardHandback'
import { makeDelivery } from '../src/main/delivery'
import { WindowsForeground, X11Foreground } from '../src/main/foreground'
import { hookEvents } from '../src/main/keyboard'
import { ModelLists } from '../src/main/modelLists'
import { PowerShellHelper, RETRY_AFTER, START_TIMEOUT } from '../src/main/powershell'
import { LoadAfterBlur } from '../src/renderer/deferredLoad'
import { Microphone, type MicrophoneParts, type Tap } from '../src/renderer/microphone'
import { FakeSource, decode, deferred, flush, settle } from './sessionHarness'

setLanguage('en')
const root = path.join(__dirname, '..')

// MARK: - Overlapping pastes give the clipboard back once

/** A clipboard made of a variable: items, each a list of [type, data]. */
class MemoryClipboard implements ClipboardPort<[string, string][][]> {
  items: [string, string][][] = []
  text(value: string) { this.items = [[['text/plain', value]]] }
  /** What the user sees on it when it is plain text. */
  get shown() { return this.items.length === 0 ? '' : this.items.map(item => item.map(([, data]) => data).join('+')).join('|') }
  async save() { return this.items.map(item => item.map(entry => [...entry] as [string, string])) }
  isEmpty(saved: [string, string][][]) { return saved.length === 0 }
  async restore(saved: [string, string][][]) { this.items = saved.map(item => item.map(entry => [...entry] as [string, string])) }
  clear() { this.items = [] }
  async writeText(value: string) { this.text(value) }
  async holdsOnly(value: string) {
    return this.items.length === 1 && this.items[0].every(([type]) => type.startsWith('text/plain')) && this.items[0].map(([, data]) => data).join('') === value
  }
}

/** Timers that run when the test says so, also the ones cleared since (a stale callback must be harmless). */
function manualTimers() {
  const timers: { run: () => void; ms: number; cleared: boolean }[] = []
  return {
    timers,
    set: (run: () => void, ms: number) => { timers.push({ run, ms, cleared: false }); return timers.length - 1 },
    clear: (handle: unknown) => { timers[handle as number].cleared = true },
    /** Runs one timer and lets what it started finish. */
    async fire(index: number) { timers[index].run(); await flush() },
    /** Runs the ones not cleared, in order. */
    async fireDue() { for (const timer of timers) if (!timer.cleared) { timer.run(); await flush() } },
  }
}

const pasted = async () => ({ pasted: true })
/** One turn of the event loop: streams deliver on it, which promises alone never let them do. */
const turn = () => new Promise<void>(resolve => setImmediate(resolve))

function clipboardSetup(initial: string | null = 'original') {
  const clipboard = new MemoryClipboard()
  if (initial !== null) clipboard.text(initial)
  const timers = manualTimers()
  const handback = new ClipboardHandback(clipboard, 1000, timers)
  return { clipboard, timers, handback }
}

test('one paste: the clipboard comes back a second after the keystroke', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript', pasted, false)
  assert.equal(clipboard.shown, 'transcript')
  assert.equal(timers.timers[0].ms, 1000)
  await timers.fire(0)
  assert.equal(clipboard.shown, 'original')
})

test('two pastes in a row give back the clipboard from before both, whichever timer runs', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript 1', pasted, false)
  await handback.deliver('transcript 2', pasted, false)
  assert.equal(clipboard.shown, 'transcript 2')
  // Every timer, the first one's (cleared) too, in the order they were set: the old code ended at "transcript 1".
  await timers.fire(0)
  await timers.fire(1)
  assert.equal(clipboard.shown, 'original')
})

test('the hand-back of an earlier paste does nothing when a later one is due: the clipboard stays until the last paste has had its second', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  // The same words twice: the clipboard still looks like "just the transcript" to the first timer.
  await handback.deliver('same words', pasted, false)
  await handback.deliver('same words', pasted, false)
  await timers.fire(0)
  assert.equal(clipboard.shown, 'same words')
  await timers.fire(1)
  assert.equal(clipboard.shown, 'original')
})

test('something the user copies between two pastes is what comes back, not the clipboard from before', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript 1', pasted, false)
  clipboard.text('new copy')
  await handback.deliver('transcript 2', pasted, false)
  await timers.fireDue()
  assert.equal(clipboard.shown, 'new copy')
})

test('something copied after the last paste is left alone, also the same words with their formatting', async () => {
  for (const copied of [[['text/plain', 'copied']], [['text/plain', 'transcript'], ['text/html', '<b>transcript</b>']]] as [string, string][][]) {
    const { clipboard, timers, handback } = clipboardSetup()
    await handback.deliver('transcript', pasted, false)
    clipboard.items = [copied]
    await timers.fireDue()
    assert.deepEqual(clipboard.items, [copied])
  }
})

test('an empty clipboard is empty again afterwards, also after a burst', async () => {
  const { clipboard, timers, handback } = clipboardSetup(null)
  await handback.deliver('a', pasted, false)
  await handback.deliver('b', pasted, false)
  await timers.fireDue()
  assert.equal(clipboard.items.length, 0)
})

test('a clipboard with several forms comes back in all of them', async () => {
  const { clipboard, timers, handback } = clipboardSetup(null)
  clipboard.items = [[['text/plain', 'plain'], ['text/html', '<i>plain</i>']], [['image/png', 'bytes']]]
  const before = JSON.stringify(clipboard.items)
  await handback.deliver('one', pasted, false)
  await handback.deliver('two', pasted, false)
  await timers.fireDue()
  assert.equal(JSON.stringify(clipboard.items), before)
})

test('a paste that did not happen leaves the transcript on the clipboard, and no earlier hand-back takes it away', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript 1', pasted, false)
  await handback.deliver('transcript 2', async () => ({ pasted: false, reason: 'nowhere to paste' }), false)
  await timers.fireDue()
  await timers.fire(0)
  assert.equal(clipboard.shown, 'transcript 2')
})

test('keeping the transcript on the clipboard sets no timer and cancels the one before', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript 1', pasted, false)
  await handback.deliver('transcript 2', pasted, true)
  await timers.fire(0)
  assert.equal(timers.timers.length, 1)
  assert.equal(clipboard.shown, 'transcript 2')
})

test('pastes that overlap run one at a time: each keystroke finds its own text on the clipboard', async () => {
  const { clipboard, handback } = clipboardSetup()
  const seen: string[] = []
  const slow = (label: string) => async () => { seen.push(`${label}:${clipboard.shown}`); await flush(); seen.push(`${label} done:${clipboard.shown}`); return { pasted: true } }
  await Promise.all([handback.deliver('one', slow('first'), false), handback.deliver('two', slow('second'), false)])
  assert.deepEqual(seen, ['first:one', 'first done:one', 'second:two', 'second done:two'])
})

test('a clipboard that refuses the text does not cost the clipboard from before the burst', async () => {
  const { clipboard, timers, handback } = clipboardSetup()
  await handback.deliver('transcript 1', pasted, false)
  const refuse = clipboard.writeText.bind(clipboard)
  clipboard.writeText = async () => { throw new Error('clipboard busy') }
  await assert.rejects(handback.deliver('transcript 2', pasted, false), /busy/)
  clipboard.writeText = refuse
  await timers.fireDue()
  assert.equal(clipboard.shown, 'original', 'the first paste is still handed back')
})

test('a paste that throws does not block the ones after it', async () => {
  const { clipboard, handback } = clipboardSetup()
  await assert.rejects(handback.deliver('one', async () => { throw new Error('boom') }, false), /boom/)
  await handback.deliver('two', pasted, false)
  assert.equal(clipboard.shown, 'two')
})

/** paste.ts with an Electron made of the same variable, loaded the way the app loads it. */
function loadPaste(clipboard: unknown, Item: unknown) {
  const internals = Module as unknown as { _load(request: string, ...rest: unknown[]): unknown }
  const real = internals._load
  internals._load = function (this: unknown, request: string, ...rest: unknown[]) { return request === 'electron' ? { clipboard, ClipboardItem: Item } : real.call(this, request, ...rest) }
  const file = require.resolve('../src/main/paste')
  delete require.cache[file]
  try { return require('../src/main/paste') as typeof import('../src/main/paste') } finally { internals._load = real; delete require.cache[file] }
}

test('paste.ts hands the clipboard back after a second, not 600 ms, and after overlapping pastes gives back the first one', async () => {
  let text = 'original clipboard'
  class Item { types: string[]; constructor(private payload: Record<string, string>) { this.types = Object.keys(payload) } async getType(type: string) { return this.payload[type] } }
  const clipboard = {
    read: async () => [new Item({ 'text/plain': text })],
    readText: async () => text,
    writeText: (value: string) => { text = value },
    write: async (items: Item[]) => { text = await items[0].getType('text/plain') },
    clear: () => { text = '' },
  }
  mock.timers.enable({ apis: ['setTimeout'] })
  try {
    const { deliver } = loadPaste(clipboard, Item)
    await deliver('first transcript', () => {}, false)
    await deliver('second transcript', () => {}, false)
    mock.timers.tick(999); await flush()
    assert.equal(text, 'second transcript', 'still there after 999 ms: a slow app can take the paste until then')
    mock.timers.tick(1); await flush()
    assert.equal(text, 'original clipboard')
  } finally { mock.timers.reset() }
})

// MARK: - The text goes to the window its dictation started in

test('each dictation keeps its own paste target: a dictation started while the last text is pasted does not take it', async () => {
  const pause = deferred(), transcription = deferred()
  const restored: string[] = [], pastedTexts: string[] = []
  const deliverInto = makeDelivery({
    records: false,
    windows: { restore: async window => { restored.push(window); return true }, isTerminal: async () => false },
    paste: async text => { pastedTexts.push(text); return { pasted: true } },
    keyTap: () => {},
    writeClipboard: () => {},
    keepsOnClipboard: () => false,
    addHistory: () => {},
    delivered: () => {},
    log: () => {},
    sleep: () => pause.promise,
  })
  // The wiring of main.ts: the window is noted when a dictation begins and travels with its text.
  let target: Promise<string | null> = Promise.resolve(null)
  const windowsAtBegin = ['window A', 'window B']
  let begins = 0
  const sources: FakeSource[] = []
  const session = new Session({
    makeSource: () => { const source = new FakeSource(['first dictated message', 'second words'][sources.length]); sources.push(source); return source },
    transcribe: async samples => { await transcription.promise; return decode(samples) },
    replacements: () => [], missing: () => null, endpointMissing: () => false, triggerMode: () => 'tap',
    hasSpeech: samples => samples.length > 0,
    deliver: text => deliverInto(text, target),
  })
  session.onBegin = () => { target = Promise.resolve(windowsAtBegin[begins++]) }
  try {
    session.press(); await settle()
    sources[0].say()
    session.press(); await settle()
    transcription.resolve(); await settle()
    // The 120 ms are not over; the next dictation starts in another window.
    session.press(); await settle()
    assert.equal(sources.length, 2)
    pause.resolve(); await settle()
    assert.deepEqual(restored, ['window A'])
    assert.deepEqual(pastedTexts, ['first dictated message'])
  } finally { session.dispose() }
})

test('main.ts hands the target to the delivery together with the text', () => {
  const main = fs.readFileSync(path.join(root, 'src', 'main', 'main.ts'), 'utf8')
  // The line before the delivery only tells the cleaner whether this dictation was cleaned up (the test mode's state).
  assert.match(main, /deliver:\s*\(text,\s*cleanup\)\s*=>\s*\{[^}]*return deliverInto\(text,\s*target,\s*cleanup\)/)
  // Cleanup's state is that of the dictation delivered: none when this one went out without the model.
  assert.match(main, /cleaner\.delivered\(cleanup !== undefined\)/)
})

test('a window that would not come back puts the text on the clipboard, and the history knows it was not pasted', async () => {
  const written: string[] = [], history: [string, boolean][] = []
  const deliverInto = makeDelivery({
    records: false,
    windows: { restore: async () => false, isTerminal: async () => false },
    paste: async () => { throw new Error('must not paste') },
    keyTap: () => {}, writeClipboard: text => { written.push(text) }, keepsOnClipboard: () => false,
    addHistory: (text, ok) => { history.push([text, ok]) }, delivered: () => {}, log: () => {}, sleep: async () => {},
  })
  const outcome = await deliverInto('hello', Promise.resolve('window A'))
  assert.equal(outcome.pasted, false)
  assert.deepEqual(written, ['hello'])
  assert.deepEqual(history, [['hello', false]])
})

test('test mode records the text and pastes nothing', async () => {
  const history: [string, boolean][] = [], delivered: string[] = []
  const deliverInto = makeDelivery({
    records: true,
    windows: { restore: async () => { throw new Error('no window') }, isTerminal: async () => false },
    paste: async () => { throw new Error('must not paste') },
    keyTap: () => {}, writeClipboard: () => {}, keepsOnClipboard: () => false,
    addHistory: (text, ok) => { history.push([text, ok]) }, delivered: text => { delivered.push(text) }, log: () => {},
  })
  assert.deepEqual(await deliverInto('heard', Promise.resolve(null)), { pasted: true })
  assert.deepEqual(delivered, ['heard'])
  assert.deepEqual(history, [['heard', true]])
})

// MARK: - A microphone that arrives after the main process gave up

function fakeMicrophone() {
  const log: string[] = []
  const requests: ReturnType<typeof deferred<MediaStream>>[] = []
  let streams = 0
  const parts: MicrophoneParts = {
    getUserMedia: () => { const request = deferred<MediaStream>(); requests.push(request); return request.promise },
    openTap: async () => ({ connect: () => { log.push('connected') }, close: () => { log.push('tap closed') } } satisfies Tap),
  }
  const stream = () => { const id = ++streams; return { id, getTracks: () => [{ stop: () => { log.push(`stream ${id} stopped`) } }] } as unknown as MediaStream }
  return { parts, requests, stream, log }
}

test('a microphone that opens after the main process gave up and said stop is let go again at once', async () => {
  const { parts, requests, stream, log } = fakeMicrophone()
  const microphone = new Microphone(parts, () => {})
  const starting = microphone.start()
  microphone.stop() // the main process: 15 s without an answer
  requests[0].resolve(stream())
  assert.equal(await starting, false, 'nobody to answer')
  assert.deepEqual(log, ['stream 1 stopped'], 'let go before an audio context was even made for it')
})

test('a microphone stopped while its audio context was still being set up is let go as well', async () => {
  const log: string[] = []
  const tap = deferred<Tap>()
  const stream = { getTracks: () => [{ stop: () => { log.push('stream stopped') } }] } as unknown as MediaStream
  const microphone = new Microphone({ getUserMedia: async () => stream, openTap: () => tap.promise }, () => {})
  const starting = microphone.start()
  await flush()
  microphone.stop()
  tap.resolve({ connect: () => { log.push('connected') }, close: () => { log.push('tap closed') } })
  assert.equal(await starting, false)
  assert.deepEqual(log, ['stream stopped', 'tap closed'])
})

test('a microphone that opens in time is connected and stays until stop', async () => {
  const { parts, requests, stream, log } = fakeMicrophone()
  const microphone = new Microphone(parts, () => {})
  const starting = microphone.start()
  requests[0].resolve(stream())
  assert.equal(await starting, true)
  assert.deepEqual(log, ['connected'])
  microphone.stop()
  assert.deepEqual(log, ['connected', 'stream 1 stopped', 'tap closed'])
})

test('a late stale microphone never touches the one that is open', async () => {
  const { parts, requests, stream, log } = fakeMicrophone()
  const microphone = new Microphone(parts, () => {})
  const first = microphone.start()
  microphone.stop()
  const second = microphone.start()
  requests[1].resolve(stream()) // the second one opens first
  assert.equal(await second, true)
  requests[0].resolve(stream()) // the first arrives late
  assert.equal(await first, false)
  assert.deepEqual(log, ['connected', 'stream 2 stopped'], 'only the late stream is let go (ids count in the order the streams were made)')
  assert.equal(log.filter(entry => entry === 'connected').length, 1)
})

test('a microphone start that fails lets go of what it had opened and says why', async () => {
  const { parts, requests, log } = fakeMicrophone()
  const microphone = new Microphone(parts, () => {})
  const starting = microphone.start()
  requests[0].reject(Object.assign(new Error('denied'), { name: 'NotAllowedError' }))
  await assert.rejects(starting, /denied/)
  assert.deepEqual(log, [])
})

// MARK: - A PowerShell that refuses its script

function fakeChild(behaviour: (child: ChildProcessWithoutNullStreams & { stdout: PassThrough; stderr: PassThrough; stdin: PassThrough }) => void) {
  const spawned: ChildProcessWithoutNullStreams[] = []
  const spawn = () => {
    const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough(), stdin: new PassThrough(),
      kill() { queueMicrotask(() => child.emit('exit', null)); return true } }) as unknown as ChildProcessWithoutNullStreams & { stdout: PassThrough; stderr: PassThrough; stdin: PassThrough }
    spawned.push(child)
    behaviour(child)
    return child
  }
  return { spawn, spawned }
}

/** Answers every line with "ok <line>" once it has said "ready". */
const working = (child: { stdout: PassThrough; stdin: PassThrough }) => {
  child.stdout.write('ready\n')
  child.stdin.on('data', chunk => { for (const line of String(chunk).split('\r\n').filter(Boolean)) child.stdout.write(`ok ${line}\n`) })
}
/** What Constrained Language Mode does to the Add-Type script: it dies at once. */
const refused = (child: ChildProcessWithoutNullStreams & { stderr: PassThrough }) => {
  setImmediate(() => { child.stderr.write('Add-Type : Cannot add type. Definition of new types is not supported in this language mode.\n'); child.emit('exit', 1) })
}

test('a PowerShell that refuses the script is not started again for every call', async () => {
  const { spawn, spawned } = fakeChild(refused)
  let clock = 1_000_000
  const log: string[] = []
  const helper = new PowerShellHelper('script', 'window helper', message => log.push(message), spawn, () => clock)
  await assert.rejects(helper.ask('current', 3000))
  assert.equal(spawned.length, 1)
  for (let call = 0; call < 5; call++) await assert.rejects(helper.ask('current', 3000), /unavailable/)
  assert.equal(spawned.length, 1, 'five more calls, no new PowerShell')
  assert.equal(log.filter(line => line.includes('left alone')).length, 1, 'said once')
  clock += RETRY_AFTER - 1
  await assert.rejects(helper.ask('current', 3000), /unavailable/)
  assert.equal(spawned.length, 1)
  clock += 2
  await assert.rejects(helper.ask('current', 3000))
  assert.equal(spawned.length, 2, 'tried again after the wait')
})

test('a PowerShell that works serves every call from one process', async () => {
  const { spawn, spawned } = fakeChild(working)
  const helper = new PowerShellHelper('script', 'window helper', () => {}, spawn)
  assert.equal(await helper.ask('current', 3000), 'ok current')
  assert.equal(await helper.ask('focus 5', 3000), 'ok focus 5')
  assert.equal(spawned.length, 1)
})

test('a PowerShell that never says ready is given up on, killed, and left alone', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  try {
    const { spawn, spawned } = fakeChild(() => {})
    const log: string[] = []
    const helper = new PowerShellHelper('script', 'window helper', message => log.push(message), spawn)
    const asking = helper.ask('current', 3000)
    const result = assert.rejects(asking, /did not start/)
    mock.timers.tick(START_TIMEOUT); await flush()
    await result
    assert.equal(spawned.length, 1)
    await assert.rejects(helper.ask('current', 3000), /unavailable/)
    assert.equal(spawned.length, 1)
    assert.ok(log.some(line => line.includes('did not start')))
  } finally { mock.timers.reset() }
})

test('an answer that came too late is not given to the next call', async () => {
  let out!: PassThrough
  const { spawn } = fakeChild(child => { child.stdout.write('ready\n'); out = child.stdout })
  const helper = new PowerShellHelper('script', 'window helper', () => {}, spawn)
  mock.timers.enable({ apis: ['setTimeout'] })
  try {
    const timedOut = assert.rejects(helper.ask('current', 3000), /no answer/)
    await turn(); await turn() // "ready" is read, the command is written
    mock.timers.tick(3000)
    await timedOut
    const next = helper.ask('focus 7', 3000)
    await turn()
    out.write('late answer to current\n')
    out.write('answer to focus\n')
    assert.equal(await next, 'answer to focus')
  } finally { mock.timers.reset() }
})

test('the window helper answers "no window, go on" when PowerShell is unavailable, without a log line per call', async () => {
  const { spawn } = fakeChild(refused)
  const log: string[] = []
  const windows = new WindowsForeground(message => log.push(message), new PowerShellHelper('script', 'window helper', message => log.push(message), spawn))
  assert.equal(await windows.current(), null)
  assert.equal(await windows.restore('123'), true, 'the text is not held back')
  assert.equal(await windows.restore('123'), true)
  assert.equal(log.filter(line => line.startsWith('window helper: window helper')).length, 0)
  assert.equal(log.filter(line => line.includes('left alone')).length, 1)
})

test('the window helper maps 0 to no window and keeps an id', async () => {
  const answers: Record<string, string> = { current: '0' }
  const { spawn } = fakeChild(child => {
    child.stdout.write('ready\n')
    child.stdin.on('data', chunk => { for (const line of String(chunk).split('\r\n').filter(Boolean)) child.stdout.write((answers[line] ?? 'ok') + '\n') })
  })
  const windows = new WindowsForeground(() => {}, new PowerShellHelper('script', 'window helper', () => {}, spawn))
  assert.equal(await windows.current(), null)
  answers.current = '131074'
  assert.equal(await windows.current(), '131074')
  assert.equal(await windows.restore('131074'), true)
})

// MARK: - X11

test('X11: no active window (0x0) is no target, a real id is kept', async () => {
  const xprop = (id: string) => async (command: string) => (command === 'xprop' ? `_NET_ACTIVE_WINDOW(WINDOW): window id # ${id}` : null)
  assert.equal(await new X11Foreground(xprop('0x0')).current(), null)
  assert.equal(await new X11Foreground(xprop('0x00000000')).current(), null)
  assert.equal(await new X11Foreground(xprop('0x4a00007')).current(), '0x4a00007')
  assert.equal(await new X11Foreground(async () => null).current(), null)
})

test('X11: the window the dictation started in comes back with xdotool, and a window that is gone says so', async () => {
  const calls: string[] = []
  let active = '0x1'
  const run = async (command: string, args: string[]) => {
    calls.push(`${command} ${args.join(' ')}`)
    if (command === 'xprop') return `window id # ${active}`
    if (command === 'xdotool') { active = '0x2a'; return '' }
    return null
  }
  assert.equal(await new X11Foreground(run).restore('0x2a'), true)
  assert.ok(calls.some(call => call.startsWith('xdotool windowactivate --sync 42')))
  assert.equal(await new X11Foreground(async (command: string) => (command === 'xprop' ? 'window id # 0x1' : null)).restore('0x2a'), false)
})

// MARK: - The keyboard hook

test('Escape with the left Ctrl (Start menu, Task Manager) does not discard a dictation; with the right Ctrl it does', () => {
  const keys = { CtrlRight: 3613, Escape: 1 }
  const seen: string[] = []
  const events = hookEvents({
    trigger: down => seen.push(`trigger ${down}`), other: () => seen.push('other'), escape: withTrigger => seen.push(`escape ${withTrigger}`), log: () => {},
  }, keys)
  // Left Ctrl is down: the hook says ctrlKey, but this is not the right Ctrl.
  events.keydown({ keycode: 29 })
  events.keydown({ keycode: keys.Escape })
  assert.deepEqual(seen, ['other', 'other', 'escape false'])
  seen.length = 0
  events.keydown({ keycode: keys.CtrlRight })
  events.keydown({ keycode: keys.Escape })
  events.keyup({ keycode: keys.CtrlRight })
  events.keydown({ keycode: keys.Escape })
  assert.deepEqual(seen, ['trigger true', 'other', 'escape true', 'trigger false', 'other', 'escape false'])
})

// MARK: - Provider lists

test('a provider that failed is not asked again for every redraw of Settings, but after ten minutes', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lists-'))
  try {
    let asked = 0
    let clock = Date.now()
    const fetcher = (async () => { asked++; return new Response('busy', { status: 429 }) }) as unknown as typeof fetch
    const lists = new ModelLists(dir, () => null, () => {}, () => {}, fetcher, () => clock)
    for (let draw = 0; draw < 20; draw++) { lists.refresh('openrouter'); await flush(); await new Promise(resolve => setImmediate(resolve)) }
    assert.equal(asked, 1, 'twenty redraws, one request')
    clock += 9 * 60_000
    lists.refresh('openrouter'); await new Promise(resolve => setImmediate(resolve))
    assert.equal(asked, 1)
    clock += 2 * 60_000
    lists.refresh('openrouter'); await new Promise(resolve => setImmediate(resolve))
    assert.equal(asked, 2, 'asked again after ten minutes')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a provider list that arrived is kept for a day and shown', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lists-'))
  try {
    let asked = 0
    const changed: string[] = []
    const body = { data: [{ id: 'acme/speech-1', name: 'Acme: Speech One' }] }
    const fetcher = (async () => { asked++; return new Response(JSON.stringify(body), { status: 200 }) }) as unknown as typeof fetch
    const lists = new ModelLists(dir, () => null, () => {}, () => changed.push('changed'), fetcher)
    lists.refresh('openrouter'); await new Promise(resolve => setImmediate(resolve)); await flush()
    assert.deepEqual(lists.get('openrouter').map(model => model.id), ['acme/speech-1'])
    lists.refresh('openrouter'); await new Promise(resolve => setImmediate(resolve))
    assert.equal(asked, 1)
    assert.equal(changed.length, 1)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('Local has no provider list to send: its models are cards', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-lists-'))
  try {
    assert.deepEqual(new ModelLists(dir, () => null, () => {}, () => {}).get('local'), [])
    assert.equal(listURL.local, null)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('a model the list does not know is not its own maker: the provider is', () => {
  assert.equal(describe('gpt-5-transcribe', 'openai').maker, 'OpenAI')
  assert.equal(describe('whisper-large-v4', 'groq').maker, 'Groq')
  assert.equal(describe('acme/speech-1', 'openrouter').maker, 'acme')
  assert.equal(describe('acme/speech-1', 'openrouter', 'Acme Labs: Speech One').maker, 'Acme Labs')
  assert.equal(describe('whisper-1', 'openai').maker, 'OpenAI')
})

// MARK: - Spoken punctuation, formal "Sie"

test('a mark the model wrote beside a spoken mark does not double it', () => {
  const german = standardReplacements('de')
  const english = standardReplacements('en')
  const said: [string, string][] = [
    ['Hast du morgen Zeit. Fragezeichen.', 'Hast du morgen Zeit?'],
    ['Das ist toll. Ausrufezeichen.', 'Das ist toll!'],
    ['Hast du morgen Zeit? Fragezeichen.', 'Hast du morgen Zeit?'],
    ['Wie geht es dir Fragezeichen?', 'Wie geht es dir?'],
    ['Das ist toll Ausrufezeichen!', 'Das ist toll!'],
    ['Hallo Peter. Doppelpunkt. Ich schreibe dir.', 'Hallo Peter: Ich schreibe dir.'],
    ['Hallo Peter, Doppelpunkt, ich schreibe dir.', 'Hallo Peter: ich schreibe dir.'],
  ]
  for (const [heard, written] of said) assert.equal(applyReplacements(german, heard), written, heard)
  assert.equal(applyReplacements(english, 'Are you free tomorrow. Question mark.'), 'Are you free tomorrow?')
  assert.equal(applyReplacements(english, 'Are you free tomorrow question mark?'), 'Are you free tomorrow?')
})

test('a spoken mark still starts a new sentence and keeps what follows', () => {
  const german = standardReplacements('de')
  assert.equal(applyReplacements(german, 'Wirklich Fragezeichen. Ja, wirklich.'), 'Wirklich? Ja, wirklich.')
  assert.equal(applyReplacements(german, 'Wirklich. Neue Zeile. Ja.'), 'Wirklich.\nJa.', 'a line break still keeps the full stop before it')
})

test('the formal Sie and Ihr keep their capital where a recording starts mid-sentence', () => {
  assert.equal(fit('Sie haben recht.', 'Ich glaube, dass', { location: 16, length: 0 }), ' Sie haben recht.')
  assert.equal(fit('Ihr Anliegen ist angekommen.', 'Vielen Dank für', { location: 15, length: 0 }), ' Ihr Anliegen ist angekommen.')
  assert.ok(!germanFunctionWords.has('sie') && !germanFunctionWords.has('ihr'))
  // The words that are safe to lower still are.
  assert.equal(lowerFirstWordIfSafe('Und dann ging es weiter.', 'Er kam, aber'), 'und dann ging es weiter.')
})

// MARK: - Fitting, at the boundaries

test('fit puts a space before the word after the spot, also before a digit, but not before a line break', () => {
  assert.equal(fit('Neu', 'AltWort', { location: 3, length: 0 }), ' Neu ')
  assert.equal(fit('Neu', 'Alt5', { location: 3, length: 0 }), ' Neu ')
  assert.equal(fit('Neu\n', 'AltWort', { location: 3, length: 0 }), ' Neu\n')
  // A space already there is not doubled.
  assert.equal(fit('Neu', 'Alt Wort', { location: 4, length: 0 }), 'Neu ')
})

test('fit keeps an acronym as it is and lowers only function words', () => {
  assert.equal(fit('IT department is closed.', 'Please ask the', { location: 14, length: 0 }), ' IT department is closed.')
  assert.equal(fit('The report is done.', 'I think', { location: 7, length: 0 }), ' the report is done.')
  assert.equal(fit('Alice Johnson called.', 'I think', { location: 7, length: 0 }), ' Alice Johnson called.')
})

test('fit does not glue an insertion into the word before it, nor after an opening quote or bracket', () => {
  assert.equal(fit('word', 'one', { location: 3, length: 0 }), ' word')
  assert.equal(fit('word', 'say (', { location: 5, length: 0 }), 'word')
  assert.equal(fit('Hallo', '', { location: 0, length: 0 }), 'Hallo')
})

// MARK: - Settings

test('the shortcut hint appears whenever the shortcut cannot start a dictation, on Wayland or not', () => {
  assert.equal(shortcutHint(true, false, 'en'), '')
  assert.equal(shortcutHint(true, true, 'de'), '')
  assert.match(shortcutHint(false, true, 'en'), /Wayland[\s\S]*satz --toggle[\s\S]*usermod/)
  assert.match(shortcutHint(false, false, 'en'), /keyboard hook[\s\S]*satz --toggle/)
  assert.match(shortcutHint(false, false, 'de'), /Tastatur-Hook[\s\S]*satz --toggle/)
  assert.doesNotMatch(shortcutHint(false, false, 'en') + shortcutHint(false, false, 'de') + shortcutHint(false, true, 'de'), /—/)
})

test('a field waited for gets one reload when it is left, however many changes arrived meanwhile', () => {
  const afterBlur = new LoadAfterBlur()
  const field = new EventTarget()
  let loads = 0
  for (let percent = 0; percent < 100; percent++) afterBlur.later(field, () => { loads++ })
  assert.equal(loads, 0, 'not under someone typing')
  field.dispatchEvent(new Event('blur'))
  assert.equal(loads, 1)
  afterBlur.later(field, () => { loads++ })
  field.dispatchEvent(new Event('blur'))
  assert.equal(loads, 2, 'the next time it is waited for again')
})

test('the history choices are one list, from "off" to "all"', () => {
  assert.deepEqual(HISTORY_LIMITS, [...HISTORY_LIMITS].sort((a, b) => a - b))
  assert.equal(HISTORY_LIMITS[0], 0)
  assert.equal(HISTORY_LIMITS.at(-1), KEEP_ALL)
  const settings = fs.readFileSync(path.join(root, 'src', 'renderer', 'settings.ts'), 'utf8')
  assert.doesNotMatch(settings, /'100000'/)
})

test('the icon-only buttons in Settings have a name', () => {
  const settings = fs.readFileSync(path.join(root, 'src', 'renderer', 'settings.ts'), 'utf8')
  for (const symbol of ["'×'", "'+'"]) {
    for (const [, line] of settings.matchAll(new RegExp(`el\\('button', \\{([^}]*textContent: ${symbol}[^}]*)\\}`, 'g'))) assert.match(line, /title:/, `button ${symbol}`)
  }
})

// MARK: - The package

const packageJson = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))

test('the Windows exe keeps its name, version and icon: only the signing is off', () => {
  assert.equal(packageJson.build.win.signExecutable, false)
  assert.notEqual(packageJson.build.win.signAndEditExecutable, false, 'false here also switches off the resource editing that names the exe')
  assert.equal(packageJson.build.win.icon, 'assets/icon.png')
})

test('the packages leave out what the bundles never load, by electron-builder\'s own filter for dependencies', () => {
  // getNodeModuleFileMatcher takes only the "!" patterns of build.files for node_modules: the positive ones
  // list nothing there, so this is what decides which dependency files a package gets.
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { getNodeModuleFileMatcher } = require('app-builder-lib/out/fileMatcher') as {
    getNodeModuleFileMatcher(appDir: string, destination: string, macroExpander: (s: string) => string, options: unknown, packager: unknown): { createFilter(): (file: string, stat: unknown) => boolean }
  }
  const packager = { config: packageJson.build, debugLogger: { isEnabled: false, add() {} } }
  const filter = getNodeModuleFileMatcher(root, '/dest', s => s, packageJson.build.win, packager).createFilter()
  const ships = (file: string) => filter(path.join(root, file), { isDirectory: () => false, moduleFullFilePath: file })
  for (const unused of [
    'node_modules/onnxruntime-web/dist/ort.wasm.min.js', 'node_modules/@huggingface/transformers/dist/transformers.node.cjs', 'node_modules/sharp/lib/index.js',
    'node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.8.18.7.dylib', 'node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64-0.35.5.node',
    'node_modules/protobufjs/index.js', 'node_modules/@protobufjs/aspromise/index.js', 'node_modules/long/index.js', 'node_modules/flatbuffers/js/flatbuffers.js',
    'node_modules/sherpa-onnx-darwin-arm64/sherpa.node',
  ]) assert.equal(ships(unused), false, unused)
  // What is loaded from beside the bundles stays.
  for (const needed of ['node_modules/uiohook-napi/dist/index.js', 'node_modules/uiohook-napi/prebuilds/win32-x64/uiohook-napi.node', 'node_modules/node-gyp-build/index.js',
    'node_modules/onnxruntime-node/dist/index.js', 'node_modules/onnxruntime-common/dist/cjs/index.js']) assert.equal(ships(needed), true, needed)
})

test('the Whisper helper bundle needs nothing at run time but ONNX Runtime from beside it', { timeout: 60_000 }, async () => {
  // The same options as build.mjs (sourcemap off here: its sources would show up as requires).
  const { build } = await import('esbuild')
  const result = await build({
    entryPoints: [path.join(root, 'src', 'main', 'local-worker.ts')], bundle: true, write: false, logLevel: 'silent', target: 'es2023',
    platform: 'node', format: 'cjs', external: ['electron', 'onnxruntime-node', 'onnxruntime-common'], alias: { sharp: path.join(root, 'src', 'main', 'no-sharp.ts') },
  })
  const code = result.outputFiles[0].text
  const wanted = new Set([...code.matchAll(/\brequire\(\s*["']([^"']+)["']\s*\)/g)].map(match => match[1]).filter(name => !name.startsWith('.') && !name.startsWith('node:') && !Module.builtinModules.includes(name)))
  assert.deepEqual([...wanted].sort(), ['electron', 'onnxruntime-common', 'onnxruntime-node'].filter(name => wanted.has(name)))
  for (const unused of ['sharp', 'onnxruntime-web', '@huggingface/transformers', '@img/']) assert.ok(![...wanted].some(name => name.startsWith(unused)), unused)
})

test('each package keeps only its own keyboard hook library', () => {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { keepOnlyThisKeyboardHook } = require('../build/after-pack.cjs') as { keepOnlyThisKeyboardHook(context: unknown): void }
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const { Arch } = require('electron-builder') as { Arch: Record<string | number, string | number> }
  const make = (platform: string, arch: number) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-pack-'))
    const prebuilds = path.join(dir, 'resources', 'app.asar.unpacked', 'node_modules', 'uiohook-napi', 'prebuilds')
    for (const name of ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64', 'win32-arm64', 'win32-x64']) {
      fs.mkdirSync(path.join(prebuilds, name), { recursive: true })
      fs.writeFileSync(path.join(prebuilds, name, 'uiohook-napi.node'), name)
    }
    keepOnlyThisKeyboardHook({ appOutDir: dir, electronPlatformName: platform, arch })
    const kept = fs.readdirSync(prebuilds)
    fs.rmSync(dir, { recursive: true, force: true })
    return kept
  }
  assert.deepEqual(make('win32', Arch.x64 as number), ['win32-x64'])
  assert.deepEqual(make('win32', Arch.arm64 as number), ['win32-arm64'])
  assert.deepEqual(make('linux', Arch.arm64 as number), ['linux-arm64'])
  assert.deepEqual(make('linux', Arch.x64 as number), ['linux-x64'])
})

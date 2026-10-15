import assert from 'node:assert/strict'
import Module from 'node:module'
import { afterEach, test } from 'node:test'
import { ClipboardBackupError, ClipboardHandback, flushHandback, registerHandback, type ClipboardPort } from '../src/main/clipboardHandback'
import { makeDelivery } from '../src/main/delivery'
import { deferred, disposeAll, flush, phase, settle, setup as sessionSetup } from './sessionHarness'

afterEach(() => disposeAll())

// Codex bug hunt 14.10., F02: a clipboard that could not be read was taken
// for an empty one, so the paste wrote over it and the hand-back then cleared
// it. Also flushHandback(): the clipboard goes back when satz quits.

// MARK: - The hand-back itself

/** A clipboard made of a list, that can be made unreadable and keeps a log of what was done to it. */
class Board implements ClipboardPort<string[]> {
  items: string[] = []
  log: string[] = []
  unreadable = false
  /** The next this many holdsOnly() calls say "not just the transcript", as a read that fails does. */
  holdsFails = 0
  async save() {
    if (this.unreadable) throw new Error('clipboard busy')
    return [...this.items]
  }
  isEmpty(saved: string[]) { return saved.length === 0 }
  async restore(saved: string[]) { this.log.push('restore'); this.items = [...saved] }
  clear() { this.log.push('clear'); this.items = [] }
  async writeText(text: string) { this.log.push(`write:${text}`); this.items = [text] }
  async holdsOnly(text: string) {
    if (this.holdsFails > 0) { this.holdsFails--; return false }
    return this.items.length === 1 && this.items[0] === text
  }
}

/** Timers that run when the test says so. */
function manualTimers() {
  const timers: { run: () => void; ms: number; cleared: boolean }[] = []
  return {
    timers,
    set: (run: () => void, ms: number) => { timers.push({ run, ms, cleared: false }); return timers.length - 1 },
    clear: (handle: unknown) => { timers[handle as number].cleared = true },
    async fireDue() { for (const timer of timers) if (!timer.cleared) { timer.run(); await flush() } },
    async fire(index: number) { timers[index].run(); await flush() },
  }
}

const pasted = async () => ({ pasted: true })

function setup(initial: string[] = ['the user copied this']) {
  const board = new Board()
  board.items = initial
  const timers = manualTimers()
  return { board, timers, handback: new ClipboardHandback(board, 1000, timers) }
}

test('a clipboard that cannot be read is not an empty one: nothing is written, nothing is pasted, nothing is cleared', async () => {
  const { board, timers, handback } = setup()
  board.unreadable = true
  let keystrokes = 0
  await assert.rejects(handback.deliver('transcript', async () => { keystrokes++; return { pasted: true } }, false), ClipboardBackupError)
  await timers.fireDue()
  assert.equal(keystrokes, 0)
  assert.deepEqual(board.log, [])
  assert.deepEqual(board.items, ['the user copied this'])
})

test('the same clipboard is backed up and given back once it can be read again', async () => {
  const { board, timers, handback } = setup()
  board.unreadable = true
  await assert.rejects(handback.deliver('first try', pasted, false), ClipboardBackupError)
  board.unreadable = false
  await handback.deliver('second try', pasted, false)
  await timers.fireDue()
  assert.deepEqual(board.items, ['the user copied this'])
})

test('where the transcript is meant to stay on the clipboard, an unreadable one does not stop the paste', async () => {
  const { board, timers, handback } = setup()
  board.unreadable = true
  const outcome = await handback.deliver('transcript', pasted, true)
  await timers.fireDue()
  assert.equal(outcome.pasted, true)
  assert.deepEqual(board.items, ['transcript'])
  assert.equal(board.log.includes('clear'), false)
})

test('an empty clipboard that could be read is still emptied again afterwards', async () => {
  const { board, timers, handback } = setup([])
  await handback.deliver('transcript', pasted, false)
  await timers.fireDue()
  assert.deepEqual(board.items, [])
  assert.deepEqual(board.log, ['write:transcript', 'clear'])
})

test('a paste refused for an unreadable clipboard leaves the hand-back of the paste before it due', async () => {
  // Paste 1 is waiting for its hand-back. Before paste 2 the read that says
  // "still just the transcript" fails once and so does the backup: paste 2 is
  // refused, and paste 1's original must still come back.
  const { board, timers, handback } = setup(['original'])
  await handback.deliver('transcript 1', pasted, false)
  board.holdsFails = 1
  board.unreadable = true
  await assert.rejects(handback.deliver('transcript 2', pasted, false), ClipboardBackupError)
  board.unreadable = false
  await timers.fireDue()
  assert.deepEqual(board.items, ['original'])
})

test('a paste refused for an unreadable clipboard does not give back over something the user copied since', async () => {
  const { board, timers, handback } = setup(['original'])
  await handback.deliver('transcript 1', pasted, false)
  board.items = ['a newer copy']
  board.unreadable = true
  await assert.rejects(handback.deliver('transcript 2', pasted, false), ClipboardBackupError)
  await timers.fireDue()
  assert.deepEqual(board.items, ['a newer copy'])
})

// MARK: - Quitting

test('flush puts the clipboard back at once, and the timer that is left does nothing', async () => {
  const { board, timers, handback } = setup(['original'])
  await handback.deliver('transcript', pasted, false)
  assert.deepEqual(board.items, ['transcript'])
  await handback.flush()
  assert.deepEqual(board.items, ['original'])
  board.items = ['copied after quitting began']
  await timers.fire(0)
  assert.deepEqual(board.items, ['copied after quitting began'])
})

test('flush after a burst of pastes gives back the clipboard from before all of them', async () => {
  const { board, handback } = setup(['original'])
  await handback.deliver('transcript 1', pasted, false)
  await handback.deliver('transcript 2', pasted, false)
  await handback.flush()
  assert.deepEqual(board.items, ['original'])
})

test('flush leaves alone what the user copied since, and does nothing when nothing is due', async () => {
  const { board, handback } = setup(['original'])
  await handback.flush()
  assert.deepEqual(board.log, [])
  await handback.deliver('transcript', pasted, false)
  board.items = ['a newer copy']
  await handback.flush()
  assert.deepEqual(board.items, ['a newer copy'])
})

test('flush clears a clipboard that was empty, and gives nothing back where the transcript was kept on purpose', async () => {
  const empty = setup([])
  await empty.handback.deliver('transcript', pasted, false)
  await empty.handback.flush()
  assert.deepEqual(empty.board.items, [])
  const kept = setup(['original'])
  await kept.handback.deliver('transcript', pasted, true)
  await kept.handback.flush()
  assert.deepEqual(kept.board.items, ['transcript'])
})

test('flush waits for a paste that is still running, then gives back its clipboard', async () => {
  const { board, handback } = setup(['original'])
  const keystroke = deferred<{ pasted: boolean }>()
  const delivering = handback.deliver('transcript', () => keystroke.promise, false)
  let flushed = false
  const flushing = handback.flush().then(() => { flushed = true })
  await flush()
  assert.equal(flushed, false)
  keystroke.resolve({ pasted: true })
  await delivering
  await flushing
  assert.deepEqual(board.items, ['original'])
})

test('flushHandback gives back the registered hand-back, and never rejects', async () => {
  const { board, handback } = setup(['original'])
  registerHandback(handback)
  await handback.deliver('transcript', pasted, false)
  await flushHandback()
  assert.deepEqual(board.items, ['original'])
  registerHandback({ flush: async () => { throw new Error('the clipboard is gone') } })
  await flushHandback()
  registerHandback({ flush: async () => {} })
})

// MARK: - paste.ts on an Electron made of variables

class Item {
  types: string[]
  constructor(readonly payload: Record<string, string>, private unreadableTypes: string[] = []) { this.types = Object.keys(payload) }
  async getType(type: string) {
    if (this.unreadableTypes.includes(type)) throw new Error('format gone')
    return this.payload[type]
  }
}

/** An Electron clipboard whose reads can be made to fail, that logs how it was written to. */
function electronClipboard(options: { items?: Item[]; failReads?: number } = {}) {
  let items = options.items ?? []
  let failReads = options.failReads ?? 0
  const calls: string[] = []
  const text = () => items.map(item => item.payload['text/plain'] ?? '').join('')
  return {
    calls,
    get content() { return items.map(item => item.types.join('+')).join('|') + ':' + text() },
    get text() { return text() },
    failReadsForever() { failReads = Infinity },
    clipboard: {
      async read() {
        calls.push('read')
        if (failReads > 0) { failReads--; throw new Error('clipboard temporarily busy') }
        return items
      },
      async readText() { return text() },
      writeText(value: string) { calls.push(`writeText:${value}`); items = [new Item({ 'text/plain': value })] },
      async write(written: Item[]) { calls.push('write'); items = written },
      clear() { calls.push('clear'); items = [] },
    },
  }
}

/** paste.ts with that clipboard, loaded the way the app loads it. */
function loadPaste(clipboard: unknown) {
  const internals = Module as unknown as { _load(request: string, ...rest: unknown[]): unknown }
  const real = internals._load
  internals._load = function (this: unknown, request: string, ...rest: unknown[]) { return request === 'electron' ? { clipboard, ClipboardItem: Item } : real.call(this, request, ...rest) }
  const file = require.resolve('../src/main/paste')
  delete require.cache[file]
  try { return require('../src/main/paste') as typeof import('../src/main/paste') } finally { internals._load = real; delete require.cache[file] }
}

test('paste.ts: a clipboard that stays unreadable is left alone and the delivery fails, so the card offers the text back', async () => {
  const board = electronClipboard({ items: [new Item({ 'text/plain': 'valuable original clipboard' })] })
  board.failReadsForever()
  const { deliver } = loadPaste(board.clipboard)
  let keystrokes = 0
  await assert.rejects(deliver('transcript', () => { keystrokes++ }, false), ClipboardBackupError)
  await flushHandback()
  assert.equal(keystrokes, 0)
  assert.equal(board.calls.some(call => call.startsWith('writeText') || call === 'write' || call === 'clear'), false, board.calls.join(', '))
})

test('paste.ts: a clipboard that is busy for a moment is read again, and comes back after the paste', async () => {
  const board = electronClipboard({ items: [new Item({ 'text/plain': 'valuable original clipboard', 'text/html': '<b>valuable</b>' })], failReads: 1 })
  const { deliver } = loadPaste(board.clipboard)
  const outcome = await deliver('transcript', () => { assert.equal(board.text, 'transcript') }, false)
  assert.equal(outcome.pasted, true)
  await flushHandback()
  assert.equal(board.content, 'text/plain+text/html:valuable original clipboard')
  assert.equal(board.calls.includes('clear'), false)
})

test('paste.ts: something on the clipboard that none of which can be read is not an empty clipboard either', async () => {
  const board = electronClipboard({ items: [new Item({ 'application/x-private': 'bytes' }, ['application/x-private'])] })
  const { deliver } = loadPaste(board.clipboard)
  await assert.rejects(deliver('transcript', () => {}, false), ClipboardBackupError)
  assert.equal(board.calls.some(call => call.startsWith('writeText') || call === 'clear'), false)
})

test('paste.ts: an unreadable rich form leaves the entire original clipboard untouched', async () => {
  const board = electronClipboard({ items: [new Item({ 'text/plain': 'original', 'text/html': '<i>original</i>' }, ['text/html'])] })
  const { deliver } = loadPaste(board.clipboard)
  let keystrokes = 0
  await assert.rejects(deliver('transcript', () => { keystrokes++ }, false), ClipboardBackupError)
  await flushHandback()
  assert.equal(keystrokes, 0)
  assert.equal(board.content, 'text/plain+text/html:original')
  assert.equal(board.calls.some(call => call.startsWith('writeText') || call === 'write' || call === 'clear'), false)
})

test('paste.ts: an unreadable Linux text alias does not block a complete canonical text backup', async () => {
  const alias = 'electron application/osclipboard;format="UTF8_STRING"'
  const board = electronClipboard({ items: [new Item({ [alias]: 'original', 'text/plain': 'original' }, [alias])] })
  const { deliver } = loadPaste(board.clipboard)
  let keystrokes = 0
  assert.deepEqual(await deliver('transcript', () => { keystrokes++ }, false), { pasted: true })
  await flushHandback()
  assert.equal(keystrokes, 1)
  assert.equal(board.content, 'text/plain:original')
})

test('Session: an incomplete rich clipboard backup keeps the dictation recoverable and inserts once after Restore', async () => {
  const unreadable = ['text/html']
  const board = electronClipboard({ items: [new Item({ 'text/plain': 'original', 'text/html': '<i>original</i>' }, unreadable)] })
  const { deliver } = loadPaste(board.clipboard)
  const inserted: string[] = []
  const history: [string, boolean][] = []
  const route = makeDelivery({
    records: false,
    windows: { restore: async () => true, isTerminal: async () => false },
    paste: deliver,
    keyTap: () => { inserted.push(board.text) },
    writeClipboard: text => board.clipboard.writeText(text),
    keepsOnClipboard: () => false,
    addHistory: (text, pasted) => { history.push([text, pasted]) },
    delivered() {}, log() {}, sleep: async () => {},
  })
  const { session, sources } = sessionSetup(['recoverable dictated words'], {
    deliver: text => route(text, Promise.resolve('window')),
  })
  session.press(); await settle(); sources[0].say(); session.press(); await settle()
  assert.equal(phase(session), 'failed')
  assert.equal(session.canRestore, true)
  assert.equal(session.discarded?.preview, 'recoverable dictated words')
  assert.deepEqual(inserted, [])
  assert.deepEqual(history, [])
  assert.equal(board.content, 'text/plain+text/html:original')
  assert.equal(board.calls.some(call => call.startsWith('writeText') || call === 'write' || call === 'clear'), false)

  unreadable.length = 0
  session.restoreLast(); await settle(); session.press(); await settle()
  assert.equal(phase(session), 'idle')
  assert.deepEqual(inserted, ['recoverable dictated words'])
  assert.deepEqual(history, [['recoverable dictated words', true]])
  assert.equal(session.discarded, null)
  session.restoreLast(); await settle()
  assert.deepEqual(inserted, ['recoverable dictated words'], 'no second insertion after the successful recovery')
  await flushHandback()
  assert.equal(board.content, 'text/plain+text/html:original')
})

test('paste.ts: a clipboard that really is empty is empty again afterwards', async () => {
  const board = electronClipboard()
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  assert.equal(board.text, 'transcript')
  await flushHandback()
  assert.equal(board.content, ':')
  assert.equal(board.calls.at(-1), 'clear')
})

import assert from 'node:assert/strict'
import fs from 'node:fs'
import Module from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import { makeDelivery } from '../src/main/delivery'
import { deferred, disposeAll, phase, settle, setup } from './sessionHarness'

/**
 * Codex's bug hunt of 14 October 2026: F03, a paste that failed late wrote
 * over a newer dictation thrown away meanwhile, and F06, a history that
 * could not be written turned a pasted text into "Not pasted", whose restore
 * pasted it twice. Each test fails on the code before the fix.
 */
afterEach(() => disposeAll())

/** A dictation A whose paste hangs until `paste` settles; every later paste lands in `delivered`. */
function lateFirstPaste() {
  const paste = deferred<{ pasted: boolean }>()
  const delivered: string[] = []
  let first = true
  const made = setup(['first delivery', 'new recording must survive'], {
    deliver: async text => {
      if (first) { first = false; return paste.promise }
      delivered.push(text)
      return { pasted: true }
    },
  })
  return { ...made, paste, delivered }
}

/** A is finished and being pasted; B was begun, paused and thrown away. */
async function discardNewerWhileOlderPastes() {
  const run = lateFirstPaste()
  const { session, sources } = run
  session.press(); await settle(); sources[0].say()
  session.press(); await settle()
  assert.equal(phase(session), 'idle', 'A is being pasted with the card closed')
  session.press(); await settle(); sources[1].say()
  session.toggleMicrophone(); await settle()
  session.discard()
  assert.equal(session.discarded?.preview, 'new recording must survive')
  return run
}

test('F03: an older paste failing after a newer dictation was thrown away leaves Undo with the newer one', async () => {
  const { session, paste, delivered } = await discardNewerWhileOlderPastes()
  paste.reject(new Error('clipboard busy')); await settle()
  assert.equal(phase(session), 'discarded')
  assert.equal(session.discarded?.preview, 'new recording must survive', 'Undo still brings back the dictation it was shown for')
  session.undoDiscard(); await settle()
  assert.equal(session.plainText().trim(), 'new recording must survive')
  session.press(); await settle()
  assert.deepEqual(delivered, ['new recording must survive'])
  // The text that was not pasted is not lost either: the tray offers it next.
  assert.equal(session.discarded?.preview, 'first delivery')
  session.restoreLast(); await settle()
  assert.equal(session.plainText().trim(), 'first delivery')
})

test('F03: with the card already closed, the failed paste is what its restore button brings back, and the newer one waits behind it', async () => {
  const { session, paste } = await discardNewerWhileOlderPastes()
  session.discard()
  assert.equal(phase(session), 'idle', 'closed, the thrown-away dictation stays for the tray')
  paste.reject(new Error('clipboard busy')); await settle()
  assert.equal(phase(session), 'failed')
  assert.equal((session.phase as { canRestore?: boolean }).canRestore, true)
  session.restoreLast(); await settle()
  assert.equal(session.plainText().trim(), 'first delivery', 'the card said this text was not pasted')
  assert.equal(session.discarded?.preview, 'new recording must survive')
})

test('F03: a paste that fails with nothing newer about still keeps its text for the card, as before', async () => {
  const { session, sources, paste } = lateFirstPaste()
  session.press(); await settle(); sources[0].say()
  session.press(); await settle()
  paste.reject(new Error('clipboard busy')); await settle()
  assert.equal(phase(session), 'failed')
  session.restoreLast(); await settle()
  assert.equal(session.plainText().trim(), 'first delivery')
})

// MARK: - F06

function loadStore(scratch: string) {
  const internals = Module as unknown as { _load: (request: string, ...rest: unknown[]) => unknown }
  const original = internals._load
  internals._load = function (request: string, ...rest: unknown[]) {
    return request === 'electron' ? { app: { getPath: () => scratch, getLocale: () => 'en' } } : original.call(this, request, ...rest)
  }
  try {
    const file = require.resolve('../src/main/store')
    delete require.cache[file]
    return (require(file) as typeof import('../src/main/store')).Store
  } finally { internals._load = original }
}

test('F06: a pasted text whose history entry cannot be written stays pasted, and is not offered to paste again', async () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-history-fails-'))
  try {
    const Store = loadStore(scratch)
    const store = new Store()
    // A deterministic failed write: the atomic rename onto a folder throws EISDIR.
    fs.mkdirSync(path.join(scratch, 'history.json'))
    const pasted: string[] = [], logs: string[] = []
    const delivery = makeDelivery({
      records: false,
      windows: { restore: async () => true, isTerminal: async () => false },
      paste: async text => { pasted.push(text); return { pasted: true } },
      keyTap() {}, writeClipboard() {}, keepsOnClipboard: () => false,
      addHistory: (text, didPaste) => store.addHistory(text, didPaste), delivered() {}, log: message => logs.push(message), sleep: async () => {},
    })
    const { session, sources } = setup(['already pasted once'], { deliver: text => delivery(text, Promise.resolve('window')) })
    session.press(); await settle(); sources[0].say(); session.press(); await settle()
    assert.deepEqual(pasted, ['already pasted once'])
    assert.equal(phase(session), 'idle', 'no "Not pasted" for a text that was pasted')
    assert.equal(session.discarded, null, 'nothing kept to paste a second time')
    assert.ok(logs.some(line => line.startsWith('history: not saved')), logs.join('\n'))
  } finally { fs.rmSync(scratch, { recursive: true, force: true }) }
})

test('F06: the history failing does not change the outcome of the other two paths either', async () => {
  const told: string[] = []
  const deps = {
    windows: { restore: async () => false, isTerminal: async () => false },
    paste: async () => ({ pasted: true }),
    keyTap() {}, writeClipboard() {}, keepsOnClipboard: () => false,
    addHistory: () => { throw new Error('ENOSPC: no space left on device') },
    delivered: (text: string) => told.push(text), log() {}, sleep: async () => {},
  }
  assert.deepEqual(await makeDelivery({ ...deps, records: true })('test mode', Promise.resolve(null)), { pasted: true })
  const gone = await makeDelivery({ ...deps, records: false })('window gone', Promise.resolve('window'))
  assert.equal(gone.pasted, false)
  assert.deepEqual(told, ['test mode', 'window gone'], 'the windows showing the history are still told')
})

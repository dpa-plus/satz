import assert from 'node:assert/strict'
import fs from 'node:fs'
import Module from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import { makeDelivery } from '../src/main/delivery'
import { deferred, disposeAll, phase, settle, setup } from './sessionHarness'

const scratches: string[] = []
afterEach(() => { disposeAll(); for (const scratch of scratches.splice(0)) fs.rmSync(scratch, { recursive: true, force: true }) })

type FileOperation = 'readFileSync' | 'renameSync' | 'openSync' | 'rmSync'
/** Windows chmod cannot deny reads or directory writes; inject the same IO error on every platform. */
function denied<T>(operation: FileOperation, matches: (target: string) => boolean, work: () => T): T {
  const filesystem = fs as unknown as Record<FileOperation, (...args: unknown[]) => unknown>
  const real = filesystem[operation]
  filesystem[operation] = function (target: unknown, ...rest: unknown[]) {
    if (matches(String(target))) throw Object.assign(new Error(`EACCES: permission denied, ${operation}`), { code: 'EACCES' })
    return real.call(this, target, ...rest)
  }
  try { return work() } finally { filesystem[operation] = real }
}
function unreadableUnmovable<T>(file: string, work: () => T): T {
  const isHistory = (target: string) => target === file
  return denied('readFileSync', isHistory, () => denied('renameSync', isHistory, work))
}
function loadStore() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-history-persistence-')); scratches.push(scratch)
  const internals = Module as unknown as { _load(request: string, ...rest: unknown[]): unknown }; const original = internals._load
  internals._load = function (this: unknown, request: string, ...rest: unknown[]) { return request === 'electron' ? { app: { getPath: () => scratch, getLocale: () => 'en' } } : original.call(this, request, ...rest) }
  try { const file = require.resolve('../src/main/store'); delete require.cache[file]; return { Store: (require(file) as typeof import('../src/main/store')).Store, scratch } }
  finally { internals._load = original }
}
function delivery(store: InstanceType<ReturnType<typeof loadStore>['Store']>, inserted: string[]) {
  return makeDelivery({ records: false, windows: { restore: async () => true, isTerminal: async () => false },
    paste: async text => { inserted.push(text); return { pasted: true } }, keyTap() {}, writeClipboard() {}, keepsOnClipboard: () => false,
    addHistory: (text, pasted, cleanup) => store.addHistory(text, pasted, cleanup), delivered() {}, log() {}, sleep: async () => {},
  })
}

test('history write failure warns after one insertion, retains original metadata and saves both rows on recovery', async () => {
  const { Store, scratch } = loadStore(); const store = new Store(); const file = path.join(scratch, 'history.json'); fs.mkdirSync(file)
  fs.writeFileSync(file + '.new', 'preexisting file must stay untouched')
  const inserted: string[] = []; const route = delivery(store, inserted)
  const { session, sources } = setup(['synthetic source words', 'later saved'], {
    cleanup: async text => ({ text: text === 'synthetic source words' ? 'Synthetic source words.' : text, outcome: 'ok' }),
    deliver: (text, cleanup) => route(text, Promise.resolve('window'), cleanup),
  })
  session.press(); await settle(); sources[0].say(); session.press(); await settle()
  assert.deepEqual(inserted, ['Synthetic source words.'])
  assert.equal(phase(session), 'failed', 'a visible non-retry notice replaces silent idle')
  assert.equal(session.phase.kind === 'failed' && session.phase.canRetry, false)
  assert.equal(session.discarded, null)
  session.retry(); session.restoreLast(); await settle(); assert.deepEqual(inserted, ['Synthetic source words.'])
  assert.equal(store.persistenceIssue, 'saveFailed')
  assert.equal(store.history[0].text, 'Synthetic source words.'); assert.equal(store.history[0].original, 'synthetic source words'); assert.equal(store.history[0].pasted, true)
  assert.equal(fs.readFileSync(file + '.new', 'utf8'), 'preexisting file must stay untouched')
  assert.deepEqual(fs.readdirSync(scratch).filter(name => name.startsWith('.history-')), [], 'failed rename leaves no owned transcript temp')
  fs.rmdirSync(file)
  session.press(); await settle(); sources[1].say(); session.press(); await settle()
  assert.deepEqual(inserted, ['Synthetic source words.', 'later saved']); assert.equal(store.persistenceIssue, null); assert.equal(phase(session), 'idle')
  const restarted = new Store(); assert.deepEqual(restarted.history.map(row => row.text), ['later saved', 'Synthetic source words.']); assert.equal(restarted.history[1].original, 'synthetic source words')
  if (process.platform !== 'win32') assert.equal(fs.statSync(file).mode & 0o777, 0o600)
})

test('Store returns typed failed save instead of pretending a memory-only row was persisted', () => {
  const { Store, scratch } = loadStore(); const store = new Store(); fs.mkdirSync(path.join(scratch, 'history.json'))
  assert.deepEqual(store.addHistory('retained words', true), { status: 'failed', issue: 'saveFailed' })
  assert.equal(store.history[0].text, 'retained words'); assert.equal(store.persistenceIssue, 'saveFailed')
})

test('history Off is intentional and clearing an absent file succeeds without a warning', () => {
  const { Store, scratch } = loadStore(); const store = new Store(); store.prefs.historyLimit = 0
  assert.deepEqual(store.addHistory('not retained by choice', true), { status: 'off' }); assert.equal(store.persistenceIssue, null)
  assert.equal(fs.existsSync(path.join(scratch, 'history.json')), false)
  assert.deepEqual(store.clearHistory(), { status: 'saved' }); assert.equal(store.persistenceIssue, null)
})

test('failed clear is distinct and does not recursively delete a directory; successful clear resets warning', () => {
  const { Store, scratch } = loadStore(); const store = new Store(); const file = path.join(scratch, 'history.json')
  fs.mkdirSync(file); fs.writeFileSync(path.join(file, 'keep'), 'synthetic marker')
  assert.deepEqual(store.clearHistory(), { status: 'failed', issue: 'clearFailed' }); assert.equal(store.persistenceIssue, 'clearFailed')
  assert.equal(fs.readFileSync(path.join(file, 'keep'), 'utf8'), 'synthetic marker')
  fs.unlinkSync(path.join(file, 'keep')); fs.rmdirSync(file)
  assert.deepEqual(store.clearHistory(), { status: 'saved' }); assert.equal(store.persistenceIssue, null)
})

test('unreadable unmovable history stays protected; new in-memory rows explicitly report unsaved', () => {
  const { Store, scratch } = loadStore(); const file = path.join(scratch, 'history.json')
  const original = '[{"id":"old","text":"original retained file","date":"2026-10-15","pasted":true}]'
  fs.writeFileSync(file, original)
  const store = unreadableUnmovable(file, () => new Store())
  assert.equal(store.persistenceIssue, 'protected')
  assert.deepEqual(store.addHistory('new memory-only words', true), { status: 'failed', issue: 'protected' }); assert.equal(store.history[0].text, 'new memory-only words')
  assert.equal(fs.readFileSync(file, 'utf8'), original)
  assert.deepEqual(store.clearHistory(), { status: 'failed', issue: 'protected' }); assert.equal(fs.readFileSync(file, 'utf8'), original)
  fs.writeFileSync(path.join(scratch, 'preferences.json'), '{"historyLimit":0}')
  const off = unreadableUnmovable(file, () => new Store())
  assert.equal(off.persistenceIssue, 'protected'); assert.equal(fs.readFileSync(file, 'utf8'), original)
})

test('failed write preserves existing disk history while the new row stays available in memory', () => {
  const { Store, scratch } = loadStore(); const store = new Store(); store.addHistory('previous saved words', true)
  const file = path.join(scratch, 'history.json'); const previous = fs.readFileSync(file, 'utf8')
  denied('openSync', target => path.dirname(target) === scratch && path.basename(target).startsWith('.history-'), () => {
    assert.deepEqual(store.addHistory('new unsaved words', true), { status: 'failed', issue: 'saveFailed' })
  })
  assert.equal(fs.readFileSync(file, 'utf8'), previous)
  assert.deepEqual(store.history.map(row => row.text), ['new unsaved words', 'previous saved words'])
  assert.deepEqual(fs.readdirSync(scratch).filter(name => name.startsWith('.history-')), [])
})

test('clipboard fallback remains the visible delivery status when history also fails', async () => {
  const { Store, scratch } = loadStore(); const store = new Store(); fs.mkdirSync(path.join(scratch, 'history.json'))
  const route = makeDelivery({ records: false, windows: { restore: async () => false, isTerminal: async () => false },
    paste: async () => { throw new Error('must not paste') }, keyTap() {}, writeClipboard() {}, keepsOnClipboard: () => false,
    addHistory: (text, pasted) => store.addHistory(text, pasted), delivered() {}, log() {}, sleep: async () => {},
  })
  const { session, sources } = setup(['clipboard-only words'], { deliver: text => route(text, Promise.resolve('gone')) })
  session.press(); await settle(); sources[0].say(); session.press(); await settle()
  assert.equal(phase(session), 'clipboard'); assert.equal(store.persistenceIssue, 'saveFailed'); assert.equal(store.history[0].pasted, false)
  assert.equal(session.discarded, null)
})

test('late persistence warning never replaces a newer active dictation', async () => {
  const { Store, scratch } = loadStore(); const store = new Store(); fs.mkdirSync(path.join(scratch, 'history.json'))
  const held = deferred(); const inserted: string[] = []; const route = delivery(store, inserted)
  const { session, sources } = setup(['first delivered words', 'new active words'], { deliver: async text => { await held.promise; return route(text, Promise.resolve('window')) } })
  session.press(); await settle(); sources[0].say(); session.press(); await settle(); session.press(); await settle(); sources[1].say()
  held.resolve(); await settle(); assert.equal(phase(session), 'listening'); assert.deepEqual(inserted, ['first delivered words']); assert.equal(store.persistenceIssue, 'saveFailed')
})

test('startup with History Off retries the existing clear choice and preserves a visible deletion failure until recovery', () => {
  const { Store, scratch } = loadStore(); const file = path.join(scratch, 'history.json')
  const original = '[{"id":"old","text":"previous saved text","date":"2026-10-15","pasted":true}]'
  fs.writeFileSync(path.join(scratch, 'preferences.json'), '{"historyLimit":0}')
  fs.writeFileSync(file, original)
  const store = denied('rmSync', target => target === file, () => new Store())
  assert.deepEqual(store.history, []); assert.equal(store.persistenceIssue, 'clearFailed')
  assert.equal(fs.readFileSync(file, 'utf8'), original)
  const recovered = new Store()
  assert.equal(fs.existsSync(file), false); assert.equal(recovered.persistenceIssue, null)
})

test('failed history limit preference save rolls back the choice and reports failure without dropping or disabling history', () => {
  const { Store, scratch } = loadStore(); const store = new Store(); store.addHistory('saved before limit action', true)
  const file = path.join(scratch, 'history.json'); const previous = fs.readFileSync(file, 'utf8'); const limit = store.prefs.historyLimit
  fs.mkdirSync(path.join(scratch, 'preferences.json'))
  assert.deepEqual(store.setHistoryLimit(0), { status: 'failed', issue: 'limitFailed' })
  assert.equal(store.persistenceIssue, 'limitFailed'); assert.equal(store.prefs.historyLimit, limit)
  assert.equal(fs.readFileSync(file, 'utf8'), previous); assert.equal(store.history[0].text, 'saved before limit action')
  assert.deepEqual(store.addHistory('new words still saved', true), { status: 'saved' }); assert.equal(store.persistenceIssue, null)
  fs.rmdirSync(path.join(scratch, 'preferences.json'))
  assert.deepEqual(store.setHistoryLimit(0), { status: 'saved' }); assert.equal(store.persistenceIssue, null); assert.equal(fs.existsSync(file), false)
})

for (const issue of ['saveFailed', 'clearFailed', 'protected'] as const) {
  test(`failed setting change preserves the existing ${issue} persistence warning`, () => {
    const { Store, scratch } = loadStore(); const file = path.join(scratch, 'history.json')
    let store = new Store()
    if (issue === 'protected') {
      fs.writeFileSync(file, '[{"id":"old","text":"protected original","date":"2026-10-15","pasted":true}]')
      store = unreadableUnmovable(file, () => new Store())
      store.addHistory('new memory-only words', true)
    } else {
      fs.mkdirSync(file)
      if (issue === 'saveFailed') store.addHistory('new memory-only words', true)
      else store.clearHistory()
    }
    assert.equal(store.persistenceIssue, issue)
    const previousLimit = store.prefs.historyLimit
    fs.mkdirSync(path.join(scratch, 'preferences.json'))
    assert.deepEqual(store.setHistoryLimit(0), { status: 'failed', issue: 'limitFailed' })
    assert.equal(store.prefs.historyLimit, previousLimit)
    assert.equal(store.persistenceIssue, issue, 'persistent storage warning stays; limitFailed is returned for the separate setting notice')
    if (issue !== 'clearFailed') assert.equal(store.history[0].text, 'new memory-only words')
  })
}

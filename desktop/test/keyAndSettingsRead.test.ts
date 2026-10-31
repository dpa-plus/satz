import assert from 'node:assert/strict'
import fs from 'node:fs'
import Module from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import { LogFile } from '../src/main/logFile'
import { diagnosticsLines, keySentence, keyShort, startedBy, trayTooltip, type Diagnostics } from '../src/core/status'

/**
 * A report from Windows, 31 October 2026: after a restart satz said "No key"
 * with the key file there and readable, until it was started again, and its
 * log had no line about it. satz could not tell a missing key from one it
 * could not read, a settings file it could not read was taken for none (and
 * written over at the next change), and a log line it could not write was
 * dropped without a word. Each test fails on the code before the fix.
 */
const scratches: string[] = []
afterEach(() => { for (const dir of scratches.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })

/** store.ts with Electron's app pointing at a scratch folder. */
function loadStore() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-keyread-'))
  scratches.push(scratch)
  const internals = Module as unknown as { _load: (request: string, ...rest: unknown[]) => unknown }
  const original = internals._load
  internals._load = function (request: string, ...rest: unknown[]) {
    return request === 'electron' ? { app: { getPath: () => scratch, getLocale: () => 'en' } } : original.call(this, request, ...rest)
  }
  try {
    const file = require.resolve('../src/main/store')
    delete require.cache[file]
    return { Store: (require(file) as typeof import('../src/main/store')).Store, scratch }
  } finally { internals._load = original }
}

/** Reads of one file fail with `code` (all of them, or the first `times`), whoever runs the tests: a chmod does nothing for root. */
function refuse(name: string, code: string, times = Infinity) {
  const real = fs.readFileSync
  let left = times
  ;(fs as { readFileSync: unknown }).readFileSync = function (target: unknown, ...rest: unknown[]) {
    if (String(target).endsWith(name) && left-- > 0) throw Object.assign(new Error(`${code}: refused, open '${name}'`), { code })
    return (real as (...args: unknown[]) => unknown).call(this, target, ...rest)
  }
  return () => { (fs as { readFileSync: unknown }).readFileSync = real }
}

const secret = 'sk-or-v1-not-a-real-key-0123456789'

test('a key file that is there and cannot be read is not "No key": the store says which, and logs it once, without the key', () => {
  const { Store, scratch } = loadStore()
  const logs: string[] = []
  const store = new Store(message => logs.push(message))
  store.storeKey(secret, 'openrouter')
  const restore = refuse(path.join('keys', 'openrouter'), 'EPERM')
  try {
    assert.deepEqual(store.keyRead('openrouter'), { key: null, problem: { kind: 'unreadable', code: 'EPERM' } })
    assert.equal(store.hasKey('openrouter'), false)
    store.readKey('openrouter')
  } finally { restore() }
  const said = logs.filter(line => line.startsWith('key for openrouter'))
  assert.equal(said.length, 1, 'said once, not at every look: ' + said.join('\n'))
  assert.match(said[0], /could not be read \(EPERM\)/)
  assert.ok(said[0].includes(path.join(scratch, 'keys', 'openrouter')), 'where satz looked')
  assert.ok(logs.every(line => !line.includes(secret)), 'never the key')
  // Readable again: the key is back, and the log says so.
  assert.equal(store.readKey('openrouter'), secret)
  assert.match(logs.at(-1) ?? '', /key for openrouter: readable/)
})

test('a key file locked for a moment (a virus scanner, sign-in) is read on the next try, not taken for none', () => {
  const { Store } = loadStore()
  const store = new Store()
  store.storeKey(secret, 'openrouter')
  const restore = refuse(path.join('keys', 'openrouter'), 'EBUSY', 2)
  try { assert.equal(store.readKey('openrouter'), secret) } finally { restore() }
})

test('no key file, and an empty one, are told apart from an unreadable one', () => {
  const { Store, scratch } = loadStore()
  const logs: string[] = []
  const store = new Store(message => logs.push(message))
  assert.deepEqual(store.keyRead('openrouter').problem, { kind: 'missing' })
  fs.mkdirSync(path.join(scratch, 'keys'), { recursive: true })
  fs.writeFileSync(path.join(scratch, 'keys', 'openrouter'), '  \n')
  assert.deepEqual(store.keyRead('openrouter').problem, { kind: 'empty' })
  assert.deepEqual(logs.filter(line => line.startsWith('key for')).map(line => line.replace(/^.* (is|could)/, '$1')), ['is missing', 'is empty'])
})

test('cleanup keys go through the same reading', () => {
  const { Store } = loadStore()
  const store = new Store()
  store.storeAccount('openrouter', secret)
  const restore = refuse(path.join('keys', 'openrouter'), 'EACCES')
  try { assert.equal(store.readAccount('openrouter'), null) } finally { restore() }
  assert.equal(store.readAccount('openrouter'), secret)
})

test('a preferences.json that cannot be read is left as it is: standard settings in memory, nothing written over it, and read again later', () => {
  const { Store, scratch } = loadStore()
  const target = path.join(scratch, 'preferences.json')
  const saved = JSON.stringify({ provider: 'groq', models: { groq: 'whisper-large-v3' }, startAtLoginDefaulted: true, startsAtLogin: false })
  fs.writeFileSync(target, saved)
  const logs: string[] = []
  const restore = refuse('preferences.json', 'EPERM')
  let store!: InstanceType<typeof Store>
  try {
    store = new Store(message => logs.push(message))
    assert.equal(store.preferencesProblem, 'EPERM')
    assert.equal(store.prefs.provider, 'openrouter', 'the standard settings meanwhile')
    store.update({ showsText: false, startAtLoginDefaulted: true })
    assert.equal(store.retryPreferences(), false, 'still refused')
  } finally { restore() }
  assert.equal(fs.readFileSync(target, 'utf8'), saved, 'the user\'s settings, not written over')
  assert.ok(logs.some(line => line.includes('preferences.json could not be read (EPERM)')), logs.join('\n'))
  assert.equal(store.retryPreferences(), true)
  assert.equal(store.preferencesProblem, null)
  assert.equal(store.prefs.provider, 'groq')
  assert.equal(store.prefs.startsAtLogin, false)
  // From now on changes are saved again.
  store.update({ showsText: false })
  assert.equal(JSON.parse(fs.readFileSync(target, 'utf8')).showsText, false)
})

test('a preferences.json that is not settings is moved aside and kept, and satz starts on the standard ones', () => {
  const { Store, scratch } = loadStore()
  fs.writeFileSync(path.join(scratch, 'preferences.json'), '{"provider": "gro')
  const logs: string[] = []
  const store = new Store(message => logs.push(message))
  assert.equal(store.preferencesProblem, null)
  const aside = fs.readdirSync(scratch).filter(name => name.startsWith('preferences.json.broken-'))
  assert.equal(aside.length, 1)
  assert.doesNotMatch(aside[0], /:/, 'a name Windows allows')
  store.update({ showsText: false })
  assert.equal(JSON.parse(fs.readFileSync(path.join(scratch, 'preferences.json'), 'utf8')).showsText, false)
})

test('a log line satz\'s folder refuses goes to the second file, which says why once; Settings learns the code', () => {
  const files = new Map<string, string>()
  let refusing = true
  const append = (file: string, text: string) => {
    if (file === 'primary.log' && refusing) throw Object.assign(new Error('EPERM'), { code: 'EPERM' })
    files.set(file, (files.get(file) ?? '') + text)
  }
  const log = new LogFile('primary.log', 'fallback.log', append)
  log.write('2026-10-31T08:00:00.000Z satz 0.4.6 on win32 x64')
  log.write('2026-10-31T08:00:01.000Z dictation not started: No key')
  assert.equal(log.problem, 'EPERM')
  assert.equal(log.refused, 2)
  const lines = (files.get('fallback.log') ?? '').trim().split('\n')
  assert.equal(lines.length, 3)
  assert.match(lines[0], /^2026-10-31T08:00:00.000Z log: primary.log refused a line \(EPERM\)/)
  refusing = false
  log.write('2026-10-31T08:00:02.000Z back')
  assert.equal(files.get('primary.log'), '2026-10-31T08:00:02.000Z back\n')
})

test('how satz was started, from its arguments', () => {
  assert.equal(startedBy(['--login']), 'login')
  assert.equal(startedBy(['--toggle']), 'toggle')
  assert.equal(startedBy(['--settings']), 'settings')
  assert.equal(startedBy([]), 'hand')
})

test('the card and the tray say "Key unreadable" for a file that could not be read, in both languages and without dashes', () => {
  assert.equal(keyShort({ kind: 'saved' }, 'en'), null)
  assert.equal(keyShort({ kind: 'missing' }, 'en'), 'No key')
  assert.equal(keyShort({ kind: 'empty' }, 'de'), 'Kein Schlüssel')
  assert.equal(keyShort({ kind: 'unreadable', code: 'EPERM' }, 'en'), 'Key unreadable')
  assert.equal(keyShort({ kind: 'unreadable', code: 'EPERM' }, 'de'), 'Schlüssel nicht lesbar')
  assert.equal(keySentence({ kind: 'missing' }, 'en'), null, 'the empty field says that one')
  for (const language of ['de', 'en'] as const) {
    const sentence = keySentence({ kind: 'unreadable', code: 'EBUSY' }, language) ?? ''
    assert.match(sentence, /EBUSY/)
    assert.doesNotMatch(sentence, /—/)
  }
  assert.equal(trayTooltip('0.4.6', null, 'right Ctrl twice', 'en'), 'satz 0.4.6: ready (right Ctrl twice)')
  assert.equal(trayTooltip('0.4.6', 'Key unreadable', 'right Ctrl twice', 'en'), 'satz 0.4.6: Key unreadable')
  assert.equal(trayTooltip('0.4.6', null, null, 'de'), 'satz 0.4.6: bereit')
})

test('Status lists only what is wrong, besides the version and how satz was started', () => {
  const healthy: Diagnostics = { version: '0.4.6', platform: 'win32', folder: 'C:\\satz', startedBy: 'login',
    log: { file: 'C:\\satz\\satz.log', problem: null, fallback: 'C:\\Temp\\satz.log' }, preferencesProblem: null, startBlocked: false }
  assert.deepEqual(diagnosticsLines(healthy, 'en'), [{ text: 'satz 0.4.6 · Windows · started at login', problem: false }])
  for (const language of ['de', 'en'] as const) {
    const lines = diagnosticsLines({ ...healthy, log: { ...healthy.log, problem: 'EPERM' }, preferencesProblem: 'EBUSY', startBlocked: true }, language)
    assert.equal(lines.filter(line => line.problem).length, 3)
    assert.ok(lines[1].text.includes('C:\\Temp\\satz.log'), 'where the log went')
    assert.ok(lines.every(line => !line.text.includes('—')))
  }
})

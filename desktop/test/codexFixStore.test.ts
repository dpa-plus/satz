import assert from 'node:assert/strict'
import fs from 'node:fs'
import Module from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import { customAddress, keyRefusal, providerNeeds, switchRow } from '../src/core/browse'

/**
 * Codex's bug hunt of 14 October 2026, for the settings on disk: F14, Custom
 * became "in use" with an ftp:// address; a history.json that was not a list
 * stopped satz's start; a key pasted with a line break was saved, and the
 * request's error then quoted it into the log; quitting within the second
 * after a paste left the transcript on the clipboard. Each test fails on the
 * code before the fix.
 */
const scratches: string[] = []
afterEach(() => { for (const dir of scratches.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })

/** store.ts with Electron's app pointing at a scratch folder. */
function loadStore() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-store-'))
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

// MARK: - F14

const facts = { hasKey: true, customBaseURL: '', model: 'm', microsoftRegion: 'northeurope', microsoftEndpoint: '' }

test('F14: Custom needs an https address, or http on the own network; ftp:// and the like are no address', () => {
  // Typed and refused: the page says why (core/browse.ts, needsMessage), it does not ask for what is there.
  for (const address of ['ftp://example.invalid/v1', 'file:///etc/passwd', 'ws://example.invalid/v1', '//example.invalid/v1', 'example.invalid/v1', 'http://example.invalid/v1', 'https://']) {
    assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: address }), ['addressRefused'], address)
  }
  assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: '' }), ['address'])
  for (const address of ['https://example.invalid/v1', ' HTTPS://Example.invalid/v1 ', 'http://localhost:9000/v1', 'http://127.0.0.1:8080/v1', 'http://[::1]:8080/v1',
    'http://192.168.1.5:8000/v1', 'http://whisper.local:9000', 'http://nas:8000/v1']) {
    assert.deepEqual(providerNeeds('custom', { ...facts, customBaseURL: address }), [], address)
  }
  assert.deepEqual(switchRow('custom', 'openrouter', 'en', providerNeeds('custom', { ...facts, customBaseURL: 'ftp://example.invalid/v1' })),
    { text: 'Dictation goes to OpenRouter. This address won\'t work: https, or http only on your own network.', button: null }, 'no "Use Custom" for an ftp address')
})

test('F14: the store refuses dictations to such an address and sends the one it checked', () => {
  const { Store } = loadStore()
  const store = new Store()
  store.update({ provider: 'custom', customBaseURL: 'ftp://example.invalid/v1', models: { custom: 'm' } })
  assert.equal(store.endpointMissing, true)
  store.update({ customBaseURL: '  https://example.invalid/v1  ' })
  assert.equal(store.endpointMissing, false)
  assert.equal(store.transcriberSettings().customBaseURL, 'https://example.invalid/v1', 'the address as checked, without the spaces')
  assert.equal(customAddress('https://example.invalid/v1 '), 'https://example.invalid/v1')
})

test('the store sends to an address on the own network over http, and not to a public one', () => {
  const { Store } = loadStore()
  const store = new Store()
  store.update({ provider: 'custom', models: { custom: 'm' } })
  for (const address of ['http://192.168.1.20:11434/v1', 'http://whisper.local:9000/v1', 'http://nas:8000/v1', 'http://10.0.0.7/v1', 'http://[fd00::5]:8000/v1']) {
    store.update({ customBaseURL: address })
    assert.equal(store.endpointMissing, false, address)
    assert.equal(store.transcriberSettings().customBaseURL, address, address)
  }
  for (const address of ['http://example.com/v1', 'http://8.8.8.8/v1', 'http://nas.local.example.com/v1']) {
    store.update({ customBaseURL: address })
    assert.equal(store.endpointMissing, true, address)
    assert.equal(store.transcriberSettings().customBaseURL, '', 'nothing refused is sent: ' + address)
  }
  // Microsoft's own address: the same rule.
  store.update({ provider: 'microsoft', microsoftEndpoint: 'http://speech.example.com' })
  assert.equal(store.endpointMissing, true)
  store.update({ microsoftEndpoint: 'http://speech.lan:9000' })
  assert.equal(store.endpointMissing, false)
})

// MARK: - history.json that is not a list of entries

test('a history.json that is not a list is moved aside, and satz starts with an empty history', () => {
  const { Store, scratch } = loadStore()
  fs.writeFileSync(path.join(scratch, 'history.json'), '{"unexpected":true}')
  const logs: string[] = []
  const store = new Store(message => logs.push(message))
  assert.deepEqual(store.history, [])
  const aside = fs.readdirSync(scratch).filter(name => name.startsWith('history.json.broken-'))
  assert.equal(aside.length, 1)
  assert.doesNotMatch(aside[0], /:/, 'a name Windows allows')
  assert.equal(fs.readFileSync(path.join(scratch, aside[0]), 'utf8'), '{"unexpected":true}', 'kept as it was')
  assert.equal(fs.existsSync(path.join(scratch, 'history.json')), false)
  assert.ok(logs.some(line => line.includes(aside[0])), logs.join('\n'))
  // The next dictation starts a new history beside the old one.
  store.addHistory('neu', true)
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(scratch, 'history.json'), 'utf8')).map((entry: { text: string }) => entry.text), ['neu'])
})

test('a cut-off history.json and one with an entry that is not one are kept too, instead of being written over', () => {
  for (const broken of ['[{"id":"a","text":"wich', '[{"id":"a","text":"ok"}, 3]', '"text"', 'null']) {
    const { Store, scratch } = loadStore()
    fs.writeFileSync(path.join(scratch, 'history.json'), broken)
    assert.deepEqual(new Store().history, [], broken)
    const aside = fs.readdirSync(scratch).find(name => name.startsWith('history.json.broken-'))
    assert.ok(aside, broken)
    assert.equal(fs.readFileSync(path.join(scratch, aside), 'utf8'), broken)
  }
})

test('a good history, and one from before ids, are read as before', () => {
  const { Store, scratch } = loadStore()
  fs.writeFileSync(path.join(scratch, 'history.json'), JSON.stringify([{ id: 'a', text: 'eins', date: '2026-10-01T00:00:00.000Z', pasted: true }, { text: 'alt', date: '2026-01-01T00:00:00.000Z', pasted: false }]))
  const history = new Store().history
  assert.deepEqual(history.map(entry => entry.text), ['eins', 'alt'])
  assert.equal(history[0].id, 'a')
  assert.ok(history[1].id)
  assert.equal(fs.readdirSync(scratch).some(name => name.includes('broken')), false)
})

// MARK: - history.json that exists and cannot be read

/** Makes reads of one file fail the way a permission error does, whoever runs the tests (a chmod does nothing for root). */
function unreadable(name: string, error: NodeJS.ErrnoException, work: () => void) {
  const real = fs.readFileSync
  ;(fs as { readFileSync: unknown }).readFileSync = function (target: unknown, ...rest: unknown[]) {
    if (String(target).endsWith(name)) throw error
    return (real as (...args: unknown[]) => unknown).call(this, target, ...rest)
  }
  try { work() } finally { (fs as { readFileSync: unknown }).readFileSync = real }
}
const denied = () => Object.assign(new Error('EACCES: permission denied, open \'history.json\''), { code: 'EACCES' })

test('a history.json that exists but cannot be read is moved aside, not written over by the next dictation', () => {
  const { Store, scratch } = loadStore()
  const original = JSON.stringify([{ id: 'a', text: 'wichtig, noch nicht gesichert', date: '2026-10-01T00:00:00.000Z', pasted: true }])
  fs.writeFileSync(path.join(scratch, 'history.json'), original)
  const logs: string[] = []
  let store!: InstanceType<typeof Store>
  unreadable('history.json', denied(), () => { store = new Store(message => logs.push(message)) })
  assert.deepEqual(store.history, [], 'starts empty')
  const aside = fs.readdirSync(scratch).filter(name => name.startsWith('history.json.unreadable-'))
  assert.equal(aside.length, 1, fs.readdirSync(scratch).join(', '))
  assert.doesNotMatch(aside[0], /:/, 'a name Windows allows')
  assert.equal(fs.readFileSync(path.join(scratch, aside[0]), 'utf8'), original, 'kept as it was')
  assert.equal(fs.existsSync(path.join(scratch, 'history.json')), false)
  assert.ok(logs.some(line => line.includes(aside[0]) && line.includes('history')), logs.join('\n'))
  // The next dictation starts a new history beside the old one, which stays.
  store.addHistory('neu', true)
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(scratch, 'history.json'), 'utf8')).map((entry: { text: string }) => entry.text), ['neu'])
  assert.equal(fs.readFileSync(path.join(scratch, aside[0]), 'utf8'), original)
})

test('a history.json that is a folder, or a lock that blocks reading, is the same: aside, and a fresh start', () => {
  const { Store, scratch } = loadStore()
  fs.mkdirSync(path.join(scratch, 'history.json'))
  fs.writeFileSync(path.join(scratch, 'history.json', 'inside'), 'x')
  const store = new Store()
  assert.deepEqual(store.history, [])
  assert.deepEqual(fs.readdirSync(scratch).filter(name => name.startsWith('history.json.unreadable-')).length, 1)
  store.addHistory('neu', true)
  assert.equal(JSON.parse(fs.readFileSync(path.join(scratch, 'history.json'), 'utf8'))[0].text, 'neu')
})

test('when it cannot be moved either, it is left as it is, nothing is written to it this time, and it is said once', () => {
  const { Store, scratch } = loadStore()
  const original = JSON.stringify([{ id: 'a', text: 'wichtig', date: '2026-10-01T00:00:00.000Z', pasted: true }])
  const target = path.join(scratch, 'history.json')
  fs.writeFileSync(target, original)
  const logs: string[] = []
  const realRename = fs.renameSync
  let store!: InstanceType<typeof Store>
  ;(fs as { renameSync: unknown }).renameSync = (from: string, to: string) => {
    if (String(from).endsWith('history.json')) throw Object.assign(new Error('EPERM: operation not permitted, rename'), { code: 'EPERM' })
    return realRename(from, to)
  }
  try {
    unreadable('history.json', denied(), () => { store = new Store(message => logs.push(message)) })
    assert.deepEqual(store.history, [])
    store.addHistory('eins', true)
    store.addHistory('zwei', false)
    store.removeHistory((store.history as { id: string }[])[0].id)
    store.setHistoryLimit(5)
    store.clearHistory()
  } finally { (fs as { renameSync: unknown }).renameSync = realRename }
  assert.equal(fs.readFileSync(target, 'utf8'), original, 'not a byte of it changed, not deleted by "clear history" either')
  assert.deepEqual(fs.readdirSync(scratch).filter(name => name.startsWith('history.json')), ['history.json'], 'no temporary file, no aside')
  assert.equal(logs.filter(line => line.includes('history')).length, 1, logs.join('\n'))
  assert.match(logs[0], /left as it is/)
})

test('without a history.json there is nothing to move and nothing to log, and the history is written as before', () => {
  const { Store, scratch } = loadStore()
  const logs: string[] = []
  const store = new Store(message => logs.push(message))
  assert.deepEqual(store.history, [])
  assert.deepEqual(logs, [])
  store.addHistory('eins', true)
  store.addHistory('zwei', true)
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(scratch, 'history.json'), 'utf8')).map((entry: { text: string }) => entry.text), ['zwei', 'eins'])
  assert.deepEqual(fs.readdirSync(scratch).filter(name => name.startsWith('history.json.')), [])
})

// MARK: - Keys with a character a header cannot carry

test('a key with a line break, a NUL or another control character inside is refused, saying why, in both languages', () => {
  const { Store, scratch } = loadStore()
  const store = new Store()
  for (const key of ['sk-abc\ndef', 'sk-abc\rdef', 'sk-abc\u0000def', 'sk-\tabc', 'sk-abc\u007fdef']) {
    assert.throws(() => store.storeKey(key, 'openai'), /line break/, JSON.stringify(key))
    assert.equal(store.hasKey('openai'), false)
  }
  assert.equal(fs.existsSync(path.join(scratch, 'keys', 'openai')), false, 'nothing written')
  assert.match(keyRefusal('a\nb', 'de')!, /Zeilenumbruch/)
  assert.match(keyRefusal('a\nb', 'en')!, /line break/)
  for (const language of ['de', 'en'] as const) assert.doesNotMatch(keyRefusal('a\nb', language)!, /—/)
})

test('a key pasted with a line break at its end is saved without it, as before', () => {
  const { Store } = loadStore()
  const store = new Store()
  store.storeKey('  sk-abc\n', 'openai')
  assert.equal(store.readKey('openai'), 'sk-abc')
})

test('the key handler logs why a key was not saved, never the key, and the page gets false', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const handler = main.slice(main.indexOf("ipcMain.handle('settings:store-key'"), main.indexOf("ipcMain.handle('settings:open-key-page'"))
  assert.match(handler, /catch \(error\)/)
  assert.match(handler, /log\(`key for \$\{provider\} not saved: \$\{\(error as Error\)\.message\}`\)/)
})

// MARK: - Quitting

test('quitting gives the clipboard back before satz ends, beside the music', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const quit = main.slice(main.indexOf("app.on('before-quit'"), main.indexOf("ipcMain.handle('settings:store-key'"))
  assert.match(quit, /Promise\.allSettled\(\[mediaPause\.quitting\(\), flushHandback\(\)\]\)\.finally\(\(\) => app\.quit\(\)\)/)
  assert.match(main, /import \{ flushHandback \} from '\.\/clipboardHandback'/)
})

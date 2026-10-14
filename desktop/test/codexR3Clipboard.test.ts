import assert from 'node:assert/strict'
import Module from 'node:module'
import { test } from 'node:test'
import { flushHandback, isPlainTextForms } from '../src/main/clipboardHandback'

// Codex bug hunt, third pass, VM-01: on Ubuntu the image that was on the
// clipboard before a dictation never came back. Electron lists the text it
// puts there as one item with more than "text/plain" (the X11 selection's own
// names for the same text), the hand-back took that for "something else was
// copied", and left the transcript where the image had been.

/** The forms Electron's clipboard.read() reported for plain text in the Ubuntu 24.04 Wayland guest (proofs/vm/ubuntu-electron-clipboard-types.json). */
const LINUX_TEXT_FORMS = [
  'text/plain',
  'electron application/osclipboard;format="TARGETS"',
  'electron application/osclipboard;format="TIMESTAMP"',
  'electron application/osclipboard;format="UTF8_STRING"',
  'electron application/osclipboard;format="text/plain;charset=utf-8"',
]

/** What wl-paste lists for the same clipboard: the selection's names without Electron's wrapping. */
const X11_TEXT_NAMES = ['text/plain;charset=utf-8', 'text/plain', 'TEXT', 'STRING', 'UTF8_STRING', 'MULTIPLE', 'SAVE_TARGETS', 'TARGETS', 'TIMESTAMP']

// MARK: - Which forms are only plain text

test('plain text is recognised under the names it has on Linux, Electron\'s wrapping of them included', () => {
  assert.equal(isPlainTextForms(['text/plain']), true)
  assert.equal(isPlainTextForms(['text/plain;charset=utf-8']), true)
  assert.equal(isPlainTextForms(LINUX_TEXT_FORMS), true)
  assert.equal(isPlainTextForms(X11_TEXT_NAMES), true)
  assert.equal(isPlainTextForms(['text/plain', 'electron application/osclipboard;format="COMPOUND_TEXT"']), true)
})

test('a copy that has anything but text in it is not plain text, whatever else it lists', () => {
  assert.equal(isPlainTextForms(['image/png']), false)
  assert.equal(isPlainTextForms(['text/plain', 'text/html']), false)
  assert.equal(isPlainTextForms([...LINUX_TEXT_FORMS, 'text/html']), false)
  assert.equal(isPlainTextForms([...LINUX_TEXT_FORMS, 'electron application/osclipboard;format="text/html"']), false)
  assert.equal(isPlainTextForms([...X11_TEXT_NAMES, 'text/uri-list']), false)
  assert.equal(isPlainTextForms([...X11_TEXT_NAMES, 'x-special/gnome-copied-files']), false)
  assert.equal(isPlainTextForms([...LINUX_TEXT_FORMS, 'electron application/osclipboard;format="image/png"']), false)
  // A name that only starts like text/plain is not it.
  assert.equal(isPlainTextForms(['text/plainly-not']), false)
  assert.equal(isPlainTextForms(['text/rtf']), false)
})

// MARK: - paste.ts on an Electron that lists text the way Linux does

class Item {
  types: string[]
  constructor(readonly payload: Record<string, string>) { this.types = Object.keys(payload) }
  async getType(type: string) { return this.payload[type] }
}

/** The one item Electron makes of a text it wrote on Linux: its text plus the native names, all the same text. */
const linuxText = (value: string) => new Item(Object.fromEntries(LINUX_TEXT_FORMS.map(form => [form, value])))

/** An Electron clipboard that lists plain text as Linux does; `text` is what it holds as text. */
function linuxClipboard(items: Item[]) {
  let held = items
  const text = () => held.map(item => item.payload['text/plain'] ?? '').join('')
  return {
    get types() { return held.map(item => item.types.join('+')).join('|') },
    get text() { return text() },
    set(next: Item[]) { held = next },
    clipboard: {
      async read() { return held },
      async readText() { return text() },
      writeText(value: string) { held = [linuxText(value)] },
      async write(written: Item[]) { held = written },
      clear() { held = [] },
    },
  }
}

function loadPaste(clipboard: unknown) {
  const internals = Module as unknown as { _load(request: string, ...rest: unknown[]): unknown }
  const real = internals._load
  internals._load = function (this: unknown, request: string, ...rest: unknown[]) { return request === 'electron' ? { clipboard, ClipboardItem: Item } : real.call(this, request, ...rest) }
  const file = require.resolve('../src/main/paste')
  delete require.cache[file]
  try { return require('../src/main/paste') as typeof import('../src/main/paste') } finally { internals._load = real; delete require.cache[file] }
}

const image = () => new Item({ 'image/png': 'PNG-BYTES-OF-THE-PICTURE' })

test('VM-01: the image that was on the clipboard comes back after the paste, with Electron\'s Linux forms', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  let seenWhenPasting = ''
  const outcome = await deliver('AUDIT RESTORE IMAGE 958.', () => { seenWhenPasting = board.text }, false)
  assert.equal(outcome.pasted, true)
  assert.equal(seenWhenPasting, 'AUDIT RESTORE IMAGE 958.', 'the field got the transcript')
  await flushHandback()
  assert.equal(board.types, 'image/png', 'the picture is back, not the transcript')
})

test('VM-01: a plain text that was on the clipboard comes back too, as text and without the system\'s names for it', async () => {
  const board = linuxClipboard([linuxText('what the user had copied')])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  await flushHandback()
  assert.equal(board.text, 'what the user had copied')
  assert.equal(board.types, 'text/plain', 'the aliases are made again by the system')
})

test('VM-01: text with formatting that was on the clipboard comes back with its formatting', async () => {
  const board = linuxClipboard([new Item({ 'text/plain': 'bold words', 'text/html': '<b>bold words</b>', 'electron application/osclipboard;format="UTF8_STRING"': 'bold words' })])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  await flushHandback()
  assert.equal(board.types, 'text/plain+text/html')
  assert.equal(board.text, 'bold words')
})

test('VM-01: an empty clipboard is empty again', async () => {
  const board = linuxClipboard([])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  await flushHandback()
  assert.equal(board.types, '')
})

test('VM-01: an image the user copied after the paste stays', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  const newer = new Item({ 'image/png': 'A-NEWER-PICTURE' })
  board.set([newer])
  await flushHandback()
  assert.equal(board.types, 'image/png')
  assert.equal(await board.clipboard.read().then(items => items[0] === newer), true, 'the newer picture, untouched')
})

test('VM-01: other text the user copied after the paste stays', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  board.set([linuxText('copied by the user meanwhile')])
  await flushHandback()
  assert.equal(board.text, 'copied by the user meanwhile')
})

test('VM-01: the same words copied with their formatting stay, the transcript\'s aliases or not', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  const rich = new Item({ 'text/plain': 'transcript', 'text/html': '<b>transcript</b>', 'electron application/osclipboard;format="UTF8_STRING"': 'transcript' })
  board.set([rich])
  await flushHandback()
  assert.equal(board.types, 'text/plain+text/html+electron application/osclipboard;format="UTF8_STRING"')
})

test('VM-01: the same words copied together with a picture stay', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, false)
  board.set([new Item({ 'text/plain': 'transcript', 'electron application/osclipboard;format="image/png"': 'PNG' })])
  await flushHandback()
  assert.equal(board.types, 'text/plain+electron application/osclipboard;format="image/png"')
})

test('VM-01: where the user keeps the transcript on the clipboard, it stays', async () => {
  const board = linuxClipboard([image()])
  const { deliver } = loadPaste(board.clipboard)
  await deliver('transcript', () => {}, true)
  await flushHandback()
  assert.equal(board.text, 'transcript')
})

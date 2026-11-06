import assert from 'node:assert/strict'
import test from 'node:test'
import { PausedEditor, type TextEdit } from '../src/renderer/pausedEditor'

function editorTest(run: (h: { editor: PausedEditor; field: any; sent: TextEdit[] }) => void) {
  const listeners = new Map<string, () => void>()
  const field = {
    value: '', selectionStart: 0, selectionEnd: 0, scrollHeight: 20, style: {}, parentElement: null as any,
    addEventListener: (name: string, callback: () => void) => listeners.set(name, callback),
    setSelectionRange(start: number, end: number) { this.selectionStart = start; this.selectionEnd = end },
    input(value: string) { this.value = value; this.selectionStart = this.selectionEnd = value.length; listeners.get('input')!() },
    select(at: number) { this.selectionStart = this.selectionEnd = at; listeners.get('mouseup')!() },
  }
  const host = { replaceChildren(child: any) { child.parentElement = this } }
  const documentBefore = globalThis.document
  globalThis.document = { createElement: () => field, activeElement: field } as unknown as Document
  try {
    const sent: TextEdit[] = []
    const editor = new PausedEditor(host as unknown as HTMLElement, edit => sent.push(edit))
    run({ editor, field, sent })
  } finally {
    globalThis.document = documentBefore
  }
}

test('an earlier main-process repaint cannot erase a newer typed correction', () => editorTest(({ editor, field, sent }) => {
  editor.show('Hello', 1, 0, 'Edit dictation')
  field.input('Hello a')
  field.input('Hello ab')
  editor.show('Hello a', 1, 1, 'Edit dictation')
  assert.equal(field.value, 'Hello ab')
  assert.equal(field.selectionStart, 8)
  assert.deepEqual(sent.map(({ before, text, sequence }) => ({ before, text, sequence })), [
    { before: 'Hello', text: 'Hello a', sequence: 1 },
    { before: 'Hello a', text: 'Hello ab', sequence: 2 },
  ])
  editor.show('Hello ab', 1, 2, 'Edit dictation')
  assert.equal(field.selectionStart, 8)
}))

test('a new dictation replaces the old editor even when an earlier edit was pending', () => editorTest(({ editor, field, sent }) => {
  editor.show('Old', 1, 0, 'Edit dictation'); field.input('Old correction')
  editor.show('New', 2, 0, 'Edit dictation')
  assert.equal(field.value, 'New')
  field.input('New correction')
  assert.equal(sent.at(-1)?.session, 2)
  assert.equal(sent.at(-1)?.before, 'New')
}))

test('typing after editing closes cannot alter the dictation', () => editorTest(({ editor, field, sent }) => {
  editor.show('Hello', 1, 0, 'Edit dictation')
  editor.hide(); field.input('late edit')
  assert.deepEqual(sent, [])
}))

test('clicking the same caret offset after resuming is sent for the next pause too', () => editorTest(({ editor, field, sent }) => {
  editor.show('Hello', 1, 0, 'Edit dictation'); field.select(5)
  editor.hide()
  editor.show('Hello world', 1, 1, 'Edit dictation'); field.select(5)
  assert.equal(sent.length, 2)
  assert.equal(sent[1].before, 'Hello world')
  assert.equal(sent[1].caret, 5)
}))

import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'
import { deferred, disposeAll, phase, setup, settle } from './sessionHarness'

afterEach(disposeAll)

test('clicking the unchanged paused text at its end keeps the recording context', async () => {
  const lengths: number[] = []
  const h = setup(['Hello ', 'world'], { transcribe: async samples => {
    lengths.push(samples.length)
    return lengths.length === 1 ? 'Hello' : 'Hello world'
  } })
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.editText(h.session.editingSession, 'Hello', 'Hello', 5), true)
  h.session.toggleMicrophone(); await settle(); h.sources[1].say()
  h.session.press(); await settle()
  assert.deepEqual(lengths, [60, 110])
  assert.deepEqual(h.delivered, ['Hello world'])
})

test('paused corrections survive resuming and the final delivery', async () => {
  const h = setup(['Hello Barket', ' works'])
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.canEdit, true)
  assert.equal(h.session.editText(h.session.editingSession, 'Hello Barket', 'Hello Bark', 10), true)
  h.session.toggleMicrophone(); await settle(); h.sources[1].say()
  h.session.press(); await settle()
  assert.deepEqual(h.delivered, ['Hello Bark works'])
})

test('paused selection and replacement allow multiline text and UTF-16 caret offsets', async () => {
  const h = setup(['Hello', 'great '])
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.canEdit, true)
  const corrected = 'Hi 🦆\nSatz'
  assert.equal(h.session.editText(h.session.editingSession, 'Hello', corrected, 6), true)
  h.session.toggleMicrophone(); await settle(); h.sources[1].say()
  h.session.press(); await settle()
  assert.deepEqual(h.delivered, ['Hi 🦆\ngreat Satz'])
})

test('editing waits for the paused audio and late transcript rather than dropping it', async () => {
  const answer = deferred<string>()
  const h = setup(['Hello'], { transcribe: () => answer.promise })
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.canEdit, false)
  assert.equal(h.session.editText(h.session.editingSession, '', 'replacement', 11), false)
  answer.resolve('Hello'); await settle()
  assert.equal(h.session.canEdit, true)
  h.session.press(); await settle()
  assert.deepEqual(h.delivered, ['Hello'])
})

test('an old editor cannot change a newer dictation or an unexpected text snapshot', async () => {
  const h = setup(['Hello', 'Hello'])
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.canEdit, true)
  const old = h.session.editingSession
  h.session.discard(); h.session.press(); await settle(); h.sources[1].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(phase(h.session), 'paused')
  assert.equal(h.session.editText(old, 'Hello', 'stale', 5), false)
  assert.equal(h.session.editText(h.session.editingSession, 'wrong snapshot', 'stale', 5), false)
  assert.equal(h.session.plainText(), 'Hello')
})

test('select all and deleting the text still permits a new recording', async () => {
  const h = setup(['Hello', 'Replacement'])
  h.session.press(); await settle(); h.sources[0].say()
  h.session.toggleMicrophone(); await settle()
  assert.equal(h.session.canEdit, true)
  assert.equal(h.session.editText(h.session.editingSession, 'Hello', '', 0), true)
  h.session.toggleMicrophone(); await settle(); h.sources[1].say()
  h.session.press(); await settle()
  assert.deepEqual(h.delivered, ['Replacement'])
})

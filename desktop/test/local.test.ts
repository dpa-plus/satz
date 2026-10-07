import assert from 'node:assert/strict'
import test from 'node:test'
import { windows } from '../src/core/windows'
import { keepEveryWord } from '../src/main/local'

test('a dictation under 30 seconds stays one piece', () => {
  const pieces = windows(new Float32Array(16_000 * 29))
  assert.equal(pieces.length, 1)
})

test('a long dictation is cut in its quietest moment, and nothing is lost', () => {
  const rate = 16_000
  const audio = new Float32Array(rate * 70).fill(0.5)
  // Quiet at 24 s: the cut belongs there, not at 30.
  audio.fill(0, 24 * rate, 24 * rate + rate / 5)
  const pieces = windows(audio)
  assert.ok(pieces.every(piece => piece.length <= 30 * rate))
  assert.ok(Math.abs(pieces[0].length - 24.1 * rate) < rate / 5)
  assert.equal(pieces.reduce((sum, piece) => sum + piece.length, 0), audio.length)
})

test('the word list is kept only when it costs no words', () => {
  const plain = 'Schreib mir eine Funktion. Thanks for the update, Thursday works for me.'
  assert.equal(keepEveryWord('Schreib mir eine Funktion.', plain).chosen, 'plain')
  assert.equal(keepEveryWord('Schreib mir eine Funktion. Thanks for the update, Thursday works for me.', plain).chosen, 'prompted')
  // A spelling fixed by the list may merge or split a word or two.
  assert.equal(keepEveryWord('Schreib mir eine Funktion. Thanks for the update Thursday works for me', plain).chosen, 'prompted')
})

import assert from 'node:assert/strict'
import test from 'node:test'
import { hasSpeech, keepEveryWord } from '../src/core/speech'
import { windows } from '../src/core/windows'

test('the word list is kept only when it costs no words', () => {
  const plain = 'Schreib mir eine Funktion. Thanks for the update, Thursday works for me.'
  assert.equal(keepEveryWord('Schreib mir eine Funktion.', plain).chosen, 'plain')
  assert.equal(keepEveryWord(plain, plain).chosen, 'prompted')
  assert.equal(keepEveryWord('Schreib mir eine Funktion. Thanks for the update Thursday works for me', plain).chosen, 'prompted')
})

test('a dropped sentence in a long dictation is caught though most words remain', () => {
  const german = Array.from({ length: 12 }, (_, k) => `Punkt ${k + 1} ist erledigt und wir machen weiter.`).join(' ')
  assert.equal(keepEveryWord(german, `${german} Thanks for the update, Thursday works for me.`).chosen, 'plain')
})

test('a spelling the list fixed keeps the prompted text, and nothing heard stays nothing', () => {
  assert.equal(keepEveryWord('Wir deployen auf Kubernetes und schauen in Grafana nach.', 'Wir deployen auf Kuber Netties und schauen in Grafana nach.').chosen, 'prompted')
  assert.deepEqual(keepEveryWord('Klammer auf, Klammer zu.', ''), { text: '', chosen: 'plain' })
})

test('silence, room tone and a click have no speech; quiet speech does', () => {
  assert.equal(hasSpeech(new Float32Array(32_000)), false)
  const room = Float32Array.from({ length: 32_000 }, (_, k) => Math.sin(k * 0.7) * 0.0005)
  assert.equal(hasSpeech(room), false)
  const click = room.slice(); click.fill(0.5, 1000, 1200)
  assert.equal(hasSpeech(click), false)
  const speech = Float32Array.from({ length: 16_000 }, (_, k) => (k > 8000 ? Math.sin(k * 0.2) * 0.025 : 0))
  assert.equal(hasSpeech(speech), true)
})

test('a longer made-up phrase never beats a dropped sentence', () => {
  const plain = 'Schick mir die Unterlagen. Bitte die Rechnung nicht bezahlen.'
  const prompted = 'Schick mir die Unterlagen. Vielen Dank fürs Zuschauen und bis zum nächsten Mal.'
  assert.equal(keepEveryWord(prompted, plain).chosen, 'plain')
})

test('quiet speech counts, steady quiet noise does not', () => {
  // Speech-like bursts at 2 % amplitude after a quiet start.
  const quiet = Float32Array.from({ length: 48_000 }, (_, k) => (k > 8000 && Math.floor(k / 2400) % 2 === 0 ? Math.sin(k * 0.2) * 0.004 : Math.sin(k) * 0.0001))
  assert.equal(hasSpeech(quiet), true)
  const hum = Float32Array.from({ length: 48_000 }, (_, k) => Math.sin(k * 0.05) * 0.003)
  assert.equal(hasSpeech(hum), false)
})

test('a long dictation is cut in its quietest moment, and nothing is lost', () => {
  const rate = 16_000
  const audio = new Float32Array(rate * 70).fill(0.5)
  audio.fill(0, 24 * rate, 24 * rate + rate / 5)
  const pieces = windows(audio, rate, 30 * rate - rate / 2)
  assert.ok(pieces.every(piece => piece.length <= 29.5 * rate))
  assert.ok(Math.abs(pieces[0].length - 24.1 * rate) < rate / 5)
  assert.equal(pieces.reduce((sum, piece) => sum + piece.length, 0), audio.length)
})

import assert from 'node:assert/strict'
import test from 'node:test'
import { cutAtLastSegment, hasSpeech, keepEveryWord } from '../src/core/speech'

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

test('a window goes on after its last complete segment', () => {
  const T = 50000 // timestamp_begin; T + n is n * 0.02 s
  const text = [1, 2, 3]
  // <0.00> a b c <5.00><5.00> d e <9.00><9.00> f g   (last segment unfinished)
  const tokens = [T, ...text, T + 250, T + 250, 4, 5, T + 450, T + 450, 6, 7]
  const cut = cutAtLastSegment(tokens, T)
  assert.equal(cut.seconds, 9)
  assert.deepEqual(cut.keep, [T, 1, 2, 3, T + 250, T + 250, 4, 5, T + 450])
  // Ends on a closing timestamp: the whole window is used.
  assert.equal(cutAtLastSegment([T, 1, 2, T + 300], T).seconds, null)
  // No timestamps at all: the whole window.
  assert.equal(cutAtLastSegment([1, 2, 3], T).seconds, null)
})

test('when both texts lost words, the one that kept more wins', () => {
  const prompted = 'Erstens, der Bericht ist fertig. Zweitens, die Rechnung geht raus. Drittens, das Meeting.'
  const plain = 'Bericht ist fertig. Zweitens, die Rechnung geht raus.'
  assert.equal(keepEveryWord(prompted, plain).chosen, 'prompted')
})

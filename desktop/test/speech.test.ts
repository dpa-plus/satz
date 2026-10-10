import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import path from 'node:path'
import { hasSpeech, isSteady, keepEveryWord } from '../src/core/speech'
import { decodeWAV, resample } from '../src/core/wav'
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

test('a passage the prompt brought in is not kept', () => {
  const plain = 'Schreib mir eine Funktion. Danach summieren.'
  const prompted = 'Schreib mir eine Funktion. Danach summieren. Schreib mir eine Funktion, die alle Rechnungen liest.'
  assert.equal(keepEveryWord(prompted, plain).chosen, 'plain')
})

test('a steady level (a fan, hiss, hum) is told from speech by how little it rises and falls; speech is not steady, silence is no judgment', () => {
  const rate = 16_000
  let seed = 3
  const noise = (seconds: number, amplitude: number) => new Float32Array(seconds * rate).map(() => { seed = (seed * 16807) % 2147483647; return (seed / 2147483647 - 0.5) * amplitude })
  // Loud enough to count as speech by level, which is why hasSpeech lets it through.
  const fan = noise(12, 0.08)
  assert.equal(hasSpeech(fan, rate), true)
  assert.equal(isSteady(fan, rate), true)
  const hum = new Float32Array(12 * rate).map((_, i) => 0.05 * Math.sin((2 * Math.PI * 50 * i) / rate))
  assert.equal(isSteady(hum, rate), true)
  // The real clip bundled with satz: 10 s of a book read aloud, with its pauses.
  const { samples, sampleRate } = decodeWAV(fs.readFileSync(path.join(__dirname, '..', 'assets', 'speedtest.wav')))
  const speech = resample(samples, sampleRate)
  assert.equal(isSteady(speech, rate), false)
  // Speech over the same fan.
  const mixed = Float32Array.from(speech, (value, i) => value + fan[i])
  assert.equal(isSteady(mixed, rate), false)
  // Nothing to judge: too short, or digital silence (hasSpeech says no to that already).
  assert.equal(isSteady(noise(0.5, 0.08), rate), false)
  assert.equal(isSteady(new Float32Array(5 * rate), rate), false)
  // A pause in the middle makes it not steady.
  const paused = Float32Array.from(fan)
  paused.fill(0, 4 * rate, 6 * rate)
  assert.equal(isSteady(paused, rate), false)
})

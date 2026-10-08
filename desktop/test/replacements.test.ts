import { test } from 'node:test'
import assert from 'node:assert/strict'
import { applyReplacements, phrases, replacement, standardReplacements, swapPredefined } from '../src/core/replacements'
import { fit } from '../src/core/textFitting'

// The inputs are what MAI-Transcribe and GPT Transcribe sent back for spoken
// punctuation on 03.10.2026 (the Mac app's ReplacementsTests).
const german = standardReplacements('de')
const english = standardReplacements('en')

test('German brackets lose the model\'s commas', () => {
  assert.equal(applyReplacements(german, 'Schreib mir eine Funktion, Klammer auf Name, Klammer zu. Er hat gesagt, das geht.'),
    'Schreib mir eine Funktion (Name). Er hat gesagt, das geht.')
})

test('quotes open and close in turn', () => {
  assert.equal(applyReplacements(german, 'Er hat gesagt, Zitat Anfang, wir liefern am Freitag, Zitat Ende. Punkt.'),
    'Er hat gesagt "wir liefern am Freitag". Punkt.')
})

test('punctuation words become marks', () => {
  assert.equal(applyReplacements(german, 'Und noch was, Doppelpunkt, der Test ist rot, Ausrufezeichen.'), 'Und noch was: der Test ist rot!')
})

test('line breaks swallow the full stop after them', () => {
  assert.equal(applyReplacements(german, 'Erste Zeile. Neue Zeile. Zweite Zeile. Neuer Absatz. Dritte.'), 'Erste Zeile.\nZweite Zeile.\n\nDritte.')
})

test('English works the same way', () => {
  assert.equal(applyReplacements(english, 'Write a function open bracket name close bracket. New line. Done'), 'Write a function (name).\nDone')
})

test('German low and high quotes pair up', () => {
  const rules = [replacement('Zitat Anfang', '„'), replacement('Zitat Ende', '“')]
  assert.equal(applyReplacements(rules, 'Er hat gesagt, Zitat Anfang, wir liefern am Freitag, Zitat Ende.'), 'Er hat gesagt „wir liefern am Freitag“.')
})

test('a new line starts with a capital', () => {
  assert.equal(applyReplacements(german, 'Erste Zeile, neue Zeile, zweite Zeile, Fragezeichen, und dann?'), 'Erste Zeile\nZweite Zeile? Und dann?')
})

test('rules that are off do nothing', () => {
  assert.equal(applyReplacements(german, 'Der Punkt ist, das geht nicht.'), 'Der Punkt ist, das geht nicht.')
})

test('letter codes match however the model spells them', () => {
  const rules = [replacement('XX', '('), replacement('YY', ')')]
  assert.equal(applyReplacements(rules, 'Funktion XX Name YY und dann'), 'Funktion (Name) und dann')
  assert.equal(applyReplacements(rules, 'Funktion x x Name y y und dann'), 'Funktion (Name) und dann')
  assert.equal(applyReplacements(rules, 'Funktion X. X. Name Y. Y. und dann'), 'Funktion (Name) und dann')
})

test('only whole words trigger', () => {
  assert.equal(applyReplacements(german, 'Zwei Doppelpunkte hintereinander'), 'Zwei Doppelpunkte hintereinander')
  assert.equal(applyReplacements([replacement('XX', '(')], 'Größe XXL bitte'), 'Größe XXL bitte')
})

test('plain replacements are inserted as they are', () => {
  assert.equal(applyReplacements([replacement('meine Mail', 'name@example.com')], 'Schick es an meine Mail, danke.'), 'Schick es an name@example.com, danke.')
})

test('case does not matter', () => {
  assert.equal(applyReplacements(german, 'KLAMMER AUF test klammer zu'), '(test)')
})

test('no rules leaves the text alone', () => {
  assert.equal(applyReplacements([], 'Klammer auf, nichts passiert.'), 'Klammer auf, nichts passiert.')
})

test('the word list gets every trigger that is on', () => {
  assert.deepEqual(phrases([replacement('XX', '('), replacement('Punkt', '.', false), replacement(' ', '?')]), ['XX'])
})

test('a trigger starting with punctuation does not crash', () => {
  assert.notEqual(applyReplacements([...german, replacement(': Strich', '-')], 'Doppelpunkt : Strich weiter'), '')
})

test('each language has its own predefined rules', () => {
  assert.ok(german.some(r => r.spoken === 'Klammer auf') && !german.some(r => r.spoken === 'open bracket'))
  assert.ok(english.some(r => r.spoken === 'open bracket') && !english.some(r => r.spoken === 'Klammer auf'))
  assert.equal(applyReplacements(english, 'He said, open quote, not today, close quote.'), 'He said "not today".')
})

test('switching the spoken language keeps the user\'s own rules', () => {
  const rules = [...german, replacement('Smiley', ':)')]
  const swapped = swapPredefined(rules, 'de', 'en')
  assert.ok(swapped.some(r => r.spoken === 'open bracket'))
  assert.ok(swapped.some(r => r.spoken === 'Smiley'))
  assert.ok(!swapped.some(r => r.spoken === 'Klammer auf'))
})

test('a line break at the edge of a recording survives fitting', () => {
  const piece = applyReplacements(german, 'Neue Zeile, zweiter Punkt.')
  const text = 'Erster Punkt.'
  assert.equal(text + fit(piece, text, { location: text.length, length: 0 }), 'Erster Punkt.\nZweiter Punkt.')
})

test('a spoken phrase with a hyphen works and never breaks the dictation', () => {
  const rules = [{ id: 'm', spoken: 'meine E-Mail', written: 'eli@example.com', isOn: true }, { id: 'b', spoken: 'Klammer auf', written: '(', isOn: true }]
  assert.equal(applyReplacements(rules, 'Schick es an meine E-Mail bitte'), 'Schick es an eli@example.com bitte')
  assert.equal(applyReplacements(rules, 'Klammer auf hallo'), '(hallo')
})

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { fit, lowerFirstWordIfSafe } from '../src/core/textFitting'

// Ported from the Mac app's TextFittingTests.
function insert(transcript: string, text: string, after: string) {
  const location = text.indexOf(after) + after.length
  return text.slice(0, location) + fit(transcript, text, { location, length: 0 }) + text.slice(location)
}

test('a mid-sentence insert loses its full stop and capital', () => {
  assert.equal(insert('Nur die PDF-Dateien.', 'Schreib mir eine Funktion, die alle Rechnungen liest.', 'Funktion'),
    'Schreib mir eine Funktion nur die PDF-Dateien, die alle Rechnungen liest.')
})

test('German nouns keep their capital', () => {
  assert.equal(insert('Rechnungen ohne Datum.', 'Bitte die Summe ausgeben.', 'Summe'), 'Bitte die Summe Rechnungen ohne Datum ausgeben.')
})

test('English lowers the first word but not acronyms or I', () => {
  assert.equal(lowerFirstWordIfSafe('Only the PDF files.'), 'only the PDF files.')
  assert.equal(lowerFirstWordIfSafe('PDF files only.'), 'PDF files only.')
  assert.equal(lowerFirstWordIfSafe('I think so.'), 'I think so.')
})

test('a new sentence stays a sentence', () => {
  assert.equal(insert('Und hier der zweite.', 'Das ist der erste Satz.', 'Satz.'), 'Das ist der erste Satz. Und hier der zweite.')
})

test('at the start nothing is added', () => {
  assert.equal(fit('Hallo Welt.', '', { location: 0, length: 0 }), 'Hallo Welt.')
})

test('the placeholder after the insert is skipped', () => {
  const text = 'Eine Funktion …, die liest.'
  assert.equal(fit('Nur PDFs.', text, { location: 'Eine Funktion'.length, length: 0 }, 2), ' nur PDFs')
})

test('an emoji counts as one character', () => {
  const text = 'Ich mag 🍕'
  assert.equal(fit('Und Pasta.', text, { location: text.length, length: 0 }), ' und Pasta.')
})

test('an empty transcript inserts nothing', () => {
  assert.equal(fit('   ', 'abc', { location: 1, length: 0 }), '')
})

test('English keeps names and I as they are', () => {
  assert.equal(lowerFirstWordIfSafe('Alice Johnson will join us.', 'Tell the team that will join us.'), 'Alice Johnson will join us.')
  assert.equal(lowerFirstWordIfSafe('I’m not sure.'), 'I’m not sure.')
  assert.equal(lowerFirstWordIfSafe('I, for one, agree.'), 'I, for one, agree.')
})

test('a mid-sentence insert before a noun loses its full stop', () => {
  const text = 'Ich habe gestern die Rechnung bezahlt.'
  const at = text.indexOf('die') + 3
  assert.equal(fit('Alte.', text, { location: at, length: 0 }), ' Alte')
})

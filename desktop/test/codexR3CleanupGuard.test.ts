import assert from 'node:assert/strict'
import test from 'node:test'
import { digitRuns, guard, keepsNumbers, keepsSigns, negationCount, numberRuns, numberWords, numberWordValue, numberWordValues, spellingFix, strictWords, words, type PresetLevel } from '../src/core/cleanup'
import { runCleanup, type CleanupJob } from '../src/core/cleanupRequest'

/*
 * Codex's third audit, CC-2 (14.10.2026): "Nur Zeichensetzung" promises that
 * every word stays, and the guard let "do not send" become "do send", 1000
 * become 9000 and three repetitions become one, because it counted a share of
 * the words and read 1000 and 9000 as a spelling mistake.
 *
 * The rules (the same ones run in Tests/SatzKitTests/CodexR3CleanupGuardTests.swift):
 *  1. "Nur Zeichensetzung": the words of the answer are the words of the
 *     dictation, in order. Only an obvious spelling fix may differ (v3:
 *     apostrophes inside words and ä ö ü ß are not changes, and a word of the
 *     vocabulary may stand for a misheard name).
 *  2. Every preset: no number in the answer that was not in the dictation
 *     (v3: 1.000 is 1000, a list marker is no number, and a number said in
 *     words may come back in digits, but only as its own value, each number
 *     word once: "um drei" is not "um 15 Uhr"; v4: the sign is part of the
 *     number, "-1000" is not "1000", "minus zwanzig" is -20).
 *  3. Every preset: exactly as many strong negations as the dictation had,
 *     not fewer and (v3) not more.
 *  4. A dictation of fewer than three words (fillers aside): every word of the
 *     answer is the same as one that was said, and (v3) the answer keeps a
 *     word, and (v4) every word that was said is still there: "nein danke" is
 *     not "Danke.".
 */

const presets: PresetLevel[] = ['punctuation', 'light', 'smooth', 'polished']
const accepts = (answer: string, said: string, level: PresetLevel | 'custom') => guard(said, answer, level)

/** What the audit fed both guards, and a few more of the same kind. */
const meaningChanged: [said: string, answer: string, why: string][] = [
  ['ich möchte die rechnung morgen nicht überweisen', 'Ich möchte die Rechnung morgen überweisen.', 'nicht dropped'],
  ['bitte überweise 1000 euro an max', 'Bitte überweise 9000 Euro an Max.', '1000 became 9000'],
  ['nein danke', 'Ja bitte.', 'a short answer reversed'],
  ['bitte nicht senden bitte nicht senden bitte nicht senden', 'Bitte nicht senden.', 'repetitions dropped'],
  ['please do not send 1000 euros to the customer tomorrow', 'Please do send 1000 euros to the customer tomorrow.', 'not dropped'],
  ['die nummer ist 12345678', 'Die Nummer ist 12345679.', '12345678 became 12345679'],
  ['不要发送', '请发送', 'one word without spaces, changed'],
]

// MARK: - What the audit reported

test('the reported answers are rejected at every preset', () => {
  for (const level of presets) for (const [said, answer, why] of meaningChanged) assert.equal(accepts(answer, said, level), false, `${level} ${why}`)
})

test('the own prompt still may answer anything, but not nothing', () => {
  for (const [said, answer, why] of meaningChanged) assert.equal(accepts(answer, said, 'custom'), true, why)
  assert.equal(accepts('  ', 'nein danke', 'custom'), false)
})

test('right punctuation still passes at every preset', () => {
  for (const level of presets) {
    assert.equal(accepts('Ich möchte die Rechnung morgen nicht überweisen.', 'ich möchte die rechnung morgen nicht überweisen', level), true, level)
    assert.equal(accepts('Bitte überweise 1000 Euro an Max.', 'bitte überweise 1000 euro an max', level), true, level)
    assert.equal(accepts('Bitte nicht senden, bitte nicht senden, bitte nicht senden.', 'bitte nicht senden bitte nicht senden bitte nicht senden', level), true, level)
    assert.equal(accepts('Please do not send 1000 euros to the customer tomorrow.', 'please do not send 1000 euros to the customer tomorrow', level), true, level)
    assert.equal(accepts('Die Nummer ist 12345678.', 'die nummer ist 12345678', level), true, level)
    assert.equal(accepts('Nein, danke.', 'nein danke', level), true, level)
  }
})

/** Through the client: the original is pasted, with the reason. */
test('the client pastes the original instead of the changed answer', async () => {
  const job = (text: string): CleanupJob => ({ provider: 'custom', base: 'http://127.0.0.1:9/v1', model: 'stand-in', key: 'KEY', level: 'punctuation', customPrompt: '', vocabulary: [], text })
  const reply = (answer: string) => async () => new Response(JSON.stringify({ choices: [{ message: { content: answer }, finish_reason: 'stop' }] }))
  for (const [said, answer, why] of meaningChanged) {
    const result = await runCleanup(job(said), reply(answer))
    assert.equal(result.kind, 'failed', why)
    if (result.kind === 'failed') assert.equal(result.reason, 'rejected', why)
  }
  const fine = await runCleanup(job('ich möchte die rechnung morgen nicht überweisen'), reply('Ich möchte die Rechnung morgen nicht überweisen.'))
  assert.equal(fine.kind, 'cleaned')
})

// MARK: - 1. Nur Zeichensetzung: every word stays, in order

test('the words of the answer are the words said', () => {
  const said = 'ähm ich komme morgen um 10 uhr'
  assert.equal(accepts('Ähm, ich komme morgen um 10 Uhr.', said, 'punctuation'), true)
  // Fillers are words too.
  assert.equal(accepts('Ich komme morgen um 10 Uhr.', said, 'punctuation'), false)
  // Added, dropped, merged, moved, repeated.
  assert.equal(accepts('Ähm, ich komme morgen alle um 10 Uhr.', said, 'punctuation'), false)
  assert.equal(accepts('Ähm, ich komme morgen um 10.', said, 'punctuation'), false)
  assert.equal(accepts('Ähm, ich komme morgen um 10 Uhr, Uhr.', said, 'punctuation'), false)
  assert.equal(accepts('Ich komme ähm morgen um 10 Uhr.', said, 'punctuation'), false)
  assert.equal(accepts('Ähm, ich komme morgen um 10Uhr.', said, 'punctuation'), false)
  // The same sentence at the next level may lose the filler.
  assert.equal(accepts('Ich komme morgen um 10 Uhr.', said, 'light'), true)
  // A stutter is a word, and stays.
  assert.equal(accepts('Wir sind morgen da.', 'wir sind sind morgen da', 'punctuation'), false)
  assert.equal(accepts('Wir sind morgen da.', 'wir sind sind morgen da', 'light'), true)
  // Same words, other order.
  assert.equal(accepts('Morgen gehe ich nach Hause.', 'ich gehe morgen nach hause', 'punctuation'), false)
})

test('a Greek final sigma is the same letter on both platforms', () => {
  // JavaScript lowercases "ΣΑΣ" to "σας", Swift used to say "σασ".
  assert.equal(accepts('Σας ευχαριστώ.', 'ΣΑΣ ΕΥΧΑΡΙΣΤΩ', 'punctuation'), true)
  assert.deepEqual(words('ΣΑΣ σας'), ['σασ', 'σασ'])
})

test('only an obvious spelling fix may differ', () => {
  // One letter added, dropped, changed, or two neighbours swapped; both words four letters or more, no digits.
  assert.equal(accepts('Das ist ein Test.', 'das ist ein tset', 'punctuation'), true)
  assert.equal(accepts('Das Projekt läuft.', 'das projeckt läuft', 'punctuation'), true)
  assert.equal(accepts('Ich mag Hunde.', 'ich mag hunnde', 'punctuation'), true)
  // Two letters off ("gefailed" and "gefailt" are one thing at the next level, two edits here), or another word.
  assert.equal(accepts('Wir testen das gefailt.', 'wir testen das gefailed', 'punctuation'), false)
  assert.equal(accepts('Das ist ein Hund.', 'das ist ein haus', 'punctuation'), false)
  // Under four letters nothing may change, not even a letter.
  assert.equal(accepts('Ich mag das nie.', 'ich mag das die', 'punctuation'), false)
  assert.equal(accepts('Ihr geht.', 'ich geht', 'punctuation'), false)
  // A word with a digit has to be the same word.
  assert.equal(accepts('Das Modell a1235 läuft.', 'das modell a1234 läuft', 'punctuation'), false)
  assert.equal(spellingFix('tset', 'test'), true)
  assert.equal(spellingFix('tset', 'tesst1'), false)
  assert.equal(spellingFix('ich', 'ihc'), false)
  assert.equal(spellingFix('a1234', 'a1235'), false)
  // Letters outside the BMP count as one letter each, as the Mac counts scalars.
  assert.equal(spellingFix('a𝒳bc', 'a𝒴bc'), true)
})

// v3: apostrophes, umlauts and the word list at "Nur Zeichensetzung"

test('an apostrophe inside a word and ä ö ü ß are not changes of a word', () => {
  assert.deepEqual(strictWords("Geht's, don’t, O'Brien, l`amour, na´ja, don\u{2BC}t"), ['gehts', 'dont', 'obrien', 'lamour', 'naja', 'dont'])
  // Only between two letters: a quote, a lone apostrophe and the opening quote separate words as before.
  assert.deepEqual(strictWords("'ja' 'nein' ja' it‘s"), ['ja', 'nein', 'ja', 'it', 's'])
  assert.deepEqual(strictWords("don''t"), ['don', 't'])
  assert.deepEqual(strictWords('Übersehen Grüße schön Öl Äpfel Straße STRASSE GRO\u{1E9E}'), ['uebersehen', 'gruesse', 'schoen', 'oel', 'aepfel', 'strasse', 'strasse', 'gross'])
  // The other presets keep the words as they are.
  assert.deepEqual(words("geht's Grüße"), ['geht', 's', 'grüße'])
})

test('"Nur Zeichensetzung" takes geht\'s for gehts and uebersehen for übersehen', () => {
  assert.equal(accepts("Wie geht's dir heute?", 'wie gehts dir heute', 'punctuation'), true)
  assert.equal(accepts('Wie geht’s dir heute?', 'wie gehts dir heute', 'punctuation'), true)
  assert.equal(accepts('Wie gehts dir heute?', "wie geht's dir heute", 'punctuation'), true)
  assert.equal(accepts("I don't think so.", 'i dont think so', 'punctuation'), true)
  assert.equal(accepts('Ich habe nichts übersehen.', 'ich habe nichts uebersehen', 'punctuation'), true)
  assert.equal(accepts('Ich habe nichts uebersehen.', 'ich habe nichts übersehen', 'punctuation'), true)
  assert.equal(accepts('Wir freuen uns auf die Grüße.', 'wir freuen uns auf die gruesse', 'punctuation'), true)
  assert.equal(accepts('Die Straße ist lang.', 'die strasse ist lang', 'punctuation'), true)
  // A contraction of two words said is one word where two were said; the folded words may still differ by a spelling fix, but not be other words.
  assert.equal(accepts("Wie geht's dir?", 'wie geht es dir', 'punctuation'), false)
  assert.equal(accepts('Ich habe nichts übersehen.', 'ich habe nichts ubersehen', 'punctuation'), true)
  assert.equal(accepts('Ich habe nichts gesehen.', 'ich habe nichts übersehen', 'punctuation'), false)
})

test('"Nur Zeichensetzung" takes a word of the word list for a misheard name, and nothing else', () => {
  const said = 'hallo yannick wie gehts'
  const answer = "Hallo Jannik, wie geht's?"
  assert.equal(guard(said, answer, 'punctuation', ['Jannik']), true)
  assert.equal(guard(said, answer, 'punctuation', []), false)
  assert.equal(guard(said, answer, 'punctuation', ['Daniel']), false)
  // A name in the list written with an umlaut is compared as it is folded.
  assert.equal(guard('ich habe herrn miller getroffen', 'Ich habe Herrn Müller getroffen.', 'punctuation', ['Müller']), true)
  assert.equal(guard('ich habe herrn miller getroffen', 'Ich habe Herrn Müller getroffen.', 'punctuation', []), false)
  // The word list does not allow a word added, dropped or moved, nor a lost negation.
  assert.equal(guard('hallo yannick', 'Hallo Jannik Daniel.', 'punctuation', ['Jannik', 'Daniel']), false)
  assert.equal(guard('hallo yannick wie gehts', 'Hallo Jannik.', 'punctuation', ['Jannik']), false)
  assert.equal(guard('yannick hallo', 'Hallo Jannik.', 'punctuation', ['Jannik']), false)
  assert.equal(guard('hallo yannick nicht', 'Hallo Jannik.', 'punctuation', ['Jannik']), false)
  // A number is not a name: the number rule runs first.
  assert.equal(guard('ich zahle 1000 euro', 'Ich zahle 9000 Euro.', 'punctuation', ['9000']), false)
})

// MARK: - 2. Numbers

test('no number appears or changes, at any preset', () => {
  for (const level of presets) {
    assert.equal(accepts('Ich will 15 Euro für das Essen heute Abend, danke.', 'ich will 5 euro für das essen heute abend danke', level), false, level)
    assert.equal(accepts('Die Nummer ist 12345679 und gilt nur heute, danke.', 'die nummer ist 12345678 und gilt nur heute danke', level), false, level)
    assert.equal(accepts('Es kostet 9.000 Euro im Monat, danke.', 'es kostet 1000 euro im monat danke', level), false, level)
    // The same digits are fine, wherever the separators stand.
    assert.equal(accepts('Wir brauchen noch 3,5 Stunden für das Projekt.', 'wir brauchen noch 3,5 stunden für das projekt', level), true, level)
    assert.equal(accepts('Es ist 10:30 Uhr, danke.', 'es ist 10 30 uhr danke', level), true, level)
  }
})

test('a number may disappear when the speaker corrects herself', () => {
  for (const level of ['light', 'smooth', 'polished'] as const) {
    assert.equal(accepts('Wir treffen uns heute um 4 im Büro.', 'wir treffen uns heute um 3 nein um 4 im büro', level), true, level)
  }
})

test('digits in any script count', () => {
  assert.deepEqual([...digitRuns('a1 b٢٣ 4,5')].sort(), ['1', '4', '5', '٢٣'])
  assert.equal(accepts('Ich habe ٢٣ Äpfel gekauft.', 'ich habe 23 äpfel gekauft', 'light'), false)
})

// v3: what counts as one number

test('a thousands separator and exactly three digits make one number', () => {
  const thin = '\u{2009}'
  for (const written of ['1.000', '1,000', "1'000", '1’000', '1 000', `1${thin}000`]) assert.deepEqual(numberRuns(written), ['1000'], written)
  assert.deepEqual(numberRuns('1 000 000 und 2.500,50'), ['1000000', '2500', '50'])
  assert.deepEqual(numberRuns('12.345.678'), ['12345678'])
  assert.deepEqual(numberRuns('٢.٠٠٠'), ['٢٠٠٠'])
  // Not exactly three digits, or another separator: separate numbers.
  assert.deepEqual(numberRuns('1.00'), ['1', '00'])
  assert.deepEqual(numberRuns('1.0000'), ['1', '0000'])
  assert.deepEqual(numberRuns('1-000'), ['1', '000'])
  assert.deepEqual(numberRuns('1\u{A0}000'), ['1', '000'])
  assert.deepEqual(numberRuns('3,5 und 10:30'), ['3', '5', '10', '30'])
  assert.deepEqual([...digitRuns('1.000 und 1000 und 1 000')], ['1000'])
})

test('1.000 is 1000, in either direction, at every preset but "Nur Zeichensetzung"', () => {
  for (const level of ['light', 'smooth', 'polished'] as const) {
    assert.equal(accepts('Die Summe ist 1.000 Euro für die Rechnung, danke.', 'die summe ist 1000 euro für die rechnung danke', level), true, level)
    assert.equal(accepts('Die Summe ist 2500 Euro für die Rechnung, danke.', 'die summe ist 2,500 euro für die rechnung danke', level), true, level)
    assert.equal(accepts('Es kostet 1.000.000 Euro im Monat, danke.', 'es kostet 1 000 000 euro im monat danke', level), true, level)
    // Another number, or one group more, is still another number.
    assert.equal(accepts('Die Summe ist 9.000 Euro für die Rechnung, danke.', 'die summe ist 1000 euro für die rechnung danke', level), false, level)
    assert.equal(accepts('Die Summe ist 1.000.000 Euro für die Rechnung, danke.', 'die summe ist 1000 euro für die rechnung danke', level), false, level)
  }
  // There every word stays, and 1.000 is two words where 1000 was one.
  assert.equal(accepts('Die Summe ist 1.000 Euro.', 'die summe ist 1000 euro', 'punctuation'), false)
  assert.equal(accepts('Die Summe ist 1000 Euro.', 'die summe ist 1000 euro', 'punctuation'), true)
})

// v3: list markers

test('the numbers of a list are markers, not numbers', () => {
  assert.deepEqual(numberRuns('1. Milch\n2) Brot\n  3. Eier', true), [])
  assert.deepEqual(numberRuns('1. Milch\n2) Brot', false), ['1', '2'])
  assert.deepEqual(numberRuns('10) Milch', true), [])
  // Every kind of line break starts a line, and so does the start of the text; indented by spaces or a tab.
  assert.deepEqual(numberRuns('Liste:\r\n1. Milch\u{2028}2. Brot\u{85}3. Eier\u{B}4. Tee\u{C}5. Kaffee\u{2029}\t6. Wasser', true), [])
  // Only at the start of a line, and only with "." or ")" right behind the digits.
  assert.deepEqual(numberRuns('Milch 1. Brot', true), ['1'])
  // v4: a dash with digits right behind it is a sign, bullet or not (the answer is judged as a number with a sign).
  assert.deepEqual(numberRuns('Milch\n- 1. Brot', true), ['-1'])
  assert.deepEqual(numberRuns('1 Milch', true), ['1'])
  assert.deepEqual(numberRuns('1: Milch', true), ['1'])
  assert.deepEqual(numberRuns('1 . Milch', true), ['1'])
  assert.deepEqual(numberRuns('1,5 Liter', true), ['1', '5'])
  // A grouped number is read as a number first: 1.000 is no marker.
  assert.deepEqual(numberRuns('1.000 Euro', true), ['1000'])
  // The dictation has no markers: a number there is a number.
  assert.deepEqual(numberRuns('1. Milch'), ['1'])
})

test('a numbered list passes where it was asked for, and nowhere else', () => {
  const said = 'wir brauchen äpfel birnen und bananen'
  assert.equal(accepts('Wir brauchen:\n\n1. Äpfel\n2. Birnen\n3. Bananen', said, 'polished'), true)
  assert.equal(accepts('Wir brauchen:\n\n1) Äpfel\n2) Birnen\n3) Bananen', said, 'polished'), true)
  assert.equal(accepts('Wir brauchen:\n  1. Äpfel\n  2. Birnen\n  3. Bananen', said, 'polished'), true)
  // "Nur Zeichensetzung" keeps every word, and a marker is one.
  assert.equal(accepts('Wir brauchen:\n\n1. Äpfel\n2. Birnen\n3. Bananen', said, 'punctuation'), false)
  // The marker is left out, a number behind it or inside a line is not.
  assert.equal(accepts('Wir brauchen:\n\n1. Äpfel\n2. 5 Birnen', 'wir brauchen äpfel und birnen', 'polished'), false)
  assert.equal(accepts('Wir sehen uns am Montag, 5. Mai.', 'wir sehen uns am montag', 'polished'), false)
})

// v3: number words count for their own value

const value = numberWordValue
const values = (text: string) => numberWordValues(words(text))

test('German cardinals have their value', () => {
  const expected: Record<string, number> = {
    null: 0, ein: 1, eins: 1, eine: 1, einen: 1, einem: 1, einer: 1, zwei: 2, drei: 3, vier: 4, fünf: 5, sechs: 6, sieben: 7,
    acht: 8, neun: 9, zehn: 10, elf: 11, zwölf: 12, dreizehn: 13, vierzehn: 14, fünfzehn: 15, sechzehn: 16, siebzehn: 17,
    achtzehn: 18, neunzehn: 19, zwanzig: 20, dreißig: 30, vierzig: 40, fünfzig: 50, sechzig: 60, siebzig: 70, achtzig: 80, neunzig: 90,
    // Compounds written as one word.
    einundzwanzig: 21, zweiundzwanzig: 22, sechsunddreißig: 36, achtundvierzig: 48, neunundneunzig: 99,
    hundert: 100, einhundert: 100, hunderteins: 101, einhundertzwanzig: 120, dreihundertfünfzig: 350,
    zweihundertdreiundzwanzig: 223, neunhundertneunundneunzig: 999,
    tausend: 1000, eintausend: 1000, tausendeins: 1001, zweitausend: 2000, zwölftausend: 12000, zweitausendfünfhundert: 2500,
    einundzwanzigtausend: 21000, hundertzwanzigtausend: 120000, hunderttausend: 100000, zweihunderttausenddreihundert: 200300,
    neunhundertneunundneunzigtausendneunhundertneunundneunzig: 999999,
  }
  for (const [word, number] of Object.entries(expected)) assert.equal(value(word), number, word)
  // Folded as in "Nur Zeichensetzung": the same without the umlaut and the ß.
  for (const [word, number] of Object.entries({ fuenf: 5, zwoelf: 12, dreissig: 30, fuenfzig: 50, fuenfzehn: 15, sechsunddreissig: 36, dreihundertfuenfzig: 350 })) assert.equal(value(word), number, word)
})

test('German ordinals have their value', () => {
  const stems: Record<string, number> = {
    erst: 1, zweit: 2, dritt: 3, viert: 4, fünft: 5, sechst: 6, siebt: 7, acht: 8, neunt: 9, zehnt: 10, elft: 11, zwölft: 12,
    dreizehnt: 13, vierzehnt: 14, fünfzehnt: 15, sechzehnt: 16, siebzehnt: 17, achtzehnt: 18, neunzehnt: 19,
    zwanzigst: 20, dreißigst: 30, vierzigst: 40, fünfzigst: 50, sechzigst: 60, siebzigst: 70, achtzigst: 80, neunzigst: 90,
    einundzwanzigst: 21, neunundneunzigst: 99, hundertst: 100, hunderterst: 101, dreihundertst: 300, tausendst: 1000,
    zweitausendst: 2000, zweitausenddritt: 2003,
  }
  for (const [stem, number] of Object.entries(stems)) {
    for (const ending of ['e', 'en', 'er', 'es', 'em']) assert.equal(value(stem + ending), number, stem + ending)
    // The stem alone is no ordinal ("erst" is "only", "acht" is the cardinal 8), nor is another ending.
    assert.equal(value(stem), stem === 'acht' ? 8 : undefined, stem)
    assert.equal(value(`${stem}el`), undefined, `${stem}el`)
  }
})

test('English numbers have their value', () => {
  const expected: Record<string, number> = {
    zero: 0, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12,
    thirteen: 13, fourteen: 14, fifteen: 15, sixteen: 16, seventeen: 17, eighteen: 18, nineteen: 19,
    twenty: 20, thirty: 30, forty: 40, fifty: 50, sixty: 60, seventy: 70, eighty: 80, ninety: 90, hundred: 100, thousand: 1000,
    first: 1, second: 2, third: 3, fourth: 4, fifth: 5, sixth: 6, seventh: 7, eighth: 8, ninth: 9, tenth: 10, eleventh: 11, twelfth: 12,
    thirteenth: 13, nineteenth: 19, twentieth: 20, thirtieth: 30, fortieth: 40, ninetieth: 90, hundredth: 100, thousandth: 1000,
  }
  for (const [word, number] of Object.entries(expected)) assert.equal(value(word), number, word)
})

test('half is no number, and neither is anything that only looks like one', () => {
  // "halb" and "half" were number words in the first v3 and give no allowance now.
  for (const word of ['halb', 'halbe', 'halber', 'half', 'halves']) assert.equal(value(word), undefined, word)
  // The words that ended in zehn, zig or teen, or began like an ordinal, but are none.
  for (const word of ['witzig', 'fleißig', 'wenig', 'einzig', 'dutzend', 'fourteens', 'someone', 'ones', 'tent', 'thirds', 'forties', 'seconds', 'billion', 'billions']) assert.equal(value(word), undefined, word)
  // Whole words only, and only these.
  for (const word of ['uns', 'viertel', 'dreiviertel', 'einkaufen', 'nullen', 'hunderte', 'tausende', 'jahrhundert', 'jahrtausend', 'keine', 'eines', 'sechsmal', 'einmal',
    'zehner', 'drei1', 'ei', 'milliarde', 'milliarden', 'nachte', 'dachte', 'erst', 'zweit', 'million', 'millionen', 'millions', '']) assert.equal(value(word), undefined, word)
  // Compounds that are not numbers.
  for (const word of ['einsundzwanzig', 'einzwanzig', 'zweiundzehn', 'nullhundert', 'hunderthundert', 'tausendtausend', 'zweihundertdreihundert',
    'dreihundertundfünfzig', 'tausendnull', 'hundertzwei1']) assert.equal(value(word), undefined, word)
})

test('million needs a number word in front', () => {
  assert.deepEqual(values('eine million euro'), [1, 1000000])
  assert.deepEqual(values('zwei millionen euro'), [2, 2000000])
  assert.deepEqual(values('dreihundert millionen'), [300, 300000000])
  assert.deepEqual(values('one million'), [1, 1000000])
  assert.deepEqual(values('two million'), [2, 2000000])
  // Alone, behind a digit ("1 million" is left unsupported), behind a word that is no number, behind an ordinal or too large a number.
  assert.deepEqual(values('million euro'), [])
  assert.deepEqual(values('1 million'), [])
  assert.deepEqual(values('1,5 millionen'), [])
  assert.deepEqual(values('viele millionen'), [])
  assert.deepEqual(values('zweite million'), [2])
  assert.deepEqual(values('tausend millionen'), [1000])
})

test('every number word of a dictation gives one value', () => {
  assert.deepEqual(values('um drei oder vier uhr'), [3, 4])
  assert.deepEqual(values('ein kunde zahlt tausend euro'), [1, 1000])
  // Spaces split compounds: the parts are their own words.
  assert.deepEqual(values('twenty one und ein hundert'), [20, 1, 1, 100])
  assert.deepEqual(values('halb drei'), [3])
  assert.deepEqual(values('am fünften märz um zwei'), [5, 2])
})

test('a number said in words may come back in digits', () => {
  for (const level of ['light', 'smooth', 'polished'] as const) {
    assert.equal(accepts('3 Exemplare, bitte.', 'drei exemplare bitte', level), true, level)
    assert.equal(accepts('Ich zahle 1.000 Euro für das Auto.', 'ich zahle tausend euro für das auto', level), true, level)
    assert.equal(accepts('Wir treffen uns um 15 Uhr.', 'wir treffen uns um fünfzehn uhr', level), true, level)
    assert.equal(accepts('Am 5. März kommt er.', 'am fünften märz kommt er', level), true, level)
    assert.equal(accepts('We need 20 copies by Friday.', 'we need twenty copies by friday', level), true, level)
    assert.equal(accepts('The 3rd of May is a holiday for us.', 'the third of may is a holiday for us', level), true, level)
    // Compounds, by their value.
    assert.equal(accepts('Das macht 350 Euro für uns alle.', 'das macht dreihundertfünfzig euro für uns alle', level), true, level)
    assert.equal(accepts('Das macht 2.500 Euro für uns alle.', 'das macht zweitausendfünfhundert euro für uns alle', level), true, level)
    assert.equal(accepts('Er wurde 21 Jahre alt gestern.', 'er wurde einundzwanzig jahre alt gestern', level), true, level)
    assert.equal(accepts('Das macht 2.000.000 Euro für uns alle.', 'das macht zwei millionen euro für uns alle', level), true, level)
    // Whatever zeros stand in front, and wherever the separators.
    assert.equal(accepts('Wir treffen uns um 07 Uhr im Büro.', 'wir treffen uns um sieben uhr im büro', level), true, level)
    // A short dictation: the digits are no word to look for among the words said.
    assert.equal(accepts('1.000 Euro', 'tausend euro', level), true, level)
    assert.equal(accepts('3 Exemplare', 'drei exemplare', level), true, level)
    assert.equal(accepts('21', 'einundzwanzig', level), true, level)
    assert.equal(accepts('Am 5. März', 'am fünften märz', level), true, level)
    // No number word said: no number may appear.
    assert.equal(accepts('Wir treffen uns um 15 Uhr im Büro.', 'wir treffen uns im büro', level), false, level)
  }
})

test('a number word counts only for its own value', () => {
  for (const level of ['light', 'smooth', 'polished'] as const) {
    // The two answers the first v3 let through.
    assert.equal(accepts('Wir treffen uns um 15 Uhr.', 'wir treffen uns um drei', level), false, level)
    assert.equal(accepts('Ein Kunde zahlt 9000 Euro.', 'ein kunde zahlt 1000 euro', level), false, level)
    // "ein" is 1, so 1 is the only number it can come back as.
    assert.equal(accepts('1 Kunde zahlt 1000 Euro.', 'ein kunde zahlt 1000 euro', level), true, level)
    assert.equal(accepts('2 Kunden zahlen 1000 Euro.', 'ein kunde zahlt 1000 euro', level), false, level)
    // Off by a little, off by a unit, off by a magnitude.
    assert.equal(accepts('Wir treffen uns um 4 Uhr im Büro.', 'wir treffen uns um drei uhr im büro', level), false, level)
    assert.equal(accepts('Wir treffen uns um 13 Uhr im Büro.', 'wir treffen uns um drei uhr im büro', level), false, level)
    assert.equal(accepts('Wir treffen uns um 30 Uhr im Büro.', 'wir treffen uns um drei uhr im büro', level), false, level)
    assert.equal(accepts('Das macht 3.000 Euro für uns alle.', 'das macht dreihundert euro für uns alle', level), false, level)
    assert.equal(accepts('Das macht 351 Euro für uns alle.', 'das macht dreihundertfünfzig euro für uns alle', level), false, level)
    assert.equal(accepts('Er wurde 12 Jahre alt gestern.', 'er wurde einundzwanzig jahre alt gestern', level), false, level)
    assert.equal(accepts('Das macht 1.000.000 Euro für uns alle.', 'das macht zwei millionen euro für uns alle', level), false, level)
    // An ordinal is its number: the fifth is 5.
    assert.equal(accepts('Am 6. März kommt er.', 'am fünften märz kommt er', level), false, level)
    assert.equal(accepts('The 4th of May is a holiday for us.', 'the third of may is a holiday for us', level), false, level)
    // A short dictation: the same.
    assert.equal(accepts('9.000 Euro', 'tausend euro', level), false, level)
    assert.equal(accepts('4 Exemplare', 'drei exemplare', level), false, level)
    assert.equal(accepts('12', 'einundzwanzig', level), false, level)
    assert.equal(accepts('9', 'acht', level), false, level)
    // "halb" and "half" give no allowance.
    assert.equal(accepts('Es kostet 5 Euro, danke.', 'es kostet halb euro danke', level), false, level)
    assert.equal(accepts('It takes 5 hours for sure.', 'it takes half hours for sure', level), false, level)
    // Digits of another script have no value to compare.
    assert.equal(accepts('Wir treffen uns um ٧ Uhr im Büro.', 'wir treffen uns um sieben uhr im büro', level), false, level)
  }
})

test('"Nur Zeichensetzung" keeps the words, so the digits stay out', () => {
  assert.equal(accepts('Wir treffen uns um 15 Uhr.', 'wir treffen uns um fünfzehn uhr', 'punctuation'), false)
  assert.equal(accepts('3 Exemplare', 'drei exemplare', 'punctuation'), false)
  assert.equal(accepts('1.000 Euro', 'tausend euro', 'punctuation'), false)
})

test('a short dictation still cannot grow words or list markers through the numbers', () => {
  // The digits of the answer are free, judged by the number rule; anything else is still a word that was not said.
  assert.equal(accepts('1.000 Euro, danke.', 'tausend euro', 'light'), false)
  assert.equal(accepts('3 Exemplare für Max', 'drei exemplare', 'light'), false)
  assert.equal(accepts('3', 'ja gerne', 'light'), false)
  assert.equal(accepts('1. Milch\n2. Brot', 'milch brot', 'polished'), false)
  // Said in digits and written with a separator: still the number said.
  assert.equal(accepts('1.000 Euro', '1000 euro', 'light'), true)
  assert.equal(accepts('9.000 Euro', '1000 euro', 'light'), false)
})

test('each number word is used once', () => {
  const said = 'wir brauchen drei exemplare für die kunden'
  assert.equal(accepts('Wir brauchen 3 Exemplare für die Kunden.', said, 'light'), true)
  // Two new numbers, one number word.
  assert.equal(accepts('Wir brauchen 3 Exemplare für 4 Kunden.', said, 'light'), false)
  // The same number twice is two places.
  assert.equal(accepts('Wir brauchen 3 Exemplare für 3 Kunden.', said, 'light'), false)
  // Two number words, two numbers, in either order; the same value twice needs it said twice.
  assert.equal(accepts('Um 3 oder 4 Uhr.', 'um drei oder vier uhr', 'polished'), true)
  assert.equal(accepts('Um 4 oder 3 Uhr.', 'um drei oder vier uhr', 'polished'), true)
  assert.equal(accepts('Um 3 oder 3 Uhr.', 'um drei oder vier uhr', 'polished'), false)
  assert.equal(accepts('Um 3 oder 5 Uhr.', 'um drei oder vier uhr', 'polished'), false)
  assert.equal(accepts('Um 3, 4 oder 5 Uhr.', 'um drei oder vier uhr', 'polished'), false)
  assert.equal(accepts('Wir brauchen 2 Exemplare und 2 Kunden und mehr Zeit.', 'wir brauchen zwei exemplare und zwei kunden und mehr zeit', 'light'), true)
  assert.equal(accepts('Wir brauchen 2 Exemplare und 2 Kunden und mehr Zeit.', 'wir brauchen zwei exemplare und drei kunden und mehr zeit', 'light'), false)
  // A number already said does not use one up: "5" was said, "sechs" becomes 6.
  assert.equal(accepts('Wir brauchen 5 Äpfel und 6 Birnen.', 'wir brauchen 5 äpfel und sechs birnen', 'light'), true)
  // The number words of a list: its markers are no numbers, the 3 behind one is.
  assert.equal(accepts('Wir brauchen:\n1. 3 Äpfel', 'wir brauchen drei äpfel', 'polished'), true)
  assert.equal(accepts('Wir brauchen:\n1. 4 Äpfel', 'wir brauchen drei äpfel', 'polished'), false)
})

test('the number rule on its own', () => {
  assert.equal(keepsNumbers('drei exemplare', '3 Exemplare') && keepsNumbers('drei oder vier', '4 oder 3') && keepsNumbers('tausend', '1.000'), true)
  assert.equal(keepsNumbers('5 äpfel', '5 Äpfel') && keepsNumbers('äpfel', '1. Äpfel') && keepsNumbers('äpfel', 'Äpfel'), true)
  assert.equal(keepsNumbers('äpfel', '5 Äpfel') || keepsNumbers('drei', '4') || keepsNumbers('drei', '3 4') || keepsNumbers('halb', '5'), false)
})

test('only the three share levels are judged by shares: "Nur Zeichensetzung" word by word, the own prompt not at all', () => {
  assert.equal(accepts('Ja bitte.', 'nein danke', 'punctuation'), false)
  assert.equal(accepts('Nein, danke.', 'nein danke', 'punctuation'), true)
  assert.equal(accepts('Ich komme morgen nicht.', 'ich komme morgen', 'punctuation'), false)
  assert.equal(accepts('Ich komme morgen nicht.', 'ich komme morgen', 'custom'), true)
  assert.equal(accepts('Can you tell me when the train leaves?', 'wann fährt der zug', 'custom'), true)
  assert.equal(accepts(' \n', 'wann fährt der zug', 'custom') || accepts('', 'wann fährt der zug', 'punctuation'), false)
})

// MARK: - 3. Negations

const strongNegations = ['nicht', 'kein', 'keine', 'keinen', 'keinem', 'keiner', 'keines', 'nie', 'niemals', 'nichts', 'niemand', 'nirgends',
  'weder', 'not', 'never', 'nothing', 'nobody', 'nowhere', 'neither', 'nor', 'cannot']

test('every strong negation counts', () => {
  for (const word of strongNegations) {
    const said = `wir haben heute ${word} mehr zu sagen und gehen jetzt nach hause`
    const kept = `Wir haben heute ${word} mehr zu sagen und gehen jetzt nach Hause.`
    const lost = 'Wir haben heute mehr zu sagen und gehen jetzt nach Hause.'
    for (const level of presets) {
      assert.equal(accepts(kept, said, level), true, `${level} keeps ${word}`)
      assert.equal(accepts(lost, said, level), false, `${level} loses ${word}`)
    }
    assert.equal(negationCount(said), 1, word)
  }
})

test('a word that contains one is no negation', () => {
  // Whole words only: "nicht" inside "nichtraucher", "not" inside "notiz".
  assert.equal(negationCount('nichtraucher und notiz und knot und nicht'), 1)
  assert.equal(accepts('Wir haben die Notiz gelesen und gehen jetzt nach Hause.', 'wir haben die notiz gelesen und gehen jetzt nach hause', 'light'), true)
})

test('"nein" and "no" are how people correct themselves', () => {
  assert.equal(negationCount('Montag, nein, Dienstag. No, Friday.'), 0)
  assert.equal(accepts('Wir treffen uns am Dienstag im Büro.', 'wir treffen uns am montag nein am dienstag im büro', 'light'), true)
  assert.equal(accepts('We meet on Tuesday at the office.', 'we meet on monday no on tuesday at the office', 'light'), true)
})

test('contractions count once', () => {
  for (const apostrophe of ["'", '’', 'ʼ', '‘', '`', '´']) {
    for (const stem of ['don', 'won', 'isn', 'can', 'shouldn', 'didn', 'ain']) {
      const word = `${stem}${apostrophe}t`
      assert.equal(negationCount(`i ${word} think so`), 1, word)
      assert.equal(negationCount(`I ${word.toUpperCase()} think so`), 1, word)
    }
  }
  assert.equal(negationCount("it's what you'd say, that's all, I'll go"), 0)
  assert.equal(negationCount("he's not here"), 1)
  // Dropped, or kept with the other apostrophe.
  assert.equal(accepts('I want that and I know it.', "i don't want that and i know it", 'light'), false)
  assert.equal(accepts('I don’t want that and I know it.', "i don't want that and i know it", 'light'), true)
  assert.equal(accepts('I don’t want that and I know it.', "i don't want that and i know it", 'punctuation'), true)
  // "not" becoming "don't" is still one negation.
  assert.equal(accepts("Please don't send the invoice before we have checked it.", 'please do not send the invoice before we checked it', 'polished'), true)
})

test('"can\'t" and "cannot" are one negation each', () => {
  assert.equal(accepts('I cannot go to the office today, sorry.', "i can't go to the office today sorry", 'light'), true)
})

// v3: the same number of negations, not only "not fewer"

const apostropheLess = ['dont', 'cant', 'wont', 'isnt', 'arent', 'wasnt', 'werent', 'doesnt', 'didnt', 'hasnt', 'havent', 'hadnt', 'wouldnt', 'couldnt', 'shouldnt',
  'mustnt', 'neednt', 'aint']

test('a negation added is as bad as one lost', () => {
  for (const level of presets) {
    assert.equal(accepts('Ich komme morgen nicht.', 'ich komme morgen', level), false, level)
    assert.equal(accepts('Ich komme morgen nicht zum Treffen im Büro vorbei.', 'ich komme morgen zum treffen im büro vorbei', level), false, level)
    assert.equal(accepts('Please do not send the invoice to the customer today.', 'please send the invoice to the customer today', level), false, level)
    assert.equal(accepts("Please don't send the invoice to the customer today.", 'please send the invoice to the customer today', level), false, level)
    for (const word of strongNegations) {
      assert.equal(accepts(`Wir haben heute ${word} mehr zu sagen und gehen jetzt nach Hause.`, 'wir haben heute mehr zu sagen und gehen jetzt nach hause', level), false, `${level} adds ${word}`)
    }
  }
  assert.equal(accepts('Ich komme morgen nicht.', 'ich komme morgen', 'custom'), true)
})

test('one negation said twice is two negations', () => {
  const said = 'ich habe nie gesagt dass ich das nicht will'
  assert.equal(negationCount(said), 2)
  assert.equal(accepts('Ich habe nie gesagt, dass ich das nicht will.', said, 'light'), true)
  assert.equal(accepts('Ich habe nie gesagt, dass ich das will.', said, 'light'), false)
  assert.equal(accepts('Ich habe nie gesagt, dass ich das nicht nie will.', said, 'light'), false)
})

test('the contractions without an apostrophe are negations, too', () => {
  for (const word of apostropheLess) {
    const apostrophe = word.replace(/nt$/, "n't")
    assert.equal(negationCount(`i ${word} think so`), 1, word)
    assert.equal(negationCount(`I ${word.toUpperCase()} think so`), 1, word)
    assert.equal(negationCount(`i ${apostrophe} think so`), 1, apostrophe)
    const said = `i ${word} think we should go there today`
    for (const level of presets) {
      // The model adds the apostrophe: still one negation.
      assert.equal(accepts(`I ${apostrophe} think we should go there today.`, said, level), true, `${level} ${apostrophe}`)
      assert.equal(accepts(`I ${word} think we should go there today.`, said, level), true, `${level} ${word}`)
      // And lost, or added to a sentence without one.
      assert.equal(accepts('I think we should go there today.', said, level), false, `${level} loses ${word}`)
      assert.equal(accepts(`I ${apostrophe} think we should go there today.`, 'i think we should go there today', level), false, `${level} adds ${apostrophe}`)
      assert.equal(accepts(`I ${word} think we should go there today.`, 'i think we should go there today', level), false, `${level} adds ${word}`)
    }
  }
  for (const level of presets) assert.equal(accepts("I don't think so.", 'i dont think so', level), true, level)
})

test('whole words only: "dont" inside another word is no negation', () => {
  assert.equal(negationCount('wonton and canto and wontons and dontcare'), 0)
})

// MARK: - 4. Short dictations

test('a short dictation keeps its words', () => {
  assert.equal(accepts('Ja bitte.', 'nein danke', 'light'), false)
  assert.equal(accepts('Um neun.', 'um acht', 'light'), false)
  assert.equal(accepts('Ja.', 'nein', 'light'), false)
  assert.equal(accepts('Nein, danke.', 'nein danke', 'light'), true)
  assert.equal(accepts('Ja.', 'ja', 'light'), true)
  // The length rule is still there.
  assert.equal(accepts('Ja, das ist eine gute Frage, danke.', 'ja', 'light'), false)
  // A spelling fix or an ending is the same word; under four letters it is not.
  assert.equal(accepts('Danke schön.', 'danke schon', 'light'), true)
  assert.equal(accepts('Projekts.', 'projekt', 'light'), true)
  assert.equal(accepts('Okay, danke.', 'ok danke', 'light'), false)
  // "Nur Zeichensetzung" asks the same of a short dictation as of a long one.
  assert.equal(accepts('Ok, danke.', 'ok danke', 'punctuation'), true)
  assert.equal(accepts('Ja, das ist gut.', 'ja', 'punctuation'), false)
})

test('fillers do not make a long dictation short', () => {
  // Three words besides the fillers: the share rules apply, so a made-up sentence is out.
  assert.equal(accepts('Ich komme morgen.', 'ähm ich komme morgen', 'light'), true)
  assert.equal(accepts('Ich komme morgen und bringe Kuchen für alle mit.', 'ähm ich komme morgen', 'light'), false)
})

// v3: a short dictation keeps a word, and the word list counts

test('a short dictation keeps at least a word', () => {
  assert.equal(accepts('👍', 'ja gerne', 'light'), false)
  assert.equal(accepts('.', 'ja gerne', 'smooth'), false)
  assert.equal(accepts('...', 'ja', 'polished'), false)
  assert.equal(accepts('.', 'ähm', 'light'), false)
  assert.equal(accepts('Ähm.', 'ähm', 'light'), true)
  assert.equal(accepts('Ja, gerne.', 'ja gerne', 'light'), true)
  // Nothing to keep where nothing was said, and nothing to be like either.
  assert.equal(accepts('...', '...', 'light'), true)
  assert.equal(accepts('Hallo.', '...', 'light'), false)
  assert.equal(guard('...', 'Jannik.', 'light', ['Jannik']), false)
})

test('a word of the word list counts as the word that was said', () => {
  assert.equal(guard('hallo yannick', 'Hallo Jannik.', 'light', ['Jannik']), true)
  assert.equal(guard('danke yannick', 'Danke, Jannik.', 'polished', ['Jannik']), true)
  assert.equal(guard('hallo yannick', 'Hallo Jannik.', 'light', []), false)
  assert.equal(guard('hallo yannick', 'Hallo Jannik.', 'light', ['Daniel']), false)
  // Still no sentence of its own.
  assert.equal(guard('hallo yannick', 'Hallo Jannik, schön dich zu sehen, wie geht es dir?', 'light', ['Jannik']), false)
})

// MARK: - v4 (Codex R4, 14.10.2026): a sign belongs to its number

/** The pairs of the fourth audit: the guards let the sign of a saldo and of a temperature go. */
const signsChanged: [said: string, answer: string, why: string][] = [
  ['der saldo beträgt -1000 euro', 'Der Saldo beträgt 1000 Euro.', '-1000 became 1000'],
  ['der saldo beträgt 1000 euro', 'Der Saldo beträgt -1000 Euro.', '1000 became -1000'],
  ['die temperatur beträgt -20 grad', 'Die Temperatur beträgt 20 Grad.', '-20 became 20'],
  ['die temperatur beträgt minus 20 grad', 'Die Temperatur beträgt 20 Grad.', 'minus 20 became 20'],
  ['die temperatur beträgt minus zwanzig grad', 'Die Temperatur beträgt 20 Grad.', 'minus zwanzig became 20'],
  ['die temperatur beträgt zwanzig grad', 'Die Temperatur beträgt -20 Grad.', 'zwanzig became -20'],
  ['das konto steht bei plus 50 euro', 'Das Konto steht bei 50 Euro.', 'plus 50 became 50'],
  ['die nummer ist +49 170 1234567', 'Die Nummer ist 49 170 1234567.', '+49 became 49'],
]

test('a changed sign is rejected at every preset', () => {
  for (const level of presets) for (const [said, answer, why] of signsChanged) assert.equal(accepts(answer, said, level), false, `${level} ${why}`)
})

test('a sign changed is a change for the own prompt, too, only where it asked for it: nothing is judged', () => {
  for (const [said, answer, why] of signsChanged) assert.equal(accepts(answer, said, 'custom'), true, why)
})

test('the same sign, written another way, passes', () => {
  for (const level of presets) {
    assert.equal(accepts('Der Saldo beträgt -1000 Euro.', 'der saldo beträgt -1000 euro', level), true, level)
    assert.equal(accepts('Der Saldo beträgt −1000 Euro.', 'der saldo beträgt -1000 euro', level), true, `${level} the real minus`)
    assert.equal(accepts('Der Saldo beträgt –1000 Euro.', 'der saldo beträgt -1000 euro', level), true, `${level} the en dash`)
    assert.equal(accepts('Der Saldo beträgt - 1000 Euro.', 'der saldo beträgt -1000 euro', level), true, `${level} one space`)
    assert.equal(accepts('Die Temperatur beträgt minus 20 Grad.', 'die temperatur beträgt minus 20 grad', level), true, `${level} the words kept`)
    assert.equal(accepts('Die Temperatur beträgt minus zwanzig Grad.', 'die temperatur beträgt minus zwanzig grad', level), true, `${level} the words kept`)
    assert.equal(accepts('Die Nummer ist +49 170 1234567.', 'die nummer ist +49 170 1234567', level), true, `${level} the plus kept`)
  }
  // The share levels may write the words as digits; "Nur Zeichensetzung" keeps the words.
  for (const level of ['light', 'smooth', 'polished'] as const) {
    assert.equal(accepts('Der Saldo beträgt −1.000 Euro.', 'der saldo beträgt -1000 euro', level), true, `${level} regrouped`)
    assert.equal(accepts('Die Temperatur beträgt -20 Grad.', 'die temperatur beträgt minus 20 grad', level), true, `${level} minus 20`)
    assert.equal(accepts('Die Temperatur beträgt -20 Grad.', 'die temperatur beträgt minus zwanzig grad', level), true, `${level} minus zwanzig`)
    assert.equal(accepts('Das Konto steht bei +50 Euro.', 'das konto steht bei plus 50 euro', level), true, `${level} plus 50`)
  }
  assert.equal(accepts('Der Saldo beträgt −1.000 Euro.', 'der saldo beträgt -1000 euro', 'punctuation'), false)
  assert.equal(accepts('Die Temperatur beträgt -20 Grad.', 'die temperatur beträgt minus 20 grad', 'punctuation'), false)
})

test('a hyphen behind a letter or a digit is a range or a code, not a sign', () => {
  assert.deepEqual(numberRuns('Seite 3-5'), ['3', '5'])
  assert.deepEqual(numberRuns('Modell A-1'), ['1'])
  assert.deepEqual(numberRuns('2026-10-14'), ['2026', '10', '14'])
  assert.deepEqual(numberRuns('x²-5'), ['5'])
  assert.deepEqual(numberRuns('3 -5'), ['3', '-5'])
  assert.deepEqual(numberRuns('3- 5'), ['3', '5'])
  for (const level of presets) {
    assert.equal(accepts('Das steht auf Seite 3–5.', 'das steht auf seite 3-5', level), true, level)
    assert.equal(accepts('Das ist Modell A-1 mit 5 Teilen.', 'das ist modell a-1 mit 5 teilen', level), true, level)
  }
  assert.equal(accepts('Das ist Modell A-1 mit -5 Teilen.', 'das ist modell a-1 mit 5 teilen', 'light'), false)
})

test('numbers carry their sign: a minus, a real minus, an en dash, a plus, the words minus and plus', () => {
  assert.deepEqual(numberRuns('-1000'), ['-1000'])
  assert.deepEqual(numberRuns('\u2212' + '1.000'), ['-1000'])
  assert.deepEqual(numberRuns('\u2013' + '5'), ['-5'])
  assert.deepEqual(numberRuns('+49 30 123456'), ['+49', '30', '123456'])
  // A space and exactly three digits are a thousands group, with a sign or without.
  assert.deepEqual(numberRuns('+49 170'), ['+49170'])
  assert.deepEqual(numberRuns('- 5'), ['-5'])
  assert.deepEqual(numberRuns('+\u00A05'), ['+5'])
  assert.deepEqual(numberRuns('-\u20095'), ['-5'])
  // Not two spaces, and not a sign that is not right in front.
  assert.deepEqual(numberRuns('-  5'), ['5'])
  assert.deepEqual(numberRuns('- a 5'), ['5'])
  assert.deepEqual(numberRuns('minus 20'), ['-20'])
  assert.deepEqual(numberRuns('Minus 20 und PLUS 3'), ['-20', '+3'])
  assert.deepEqual(numberRuns('minus: 20'), ['-20'])
  assert.deepEqual(numberRuns('minus 1.000'), ['-1000'])
  assert.deepEqual(numberRuns('minus 3,5'), ['-3', '5'])
  assert.deepEqual(numberRuns('-3,5'), ['-3', '5'])
  assert.deepEqual(numberRuns('minus -5'), ['-5'])
  assert.deepEqual(numberRuns('1000 minus 5'), ['1000', '-5'])
  assert.deepEqual(numberRuns('minus20'), ['20'])
  assert.deepEqual(numberRuns('Kaminus 20'), ['20'])
  assert.deepEqual(numberRuns('minus ähm 20'), ['20'])
  assert.deepEqual(numberRuns('-\u0662\u0663'), ['-\u0662\u0663'])
  assert.deepEqual(numberRuns('-1. Milch', true), ['-1'])
  assert.deepEqual(numberRuns('1. Milch\nminus 2 Brot', true), ['-2'])
  assert.deepEqual([...digitRuns('-5 und 5 und minus 5')].sort(), ['-5', '5'])
})

test('a number word has the sign of the word right before it', () => {
  const entries = (text: string) => numberWords(words(text)).map(entry => `${entry.sign}${entry.value}@${entry.position}`)
  assert.deepEqual(entries('minus zwanzig und plus drei und vier'), ['-20@1', '+3@4', '4@6'])
  assert.deepEqual(entries('minus ähm zwanzig'), ['20@2'])
  assert.deepEqual(entries('zwanzig minus drei'), ['20@0', '-3@2'])
  assert.deepEqual(entries('minus zwei millionen'), ['-2@1', '-2000000@2'])
  assert.deepEqual(entries('zwei millionen'), ['2@0', '2000000@1'])
  assert.deepEqual(entries('minus million'), [])
  assert.deepEqual(entries('minus twenty one'), ['-20@1', '1@2'])
  assert.deepEqual(numberWordValues(words('minus zwanzig und plus drei')), [20, 3])
})

test('the number rule reads the sign', () => {
  const keeps = (said: string, answer: string) => keepsNumbers(said, answer)
  assert.equal(keeps('-1000 euro', '\u2212' + '1.000 Euro') && keeps('minus 20 grad', '-20 Grad') && keeps('minus zwanzig', '-20') && keeps('plus fünf', '+5'), true)
  assert.equal(keeps('minus zwei millionen', '-2.000.000') && keeps('minus 5', 'minus 5') && keeps('-5', '- 5'), true)
  assert.equal(keeps('-1000', '1000') || keeps('1000', '-1000') || keeps('minus 20 grad', '20 Grad') || keeps('minus zwanzig', '20'), false)
  assert.equal(keeps('zwanzig', '-20') || keeps('plus 5', '5') || keeps('5', '+5') || keeps('minus 5', '+5') || keeps('plus fünf', '5'), false)
  assert.equal(keeps('minus zwei millionen', '2.000.000') || keeps('zwei millionen', '-2.000.000') || keeps('minus zwanzig', '-21'), false)
  // A sign is not a number word's value: each word is still used once.
  assert.equal(keeps('minus drei', '-3 und -3'), false)
})

test('"Nur Zeichensetzung" keeps the sign of every number, in its place', () => {
  assert.equal(keepsSigns('der saldo ist -5 und das limit ist 5', 'Der Saldo ist -5 und das Limit ist 5.'), true)
  assert.equal(keepsSigns('der saldo ist -5 und das limit ist 5', 'Der Saldo ist 5 und das Limit ist 5.'), false)
  assert.equal(keepsSigns('der saldo ist -5 und das limit ist 5', 'Der Saldo ist 5 und das Limit ist -5.'), false)
  assert.equal(keepsSigns('minus 5', '-5'), true)
  assert.equal(keepsSigns('5 minus 3', '5 - 3'), true)
  assert.equal(keepsSigns('3 - 5', '3–5'), false)
  // Another count of numbers is no sign lost: the words have judged a number regrouped or replaced by a word of the word list.
  assert.equal(keepsSigns('-5', 'Danke.'), true)
  assert.equal(keepsSigns('1.000', '1. 000'), true)
  assert.equal(keepsSigns('', '-5'), true)
  // The other presets judge the set of numbers: a number said twice, with and without its sign, can lose it.
  assert.equal(accepts('Der Saldo ist 5 und das Limit ist 5.', 'der saldo ist -5 und das limit ist 5', 'punctuation'), false)
  assert.equal(accepts('Der Saldo ist -5 und das Limit ist 5.', 'der saldo ist -5 und das limit ist 5', 'punctuation'), true)
})

// v4: a short dictation keeps every word

/** The pairs of the fourth audit: a short reply lost its denial or all its words. */
const shortRepliesLost: [said: string, answer: string, why: string][] = [
  ['nein danke', 'Danke.', 'nein dropped'],
  ['nein danke', 'Nein.', 'danke dropped'],
  ['nein danke', '!', 'no word left'],
  ['nein danke', '👍', 'no word left, an emoji'],
  ['ja danke', '👍', 'no word left, an emoji'],
  ['ja', '...', 'no word left'],
  ['ja gerne', 'Gerne.', 'ja dropped'],
]

test('a short reply that lost a word is rejected at every preset', () => {
  for (const level of presets) for (const [said, answer, why] of shortRepliesLost) assert.equal(accepts(answer, said, level), false, `${level} ${why}`)
  assert.equal(accepts('Danke.', 'ähm nein danke', 'light'), false)
})

test('a short reply that keeps its words passes at every preset', () => {
  for (const level of presets) {
    assert.equal(accepts('Nein, danke.', 'nein danke', level), true, level)
    assert.equal(accepts('Ja.', 'ja', level), true, level)
    assert.equal(accepts('Ja, gerne.', 'ja gerne', level), true, level)
  }
  // A filler is no word; at "Nur Zeichensetzung" it is one.
  for (const level of ['light', 'smooth', 'polished'] as const) assert.equal(accepts('Ja.', 'ähm ja', level), true, level)
  assert.equal(accepts('Ja.', 'ähm ja', 'punctuation'), false)
  // Where the words are, their order is not read (the share levels never read it).
  assert.equal(accepts('Nein, ja.', 'ja nein', 'light'), true)
  // The own prompt may do anything.
  assert.equal(accepts('Danke.', 'nein danke', 'custom'), true)
})

test('"ok" and "okay" are two different short words: rejected at every preset, as before', () => {
  for (const level of presets) assert.equal(accepts('Okay.', 'ok', level), false, level)
  assert.equal(accepts('Ok.', 'ok', 'light'), true)
})

test('a word that is gone needs a vocabulary word of its own that was not said', () => {
  // The transcription misheard a name; the vocabulary's spelling stands for it.
  assert.equal(guard('hallo yannick', 'Hallo Jannik.', 'light', ['Jannik']), true)
  assert.equal(guard('danke yannick', 'Danke, Jannik.', 'polished', ['Jannik']), true)
  // One vocabulary word does not stand for two words that are gone.
  assert.equal(guard('hallo yannick', 'Jannik.', 'light', ['Jannik']), false)
  assert.equal(guard('nein yannick', 'Jannik.', 'smooth', ['Jannik']), false)
  // A name that was said stands for itself and nothing else.
  assert.equal(guard('ja jannik', 'Jannik.', 'light', ['Jannik']), false)
  assert.equal(guard('ja jannik', 'Ja, Jannik.', 'light', ['Jannik']), true)
  // A name the transcription split in two: the one that is no longer `similar` is the one the vocabulary replaces.
  for (const level of ['light', 'smooth', 'polished'] as const) assert.equal(guard('kuber netes', 'Kubernetes.', level, ['Kubernetes']), true, level)
  assert.equal(guard('kuber netes', 'Kubernetes.', 'light', []), false)
  assert.equal(guard('kuber netes', 'Kubernetes.', 'punctuation', ['Kubernetes']), false)
})

test('a number in a short dictation comes back as its digits, or stays a word', () => {
  assert.equal(accepts('Euro.', 'tausend euro', 'light'), false)
  assert.equal(accepts('Tausend Euro.', 'tausend euro', 'light'), true)
  assert.equal(accepts('1.000 Euro', 'tausend euro', 'light'), true)
  assert.equal(accepts('Euro.', '1000 euro', 'light'), false)
  assert.equal(accepts('1000 Euro.', '1000 euro', 'light'), true)
  assert.equal(accepts('1.000 Euro', '1000 euro', 'light'), true)
  // Two words besides the separator's digits: "1.000" is "1" and "000" to the words, and one number to the digits.
  assert.equal(accepts('1000', '1.000', 'light'), true)
  assert.equal(accepts('Euro.', '1.000', 'light'), false)
  // Two numbers said, one left.
  assert.equal(accepts('3, 4', 'drei vier', 'light'), true)
  assert.equal(accepts('3', 'drei vier', 'light'), false)
  assert.equal(accepts('Drei.', 'drei vier', 'light'), false)
  // A million is its own number, and the "zwei" in front of it is part of it.
  assert.equal(accepts('2.000.000', 'zwei millionen', 'light'), true)
  assert.equal(accepts('2 Millionen', 'zwei millionen', 'light'), true)
  assert.equal(accepts('Millionen.', 'zwei millionen', 'light'), false)
  assert.equal(accepts('2.000.001', 'zwei millionen', 'light'), false)
})

test('"minus zwanzig" is -20 in a short dictation: the sign and the number come back together', () => {
  assert.equal(accepts('-20', 'minus zwanzig', 'light'), true)
  assert.equal(accepts('\u221220', 'minus zwanzig', 'light'), true)
  assert.equal(accepts('Minus zwanzig.', 'minus zwanzig', 'light'), true)
  assert.equal(accepts('Minus 20.', 'minus zwanzig', 'light'), true)
  assert.equal(accepts('20', 'minus zwanzig', 'light'), false)
  assert.equal(accepts('+20', 'minus zwanzig', 'light'), false)
  assert.equal(accepts('Zwanzig.', 'minus zwanzig', 'light'), false)
  assert.equal(accepts('Minus.', 'minus zwanzig', 'light'), false)
  assert.equal(accepts('+5', 'plus fünf', 'light'), true)
  assert.equal(accepts('5', 'plus fünf', 'light'), false)
  assert.equal(accepts('+5', 'fünf', 'light'), false)
  assert.equal(accepts('-20 Grad', '-20 grad', 'light'), true)
  assert.equal(accepts('20 Grad', '-20 grad', 'light'), false)
  assert.equal(accepts('Grad.', '-20 grad', 'light'), false)
  assert.equal(accepts('-20', 'minus 20', 'light'), true)
  assert.equal(accepts('20', 'minus 20', 'light'), false)
  assert.equal(accepts('Minus.', 'minus 20', 'light'), false)
})

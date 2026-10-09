import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  formatGermanErrors, formatSize, formatSpeed, germanErrors, germanOrEnglish, localFacts, localModel, localModelIds, localModels,
  measuredHere, onlyLanguage, parseGermanErrors, secondsPer10, shippedGermanErrors, type Speed,
} from '../src/core/localModels'
import { models } from '../src/core/models'
import { providers } from '../src/core/transcriber'
import { GermanErrors } from '../src/main/localBenchmarks'
import { isModelId, readSpeed, speedPath, writeSpeed } from '../src/main/localFiles'

/** The head of hf-audio/multilingual_evals' multilingual_de.csv as fetched on 08.10.2026, trimmed. */
const leaderboard = `model,RTFx,FLEURS WER,MCV WER
assemblyai/universal-3-5-pro,-1,2.17,2.69
openai/whisper-large-v3,327.55,3.2,4.79
openai/whisper-large-v3-turbo,338.32,3.67,8.58
TheStageAI/thewhisper-large-v3-turbo,960.42,2.91,3.17
`

test('the catalog: eight models, Turbo first as the default, real sizes', () => {
  assert.deepEqual(localModels.map(model => model.id), [
    'onnx-community/whisper-large-v3-turbo', 'onnx-community/whisper-large-v3-ONNX', 'onnx-community/whisper-medium-ONNX',
    'onnx-community/whisper-small', 'onnx-community/whisper-base', 'onnx-community/whisper-large-v3-turbo-german-ONNX',
    'onnx-community/distil-large-v3.5-ONNX', 'onnx-community/whisper-tiny'])
  assert.equal(localModels[0].id, providers.local.defaultModel)
  // The sum of the three files satz loads, from each repo's file list (09.10.2026).
  assert.deepEqual(localModels.map(model => formatSize(model.bytes, 'en')), ['981 MB', '1.4 GB', '786 MB', '328 MB', '149 MB', '983 MB', '950 MB', '99 MB'])
  // The cloud menus and the local list name the same models, with their makers.
  assert.deepEqual(models.local.map(model => model.id).sort(), localModels.map(model => model.id).sort())
  assert.equal(models.local.find(model => model.id === 'onnx-community/whisper-large-v3-turbo-german-ONNX')?.maker, 'primeLine')
})

test('the order: the models for both languages by German errors, then the single-language ones, Tiny last', () => {
  const rates = germanErrors()
  const both = localModels.filter(model => model.language === 'both' && model.id !== 'onnx-community/whisper-tiny')
  // Turbo is first as the default; after it, fewer errors first.
  const afterDefault = both.slice(1).map(model => rates[model.original])
  assert.deepEqual(afterDefault, [...afterDefault].sort((a, b) => a - b))
  const firstSingle = localModels.findIndex(model => model.language !== 'both')
  assert.ok(localModels.slice(firstSingle, -1).every(model => model.language !== 'both'))
  assert.equal(localModels.at(-1)!.id, 'onnx-community/whisper-tiny')
  assert.equal(localModels.at(-1)!.tag?.en, 'very rough')
})

test('models satz cannot run, and the *.en ones, are never offered', () => {
  for (const { id } of localModels) {
    assert.doesNotMatch(id, /\.en$|lite-whisper|whisper-small-ONNX|whisper-large-v3-turbo-ONNX|^Xenova\//)
  }
})

test('a single-language model always decodes in its language; the others are asked which they hear', () => {
  assert.equal(onlyLanguage('onnx-community/whisper-large-v3-turbo-german-ONNX'), 'de')
  assert.equal(onlyLanguage('onnx-community/distil-large-v3.5-ONNX'), 'en')
  for (const id of ['onnx-community/whisper-large-v3-turbo', 'onnx-community/whisper-tiny', 'onnx-community/whisper-medium-ONNX']) assert.equal(onlyLanguage(id), undefined, id)
  // Typed in by hand: nothing known, Whisper tells.
  assert.equal(onlyLanguage('someone/whisper-de'), undefined)
  // Each one's tag says it.
  for (const model of localModels.filter(model => model.language !== 'both')) {
    assert.deepEqual(model.tag, model.language === 'de' ? { de: 'nur Deutsch', en: 'German only' } : { de: 'nur Englisch', en: 'English only' })
  }
})

test('a model typed in earlier gets its own row, after the list', () => {
  assert.deepEqual(localModelIds('onnx-community/whisper-small'), localModels.map(model => model.id))
  assert.deepEqual(localModelIds('someone/whisper-de').slice(-1), ['someone/whisper-de'])
  assert.equal(localModelIds('').length, localModels.length)
})

test('the German leaderboard is read by column name, and only for the models satz offers that write German', () => {
  assert.deepEqual(parseGermanErrors(leaderboard), { 'openai/whisper-large-v3': 3.2, 'openai/whisper-large-v3-turbo': 3.67 })
  // A German number for the English-only model would mean nothing.
  assert.deepEqual(parseGermanErrors(`${leaderboard}distil-whisper/distil-large-v3.5,1,40.2,50\nprimeLine/whisper-large-v3-turbo-german,1,2.8,3\n`),
    { 'openai/whisper-large-v3': 3.2, 'openai/whisper-large-v3-turbo': 3.67, 'primeLine/whisper-large-v3-turbo-german': 2.8 })
  // Columns moved, a quoted field, Windows line ends.
  const moved = 'MCV WER,"FLEURS WER",model,RTFx\r\n4.79,3.1,"openai/whisper-large-v3",327.55\r\n'
  assert.deepEqual(parseGermanErrors(moved), { 'openai/whisper-large-v3': 3.1 })
})

test('a leaderboard without its columns, or with nonsense in them, gives nothing', () => {
  assert.deepEqual(parseGermanErrors('model,RTFx,WER\nopenai/whisper-large-v3,1,3.2\n'), {})
  assert.deepEqual(parseGermanErrors('<!doctype html><html>'), {})
  assert.deepEqual(parseGermanErrors(''), {})
  assert.deepEqual(parseGermanErrors('model,FLEURS WER\nopenai/whisper-large-v3,\nopenai/whisper-small,n/a\nopenai/whisper-base,-1\n'), {})
})

test("today's numbers win; the paper's stay for the models the leaderboard dropped", () => {
  const rates = germanErrors({ 'openai/whisper-large-v3-turbo': 3.5 })
  assert.equal(rates['openai/whisper-large-v3-turbo'], 3.5)
  assert.equal(rates['openai/whisper-small'], 10.2)
  assert.equal(rates['openai/whisper-base'], 17.9)
  // The Whisper paper, Table 13 (FLEURS, German).
  assert.equal(rates['openai/whisper-medium'], 6.5)
  assert.equal(rates['openai/whisper-tiny'], 27.8)
  assert.deepEqual(germanErrors(), shippedGermanErrors)
})

test('sizes, speeds and errors in German and English', () => {
  assert.equal(formatSize(981_450_034, 'de'), '981 MB')
  assert.equal(formatSize(1_445_984_744, 'de'), '1,4 GB')
  assert.equal(formatSize(1_445_984_744, 'en'), '1.4 GB')
  assert.equal(formatSize(1_638_500_000, 'de'), '1,6 GB')
  assert.equal(formatSpeed(0.7, 'de'), '0,7 s für 10 s Sprechen')
  assert.equal(formatSpeed(0.7, 'en'), '0.7 s per 10 s of speech')
  assert.equal(formatSpeed(12.4, 'de'), '12 s für 10 s Sprechen')
  assert.equal(formatSpeed(0.01, 'en'), '0.1 s per 10 s of speech')
  assert.equal(formatGermanErrors(3.67, 'de'), '3,7 % Fehler Deutsch')
  assert.equal(formatGermanErrors(3.67, 'en'), '3.7 % errors in German')
})

test('seconds per 10 s of speech from a warm run', () => {
  assert.equal(secondsPer10(700, 10), 0.7)
  assert.equal(secondsPer10(1400, 20), 0.7)
  assert.equal(secondsPer10(35_000, 10), 35)
})

test("a model's second line: size, speed once measured, German errors, each with its source", () => {
  const speed: Speed = { secondsPer10: 0.7, date: '2026-10-08T12:00:00.000Z', version: '0.4.1', machine: 'Apple M5 Pro, 18 cores' }
  const turbo = 'onnx-community/whisper-large-v3-turbo'
  assert.deepEqual(localFacts(turbo, 'de').map(fact => fact.text), ['981 MB', '3,7 % Fehler Deutsch'])
  const here = localFacts(turbo, 'de', { speed, here: true })
  assert.deepEqual(here.map(fact => fact.text), ['981 MB', '0,7 s für 10 s Sprechen', '3,7 % Fehler Deutsch'])
  assert.equal(here[1].help, 'Auf diesem Computer gemessen')
  assert.equal(here[2].help, 'FLEURS, Originalmodell, nicht die geladene Fassung')
  const brought = localFacts(turbo, 'en', { speed, here: false })
  assert.match(brought[1].help!, /^Measured on 10\/8\/2026 with satz 0\.4\.1 on Apple M5 Pro, 18 cores$/)
  assert.equal(localFacts(turbo, 'en', { errors: { 'openai/whisper-large-v3-turbo': 2.5 } })[1].text, '2.5 % errors in German')
  // The German fine-tune and the English-only model: no German number, their tags say what they are.
  assert.deepEqual(localFacts('onnx-community/whisper-large-v3-turbo-german-ONNX', 'de').map(fact => fact.text), ['983 MB'])
  assert.deepEqual(localFacts('onnx-community/distil-large-v3.5-ONNX', 'en', { errors: { 'distil-whisper/distil-large-v3.5': 40 } }).map(fact => fact.text), ['950 MB'])
  assert.deepEqual(localFacts('onnx-community/whisper-tiny', 'de').map(fact => fact.text), ['99 MB', '27,8 % Fehler Deutsch'])
  // One typed in by hand: nothing known until it is measured.
  assert.deepEqual(localFacts('someone/whisper-de', 'en'), [])
  assert.deepEqual(localFacts('someone/whisper-de', 'en', { speed, here: true }).map(fact => fact.text), ['0.7 s per 10 s of speech'])
})

test('a speed counts as measured here only on this computer with this satz', () => {
  const speed: Speed = { secondsPer10: 1, date: '2026-10-08T12:00:00.000Z', version: '0.4.1', machine: 'A, 8 cores' }
  assert.equal(measuredHere(speed, 'A, 8 cores', '0.4.1'), true)
  assert.equal(measuredHere(speed, 'B, 8 cores', '0.4.1'), false)
  assert.equal(measuredHere(speed, 'A, 8 cores', '0.4.2'), false)
})

test('the language is German or English, whatever else Whisper rates higher', () => {
  const logits = new Float32Array(10)
  const de = 3, en = 4, nl = 7
  logits[nl] = 9; logits[de] = 5; logits[en] = 2
  assert.equal(germanOrEnglish(logits, { de, en }), de)
  logits[en] = 6
  assert.equal(germanOrEnglish(logits, { de, en }), en)
  // A token the model does not have never wins, and none at all gives none.
  assert.equal(germanOrEnglish(logits, { de: undefined, en }), en)
  assert.equal(germanOrEnglish(logits, { de, en: null }), de)
  assert.equal(germanOrEnglish(logits, { de: 99, en: -1 }), undefined)
  assert.equal(germanOrEnglish(logits, {}), undefined)
})

test('a speed is kept beside the model, and a broken file reads as none', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-speed-'))
  try {
    const id = 'onnx-community/whisper-small'
    assert.equal(readSpeed(dir, id), null)
    const speed: Speed = { secondsPer10: 0.5, date: '2026-10-08T12:00:00.000Z', version: '0.4.1', machine: 'A, 8 cores' }
    writeSpeed(dir, id, speed)
    assert.equal(path.basename(speedPath(dir, id)), 'onnx-community--whisper-small.speed.json')
    assert.deepEqual(readSpeed(dir, id), speed)
    fs.writeFileSync(speedPath(dir, id), '{"secondsPer10": "fast"')
    assert.equal(readSpeed(dir, id), null)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('only "owner/name" ids reach the disk: nothing that leaves the models folder', () => {
  for (const id of localModels.map(model => model.id)) assert.equal(isModelId(id), true)
  for (const id of ['..', '../x', 'a/..', 'a/b/c', '/etc', 'a', '', 'a/ b', 'C:\\x/y', 42]) assert.equal(isModelId(id), false, String(id))
})

test("German errors: fetched once a day and kept; the shipped numbers whenever that fails", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-errors-'))
  try {
    let asked = 0
    const answer = (body: string, status = 200) => (async () => { asked++; return new Response(body, { status }) }) as unknown as typeof fetch
    // Offline: the shipped numbers, nothing kept.
    const offline = new GermanErrors(dir, () => {}, () => {}, (async () => { asked++; throw new Error('offline') }) as unknown as typeof fetch)
    await offline.refresh()
    assert.deepEqual(offline.get(), shippedGermanErrors)
    // An error page is not a leaderboard.
    await new GermanErrors(dir, () => {}, () => {}, answer('<html>', 200)).refresh()
    await new GermanErrors(dir, () => {}, () => {}, answer(leaderboard, 500)).refresh()
    assert.deepEqual(new GermanErrors(dir, () => {}, () => {}).get(), shippedGermanErrors)
    // Fetched: kept, and not asked again the same day.
    let changed = 0
    const live = new GermanErrors(dir, () => {}, () => { changed++ }, answer(leaderboard.replace('3.67', '3.5')))
    await live.refresh()
    assert.equal(changed, 1)
    assert.equal(live.get()['openai/whisper-large-v3-turbo'], 3.5)
    assert.equal(live.get()['openai/whisper-small'], 10.2)
    const before = asked
    await live.refresh()
    assert.equal(asked, before)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('the catalog knows each id it lists', () => {
  for (const model of localModels) assert.equal(localModel(model.id), model)
  assert.equal(localModel('onnx-community/whisper-tiny.en'), undefined)
})

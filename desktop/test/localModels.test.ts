import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  engineOf, formatGermanErrors, formatSize, formatSpeed, germanErrors, germanOrEnglish, languageLine, localModel, localModelIds, localModels,
  measuredHere, modelBars, offeredModels, onlyLanguage, parseGermanErrors, secondsPer10, shippedGermanErrors, speedScore, toldLanguage, type Speed,
} from '../src/core/localModels'
import { models } from '../src/core/models'
import { providers } from '../src/core/transcriber'
import { GermanErrors } from '../src/main/localBenchmarks'
import { isDownloaded, isModelId, markerPath, readSpeed, speedPath, writeSpeed } from '../src/main/localFiles'

/** The head of hf-audio/multilingual_evals' multilingual_de.csv as fetched on 08.10.2026, trimmed. */
const leaderboard = `model,RTFx,FLEURS WER,MCV WER
assemblyai/universal-3-5-pro,-1,2.17,2.69
openai/whisper-large-v3,327.55,3.2,4.79
openai/whisper-large-v3-turbo,338.32,3.67,8.58
TheStageAI/thewhisper-large-v3-turbo,960.42,2.91,3.17
`

const whisperIds = [
  'onnx-community/whisper-large-v3-turbo', 'onnx-community/whisper-large-v3-ONNX', 'onnx-community/whisper-medium-ONNX',
  'onnx-community/whisper-small', 'onnx-community/whisper-base', 'onnx-community/whisper-tiny',
  'onnx-community/whisper-large-v3-turbo-german-ONNX', 'onnx-community/distil-large-v3.5-ONNX']
const sherpaIds = ['sherpa/parakeet-v3', 'sherpa/canary-180m', 'sherpa/parakeet-v2', 'sherpa/moonshine-base', 'sherpa/sense-voice', 'sherpa/moonshine-tiny']

test("the catalog: the eight Whisper builds and Handy's six models, Turbo first as the default, real sizes", () => {
  assert.deepEqual(localModels.filter(model => model.engine === 'whisper').map(model => model.id).sort(), [...whisperIds].sort())
  assert.deepEqual(localModels.filter(model => model.engine === 'sherpa').map(model => model.id).sort(), [...sherpaIds].sort())
  assert.equal(localModels[0].id, providers.local.defaultModel)
  // Whisper: the sum of the three files satz loads; sherpa: every file, from each repo's file list (09.10.2026).
  const size = (id: string) => formatSize(localModel(id)!.bytes, 'en')
  assert.deepEqual(whisperIds.map(size), ['981 MB', '1.4 GB', '786 MB', '328 MB', '149 MB', '99 MB', '983 MB', '950 MB'])
  assert.deepEqual(sherpaIds.map(size), ['670 MB', '207 MB', '661 MB', '287 MB', '240 MB', '124 MB'])
  assert.equal(localModel('sherpa/parakeet-v3')!.bytes, 670_478_772)
  // The cloud menus and the local list name the same models, with their makers.
  assert.deepEqual(models.local.map(model => model.id).sort(), localModels.map(model => model.id).sort())
  assert.equal(models.local.find(model => model.id === 'onnx-community/whisper-large-v3-turbo-german-ONNX')?.maker, 'primeLine')
  assert.equal(models.local.find(model => model.id === 'sherpa/parakeet-v3')?.maker, 'NVIDIA')
})

test("Handy's scores, and one plain sentence each in German and English without em dashes", () => {
  const score = (id: string) => [localModel(id)!.accuracy, localModel(id)!.speed]
  assert.deepEqual(score('sherpa/parakeet-v3'), [0.80, 0.85])
  assert.deepEqual(score('sherpa/parakeet-v2'), [0.85, 0.85])
  assert.deepEqual(score('sherpa/canary-180m'), [0.75, 0.85])
  assert.deepEqual(score('sherpa/moonshine-base'), [0.70, 0.90])
  assert.deepEqual(score('sherpa/moonshine-tiny'), [0.55, 0.95])
  assert.deepEqual(score('sherpa/sense-voice'), [0.65, 0.95])
  assert.equal(localModel('onnx-community/whisper-large-v3-ONNX')!.accuracy, 0.85)
  assert.equal(localModel('onnx-community/whisper-tiny')!.accuracy, 0.35)
  assert.deepEqual(localModel('sherpa/parakeet-v3')!.description, { de: 'Schnell und genau. 25 europäische Sprachen.', en: 'Fast and accurate. 25 European languages.' })
  for (const model of localModels) {
    assert.ok(model.accuracy > 0 && model.accuracy <= 1 && model.speed > 0 && model.speed <= 1, model.id)
    assert.ok(model.description.de && model.description.en, model.id)
    assert.doesNotMatch(`${model.description.de} ${model.description.en}`, /—/)
  }
})

test('the order: the default, then those that write German by accuracy, the German-only one, then the rest by accuracy', () => {
  const rest = localModels.slice(1)
  const german = rest.filter(model => model.languages.includes('de') && model.languages.length > 1)
  const germanOnly = rest.filter(model => model.languages.length === 1 && model.languages[0] === 'de')
  const others = rest.filter(model => !model.languages.includes('de'))
  assert.deepEqual(rest, [...german, ...germanOnly, ...others])
  for (const group of [german, others]) {
    const scores = group.map(model => model.accuracy)
    assert.deepEqual(scores, [...scores].sort((a, b) => b - a))
  }
  assert.equal(localModels.at(-1)!.id, 'sherpa/moonshine-tiny')
})

test('Windows on ARM gets no sherpa-onnx models, without a word; everywhere satz ships, it gets all', () => {
  assert.deepEqual(offeredModels('win32', 'arm64').map(model => model.id), localModels.filter(model => model.engine === 'whisper').map(model => model.id))
  for (const [platform, arch] of [['win32', 'x64'], ['linux', 'x64'], ['linux', 'arm64'], ['darwin', 'arm64']]) assert.equal(offeredModels(platform, arch).length, localModels.length)
  assert.equal(localModelIds('onnx-community/whisper-small', offeredModels('win32', 'arm64')).length, 8)
  assert.equal(engineOf('sherpa/canary-180m'), 'sherpa')
  assert.equal(engineOf('onnx-community/whisper-small'), 'whisper')
  // Typed in by hand earlier: a Whisper repo.
  assert.equal(engineOf('someone/whisper-de'), 'whisper')
})

test('models satz cannot run, and the *.en ones, are never offered', () => {
  for (const { id } of localModels) {
    assert.doesNotMatch(id, /\.en$|lite-whisper|whisper-small-ONNX|whisper-large-v3-turbo-ONNX|^Xenova\//)
  }
})

test('a single-language model always decodes in its language; the others find out, and Canary is told', () => {
  assert.equal(onlyLanguage('onnx-community/whisper-large-v3-turbo-german-ONNX'), 'de')
  assert.equal(onlyLanguage('onnx-community/distil-large-v3.5-ONNX'), 'en')
  assert.equal(onlyLanguage('sherpa/parakeet-v2'), 'en')
  for (const id of ['onnx-community/whisper-large-v3-turbo', 'onnx-community/whisper-tiny', 'onnx-community/whisper-medium-ONNX', 'sherpa/parakeet-v3', 'sherpa/canary-180m', 'sherpa/sense-voice']) {
    assert.equal(onlyLanguage(id), undefined, id)
  }
  assert.equal(localModel('sherpa/canary-180m')!.language, 'spoken')
  // Typed in by hand: nothing known, Whisper tells.
  assert.equal(onlyLanguage('someone/whisper-de'), undefined)
})

test("Canary is told the language chosen for it among its four, else the app's spoken language; no other model is told one", () => {
  const canary = 'sherpa/canary-180m'
  assert.equal(toldLanguage(canary, null, 'de'), 'de')
  assert.equal(toldLanguage(canary, undefined, 'en'), 'en')
  assert.equal(toldLanguage(canary, 'es', 'de'), 'es')
  assert.equal(toldLanguage(canary, 'fr', 'en'), 'fr')
  // Something it does not write (an old or broken setting): the spoken language.
  assert.equal(toldLanguage(canary, 'it', 'en'), 'en')
  for (const id of ['onnx-community/whisper-large-v3-turbo', 'sherpa/parakeet-v3', 'sherpa/sense-voice', 'someone/whisper-de']) assert.equal(toldLanguage(id, 'es', 'de'), undefined, id)
})

test("the card's languages: one, two, a few named, many counted with the names in the help", () => {
  const line = (id: string, language: 'de' | 'en') => languageLine(localModel(id)!, language)
  assert.equal(line('onnx-community/whisper-large-v3-turbo', 'de').text, 'Deutsch und Englisch')
  assert.equal(line('onnx-community/whisper-large-v3-turbo', 'en').text, 'German and English')
  assert.equal(line('onnx-community/whisper-large-v3-turbo', 'de').help, 'Erkennt selbst, ob Deutsch oder Englisch gesprochen wird.')
  assert.equal(line('onnx-community/whisper-large-v3-turbo-german-ONNX', 'de').text, 'Nur Deutsch')
  assert.equal(line('sherpa/moonshine-tiny', 'de').text, 'Nur Englisch')
  assert.equal(line('sherpa/moonshine-tiny', 'en').text, 'English only')
  assert.equal(line('sherpa/canary-180m', 'de').text, 'Englisch, Deutsch, Spanisch, Französisch')
  assert.equal(line('sherpa/canary-180m', 'de').help, 'Hört auf die Sprache unter „Gesprochen auf“.')
  assert.equal(line('sherpa/sense-voice', 'de').text, 'Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch')
  assert.equal(line('sherpa/sense-voice', 'en').text, 'Chinese, English, Japanese, Korean, Cantonese')
  const parakeet = line('sherpa/parakeet-v3', 'de')
  assert.equal(parakeet.text, '25 Sprachen')
  assert.match(parakeet.help, /^Erkennt die Sprache selbst\. Bulgarisch, Kroatisch, .*Deutsch.*, Ukrainisch\.$/)
  assert.equal(line('sherpa/parakeet-v3', 'en').text, '25 languages')
  for (const model of localModels) for (const language of ['de', 'en'] as const) assert.doesNotMatch(Object.values(languageLine(model, language)).join(' '), /—/)
})

test('a model typed in earlier gets its own card, after the list', () => {
  assert.deepEqual(localModelIds('onnx-community/whisper-small'), localModels.map(model => model.id))
  assert.deepEqual(localModelIds('someone/whisper-de').slice(-1), ['someone/whisper-de'])
  assert.equal(localModelIds('').length, localModels.length)
})

test('the German leaderboard is read by column name, and only for the models satz offers that write German', () => {
  assert.deepEqual(parseGermanErrors(leaderboard), { 'openai/whisper-large-v3': 3.2, 'openai/whisper-large-v3-turbo': 3.67 })
  // Parakeet V3 writes German; its GPU-only variant is another row.
  assert.deepEqual(parseGermanErrors(`${leaderboard}nvidia/parakeet-tdt-0.6b-v3,3362.94,4.16,4.07\nnvidia/parakeet-tdt-0.6b-v3 (fast-gpu-asr),1,4.06,3.9\nnvidia/parakeet-tdt-0.6b-v2,1,50,50\n`),
    { 'openai/whisper-large-v3': 3.2, 'openai/whisper-large-v3-turbo': 3.67, 'nvidia/parakeet-tdt-0.6b-v3': 4.16 })
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
  assert.equal(formatGermanErrors(3.67, 'de'), '3,7 % Fehler auf Deutsch')
  assert.equal(formatGermanErrors(3.67, 'en'), '3.7 % errors in German')
})

test('seconds per 10 s of speech from a warm run', () => {
  assert.equal(secondsPer10(700, 10), 0.7)
  assert.equal(secondsPer10(1400, 20), 0.7)
  assert.equal(secondsPer10(35_000, 10), 35)
})

test('the speed bar: seconds per 10 s on a log scale, 0.2 s full, 1 s at 0.7, 3 s at 0.4, 10 s at 0.1', () => {
  const near = (value: number, expected: number) => assert.ok(Math.abs(value - expected) < 1e-9, `${value} ≠ ${expected}`)
  near(speedScore(0.2), 1)
  near(speedScore(0.05), 1)
  near(speedScore(1), 0.7)
  near(speedScore(3), 0.4)
  near(speedScore(10), 0.1)
  near(speedScore(60), 0.1)
  // Between the points, by the ratio: 0.2 to 1 s halfway is √0.2 ≈ 0.45 s.
  near(speedScore(Math.sqrt(0.2)), 0.85)
  for (let s = 0.1; s < 20; s *= 1.3) assert.ok(speedScore(s) >= speedScore(s * 1.3), `not falling at ${s}`)
  assert.equal(speedScore(Number.NaN), 1)
})

test("a card's bars: Handy's accuracy with the German error rate behind it, speed measured here or estimated", () => {
  const speed: Speed = { secondsPer10: 0.7, date: '2026-10-08T12:00:00.000Z', version: '0.4.1', machine: 'Apple M5 Pro, 18 cores' }
  const turbo = 'onnx-community/whisper-large-v3-turbo'
  const plain = modelBars(turbo, 'de')
  assert.equal(plain.accuracy!.value, 0.80)
  assert.equal(plain.accuracy!.help, '3,7 % Fehler auf Deutsch (FLEURS, Originalmodell, nicht die geladene Fassung)')
  assert.equal(plain.speed!.value, 0.40)
  assert.equal(plain.speed!.help, 'Geschätzt. satz misst das Tempo nach dem Laden.')
  assert.equal(modelBars(turbo, 'en', { downloaded: true }).speed!.help, 'Estimated, not measured on this computer yet')
  const here = modelBars(turbo, 'de', { speed, here: true })
  assert.equal(here.speed!.value, speedScore(0.7))
  assert.equal(here.speed!.help, '0,7 s für 10 s Sprechen, gemessen auf diesem Computer')
  assert.match(modelBars(turbo, 'en', { speed, here: false }).speed!.help, /^0\.7 s per 10 s of speech, measured on 10\/8\/2026 with satz 0\.4\.1 on Apple M5 Pro, 18 cores$/)
  assert.match(modelBars(turbo, 'en', { errors: { 'openai/whisper-large-v3-turbo': 2.5 } }).accuracy!.help, /^2\.5 % errors in German/)
  assert.equal(modelBars('sherpa/parakeet-v3', 'en').accuracy!.help, '4.2 % errors in German (FLEURS, full model, not the downloaded build)')
  // No German number where there is none, or where the model writes no German.
  assert.equal(modelBars('onnx-community/whisper-large-v3-turbo-german-ONNX', 'de').accuracy!.help, 'Geschätzt')
  assert.equal(modelBars('onnx-community/distil-large-v3.5-ONNX', 'en', { errors: { 'distil-whisper/distil-large-v3.5': 40 } }).accuracy!.help, 'Estimated')
  assert.equal(modelBars('sherpa/canary-180m', 'en').accuracy!.help, 'Estimated')
  // One typed in by hand: nothing until it is measured.
  assert.deepEqual(modelBars('someone/whisper-de', 'en'), {})
  assert.deepEqual(Object.keys(modelBars('someone/whisper-de', 'en', { speed, here: true })), ['speed'])
  for (const model of localModels) for (const language of ['de', 'en'] as const) {
    const bars = modelBars(model.id, language, { speed })
    assert.doesNotMatch(`${bars.accuracy?.help} ${bars.speed?.help}`, /—/)
  }
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

test('a sherpa-onnx model counts as downloaded only with its marker and every one of its files', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-sherpa-files-'))
  try {
    const id = 'sherpa/canary-180m'
    const folder = path.join(dir, id)
    fs.mkdirSync(folder, { recursive: true })
    for (const file of localModel(id)!.sherpa!.files) fs.writeFileSync(path.join(folder, file.name), 'x')
    assert.equal(isDownloaded(dir, id), false)
    fs.writeFileSync(markerPath(dir, id), 'now')
    assert.equal(path.basename(markerPath(dir, id)), 'sherpa--canary-180m.ready')
    assert.equal(isDownloaded(dir, id), true)
    // A file gone: not there any more, and the marker goes with it.
    fs.rmSync(path.join(folder, 'decoder.int8.onnx'))
    assert.equal(isDownloaded(dir, id), false)
    assert.equal(fs.existsSync(markerPath(dir, id)), false)
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

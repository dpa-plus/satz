import type { Language } from './language'
import { runsSherpa, type SherpaFile, type SherpaSource } from './sherpa'

/**
 * The models satz offers for the provider "Lokal", one card each in
 * Settings: what each downloads, what it is good at, Handy's scores for its
 * accuracy and speed, the published German error rate where there is one,
 * and how fast it ran on this computer once measured. The one place these
 * models are named; the settings, the download's progress bar, the model
 * menus and both engines read it.
 *
 * Two engines. Whisper runs through transformers.js (whisperEngine.ts): all
 * are onnx-community repos whose three files satz loads (localFiles.ts)
 * exist and whose 4-bit decoders take no `cache_position`, which
 * transformers.js 4.3.1 never sends; each was run end to end on 09.10.2026.
 * Left out on purpose: the *.en models (one model for English alone is
 * enough: Distil Large v3.5), lite-whisper (no language table),
 * whisper-small-ONNX and whisper-large-v3-turbo-ONNX (their 4-bit decoders
 * want `cache_position`) and Xenova/whisper-large* (no 4-bit decoder).
 * Handy's models run through sherpa-onnx (sherpaEngine.ts), from single
 * files in csukuangfj's repos (core/sherpa.ts).
 */
export interface LocalModel {
  id: string
  name: string
  engine: 'whisper' | 'sherpa'
  /** One plain sentence under the name. */
  description: { de: string; en: string }
  /** What is downloaded: Whisper's 8-bit encoder, 4-bit decoder and tokenizer.json (the few kB of JSON beside them left out), or every sherpa file. */
  bytes: number
  /** The original model, as the benchmarks name it. */
  original: string
  /** Who made the original, for the model menus. */
  maker: string
  /**
   * How it knows which language it hears. 'auto': it finds out itself
   * (Whisper between German and English, Parakeet V3 and SenseVoice among
   * theirs). 'spoken': it is told the one set under "Gesprochen auf"
   * (Canary). A language: the only one it writes, and always told that one
   * (onlyLanguage): Distil Large v3.5 writes English only, and primeLine
   * tuned theirs on German alone.
   */
  language: 'auto' | 'spoken' | Language
  /** What it writes, as language codes ("yue" is Cantonese): the card's globe line. Whisper's are the two satz lets it choose from. */
  languages: string[]
  /** Handy's scores from 0 to 1, the card's two bars. The speed counts until the model is measured here. */
  accuracy: number
  speed: number
  /** Where a sherpa-onnx model's files come from, and how it runs. */
  sherpa?: SherpaSource
}

const whisper = { engine: 'whisper' as const, language: 'auto' as const, languages: ['de', 'en'], maker: 'OpenAI' }
const total = (files: SherpaFile[]) => files.reduce((sum, file) => sum + file.bytes, 0)

/** One sherpa-onnx model; its size is the sum of its files. */
function sherpaModel(model: Omit<LocalModel, 'engine' | 'bytes' | 'sherpa'>, sherpa: SherpaSource): LocalModel {
  return { ...model, engine: 'sherpa', bytes: total(sherpa.files), sherpa }
}

// The 25 languages NVIDIA lists for Parakeet TDT 0.6B v3, as Handy has them.
const european = ['bg', 'hr', 'cs', 'da', 'nl', 'en', 'et', 'fi', 'fr', 'de', 'el', 'hu', 'it', 'lv', 'lt', 'mt', 'pl', 'pt', 'ro', 'sk', 'sl', 'es', 'sv', 'ru', 'uk']

/**
 * The default first. Then those that write German, most accurate first;
 * the German-only one; then those that write no German, most accurate
 * first. Sizes and checksums from each repo's file list (09.10.2026).
 */
export const localModels: LocalModel[] = [
  { ...whisper, id: 'onnx-community/whisper-large-v3-turbo', name: 'Whisper Large v3 Turbo', bytes: 981_450_034, original: 'openai/whisper-large-v3-turbo',
    description: { de: 'Ausgewogen: genau und schnell.', en: 'Balanced: accurate and fast.' }, accuracy: 0.80, speed: 0.40 },
  { ...whisper, id: 'onnx-community/whisper-large-v3-ONNX', name: 'Whisper Large v3', bytes: 1_445_984_744, original: 'openai/whisper-large-v3',
    description: { de: 'Sehr genau, aber langsam.', en: 'Very accurate, but slow.' }, accuracy: 0.85, speed: 0.30 },
  sherpaModel({ id: 'sherpa/parakeet-v3', name: 'Parakeet V3', original: 'nvidia/parakeet-tdt-0.6b-v3', maker: 'NVIDIA', language: 'auto', languages: european,
    description: { de: 'Schnell und genau. 25 europäische Sprachen.', en: 'Fast and accurate. 25 European languages.' }, accuracy: 0.80, speed: 0.85 }, {
    kind: 'nemo-transducer', repo: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8', revision: '2bda32ec70b097a55adaa07d9a7173915b43cc78', windowed: false, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 652_184_281, sha256: 'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 11_845_275, sha256: '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e' },
      { name: 'joiner.int8.onnx', role: 'joiner', bytes: 6_355_277, sha256: '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3' },
      { name: 'tokens.txt', role: 'tokens', bytes: 93_939, sha256: 'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d' },
    ] }),
  { ...whisper, id: 'onnx-community/whisper-medium-ONNX', name: 'Whisper Medium', bytes: 786_438_953, original: 'openai/whisper-medium',
    description: { de: 'Gute Genauigkeit, mittleres Tempo.', en: 'Good accuracy, medium speed.' }, accuracy: 0.75, speed: 0.60 },
  sherpaModel({ id: 'sherpa/canary-180m', name: 'Canary 180M Flash', original: 'nvidia/canary-180m-flash', maker: 'NVIDIA', language: 'spoken', languages: ['en', 'de', 'es', 'fr'],
    description: { de: 'Sehr schnell. Englisch, Deutsch, Spanisch, Französisch.', en: 'Very fast. English, German, Spanish, French.' }, accuracy: 0.75, speed: 0.85 }, {
    kind: 'canary', repo: 'sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8', revision: '9077164e0d3dd1d5353743e89ceaa1d3a770838c', windowed: true, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 132_678_643, sha256: '7a75b4e2a5857a6dcc0819503bbe3fad66943db4a3ccf21d3f27c633667d303f' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 74_437_848, sha256: 'e41a2ab9c0c2fe81a1e8ade5a45fb02a74bc4db7d1f91b89a54a25e2cf79cba2' },
      { name: 'tokens.txt', role: 'tokens', bytes: 53_555, sha256: '2dae6fc7815f9640645e0c765522b278ee0cef49b482d91f6913e334628d3e77' },
    ] }),
  { ...whisper, id: 'onnx-community/whisper-small', name: 'Whisper Small', bytes: 327_955_953, original: 'openai/whisper-small',
    description: { de: 'Schnell, ordentlich auf Englisch.', en: 'Fast, decent in English.' }, accuracy: 0.60, speed: 0.85 },
  { ...whisper, id: 'onnx-community/whisper-base', name: 'Whisper Base', bytes: 149_284_199, original: 'openai/whisper-base',
    description: { de: 'Sehr schnell, ungenau.', en: 'Very fast, rough.' }, accuracy: 0.45, speed: 0.90 },
  { ...whisper, id: 'onnx-community/whisper-tiny', name: 'Whisper Tiny', bytes: 99_319_158, original: 'openai/whisper-tiny',
    description: { de: 'Am schnellsten, sehr ungenau.', en: 'Fastest, very rough.' }, accuracy: 0.35, speed: 0.95 },
  { ...whisper, id: 'onnx-community/whisper-large-v3-turbo-german-ONNX', name: 'Whisper Large v3 Turbo German', bytes: 982_774_635, original: 'primeLine/whisper-large-v3-turbo-german',
    maker: 'primeLine', language: 'de', languages: ['de'], description: { de: 'Turbo, auf Deutsch trainiert.', en: 'Turbo, trained on German.' }, accuracy: 0.80, speed: 0.40 },
  sherpaModel({ id: 'sherpa/parakeet-v2', name: 'Parakeet V2', original: 'nvidia/parakeet-tdt-0.6b-v2', maker: 'NVIDIA', language: 'en', languages: ['en'],
    description: { de: 'Nur Englisch, das beste für Englisch.', en: 'English only. The best for English.' }, accuracy: 0.85, speed: 0.85 }, {
    kind: 'nemo-transducer', repo: 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8', revision: '1ab9323565ddb038682214b292f588070a538ce2', windowed: false, files: [
      { name: 'encoder.int8.onnx', role: 'encoder', bytes: 652_184_296, sha256: 'a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab' },
      { name: 'decoder.int8.onnx', role: 'decoder', bytes: 7_257_753, sha256: 'b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e' },
      { name: 'joiner.int8.onnx', role: 'joiner', bytes: 1_739_080, sha256: '7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2' },
      { name: 'tokens.txt', role: 'tokens', bytes: 9_384, sha256: 'ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d' },
    ] }),
  { ...whisper, id: 'onnx-community/distil-large-v3.5-ONNX', name: 'Distil-Whisper Large v3.5', bytes: 949_690_520, original: 'distil-whisper/distil-large-v3.5',
    maker: 'Hugging Face', language: 'en', languages: ['en'], description: { de: 'Schnell, nur Englisch.', en: 'Fast, English only.' }, accuracy: 0.75, speed: 0.45 },
  sherpaModel({ id: 'sherpa/moonshine-base', name: 'Moonshine Base', original: 'UsefulSensors/moonshine-base', maker: 'Useful Sensors', language: 'en', languages: ['en'],
    description: { de: 'Sehr schnell, nur Englisch. Kommt gut mit Akzenten klar.', en: 'Very fast, English only. Handles accents well.' }, accuracy: 0.70, speed: 0.90 }, {
    kind: 'moonshine', repo: 'sherpa-onnx-moonshine-base-en-int8', revision: '052b0798ad1bf046a140fdd4efcd9426530fa3f5', windowed: true, files: [
      { name: 'preprocess.onnx', role: 'preprocessor', bytes: 14_077_290, sha256: 'ffa630d395c5ccf76f5d4954be5b882df76aaf6491519ec01fd82ea7a3819fb2' },
      { name: 'encode.int8.onnx', role: 'encoder', bytes: 50_311_494, sha256: '7e38770f776f2e5583a53b052936005df2ba5c833d7e09c2a5fd796b94bf73e2' },
      { name: 'uncached_decode.int8.onnx', role: 'uncachedDecoder', bytes: 122_120_451, sha256: 'c01f4b35093bcac20d352d23a75a539e772964579f9d024a90e5e6f09cae9987' },
      { name: 'cached_decode.int8.onnx', role: 'cachedDecoder', bytes: 99_983_837, sha256: '2db74e51cedf64a8b1be3c8192e0bb5e4923af0e90bd9e87f8e8771873f8ea03' },
      { name: 'tokens.txt', role: 'tokens', bytes: 436_688, sha256: '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea' },
    ] }),
  // The original export: the 2025-09-09 one is tuned for Cantonese and wrote
  // English as "PNNYES … BULLDOSZING THE GROOSSER" (this one writes it right).
  sherpaModel({ id: 'sherpa/sense-voice', name: 'SenseVoice', original: 'FunAudioLLM/SenseVoiceSmall', maker: 'Alibaba', language: 'auto', languages: ['zh', 'en', 'ja', 'ko', 'yue'],
    description: { de: 'Sehr schnell. Chinesisch, Englisch, Japanisch, Koreanisch, Kantonesisch.', en: 'Very fast. Chinese, English, Japanese, Korean, Cantonese.' }, accuracy: 0.65, speed: 0.95 }, {
    kind: 'sense-voice', repo: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', revision: '2365baeacb507f821a0c8120fcee3d484dba7a07', windowed: true, files: [
      { name: 'model.int8.onnx', role: 'model', bytes: 239_233_841, sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51' },
      { name: 'tokens.txt', role: 'tokens', bytes: 315_894, sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc' },
    ] }),
  sherpaModel({ id: 'sherpa/moonshine-tiny', name: 'Moonshine Tiny', original: 'UsefulSensors/moonshine-tiny', maker: 'Useful Sensors', language: 'en', languages: ['en'],
    description: { de: 'Extrem schnell, nur Englisch.', en: 'Extremely fast, English only.' }, accuracy: 0.55, speed: 0.95 }, {
    kind: 'moonshine', repo: 'sherpa-onnx-moonshine-tiny-en-int8', revision: 'bf2b762c076d8ea61e2af0b3851c9564fb77552e', windowed: true, files: [
      { name: 'preprocess.onnx', role: 'preprocessor', bytes: 6_800_738, sha256: 'f33addce61a143460fe753b5ee5b7db255e5140b5b779c065b94f6c83ff0bf4e' },
      { name: 'encode.int8.onnx', role: 'encoder', bytes: 18_249_187, sha256: '8774dfba578de027ec6595c2c654a0836434489bc963a0db124a7f181f571acb' },
      { name: 'uncached_decode.int8.onnx', role: 'uncachedDecoder', bytes: 53_216_096, sha256: '216737000dd5881a17aa043f6bbd286add33e4c3b0ae257153e2ec15438bdc41' },
      { name: 'cached_decode.int8.onnx', role: 'cachedDecoder', bytes: 45_264_830, sha256: '2aff28bba6a03d8dcf5c9feac45462629bae37317442299f28115ad09da773f6' },
      { name: 'tokens.txt', role: 'tokens', bytes: 436_688, sha256: '1165c2aeb9f72f457a83be2d459a09054f27490acd9b41bd43794dfd25e296ea' },
    ] }),
]

/** The catalog's entry for an id, undefined for one typed in by hand earlier. */
export const localModel = (id: string) => localModels.find(model => model.id === id)

/** The models this system can run: sherpa-onnx has no build for Windows on ARM, so there its models are left out without a word. */
export const offeredModels = (platform: string, arch: string) => localModels.filter(model => model.engine !== 'sherpa' || runsSherpa(platform, arch))

/** The cards Settings shows: the models offered, and the model in use when it is not in the catalog. */
export const localModelIds = (inUse: string, offered: LocalModel[] = localModels) =>
  [...offered.map(model => model.id), ...(inUse && !localModel(inUse) ? [inUse] : [])]

/** The engine an id runs on; one typed in by hand is a Whisper repo. */
export const engineOf = (id: string) => localModel(id)?.engine ?? 'whisper'

/** The language a single-language model always decodes in; undefined where the model finds out (or is told) and for a model typed in by hand. */
export function onlyLanguage(id: string): Language | undefined {
  const language = localModel(id)?.language
  return language === 'de' || language === 'en' ? language : undefined
}

/**
 * What a model that cannot tell the language (Canary) is told: the one
 * chosen for it among those it writes, else the language set under
 * "Gesprochen auf" (German or English, the app's own setting, which Whisper
 * and the replacements use), else its first. Undefined for every other model.
 */
export function toldLanguage(id: string, chosen: string | null | undefined, spoken: Language): string | undefined {
  const model = localModel(id)
  if (model?.language !== 'spoken') return undefined
  if (chosen && model.languages.includes(chosen)) return chosen
  return model.languages.includes(spoken) ? spoken : model.languages[0]
}

/** A German error rate means something only for a model that writes German. */
const hearsGerman = (model: LocalModel) => model.languages.includes('de')

// MARK: - German errors

/**
 * Word error rate in German on FLEURS, of the original models (satz runs
 * 8-bit and 4-bit builds; nobody publishes numbers for those). Large v3,
 * Turbo and Parakeet V3 from the Open ASR Leaderboard's German file (checked
 * against it on 09.10.2026: 3.2, 3.67 and 4.16), medium, small, base and tiny
 * from the Whisper paper (arXiv 2212.04356, Table 13), the only place they
 * are published. None for the German fine-tune and Canary 180M Flash (the
 * leaderboard has no row for them) and the models that write no German.
 */
export const shippedGermanErrors: Record<string, number> = {
  'openai/whisper-large-v3-turbo': 3.67,
  'openai/whisper-large-v3': 3.2,
  'nvidia/parakeet-tdt-0.6b-v3': 4.16,
  'openai/whisper-medium': 6.5,
  'openai/whisper-small': 10.2,
  'openai/whisper-base': 17.9,
  'openai/whisper-tiny': 27.8,
}

/** The leaderboard's German results; a new row there reaches satz within a day. */
export const germanErrorsURL = 'https://huggingface.co/datasets/hf-audio/multilingual_evals/resolve/main/multilingual_de.csv'

/**
 * `model,RTFx,FLEURS WER,MCV WER`, read by the column names: the leaderboard
 * has added and dropped columns several times. Only the models satz offers
 * that write German; a row that is not a number between 0 and 100 is left out.
 */
export function parseGermanErrors(csv: string): Record<string, number> {
  const [header, ...rows] = csv.split(/\r?\n/).filter(line => line.trim()).map(csvFields)
  const model = header?.indexOf('model') ?? -1
  const wer = header?.indexOf('FLEURS WER') ?? -1
  if (model < 0 || wer < 0) return {}
  const wanted = new Set(localModels.filter(hearsGerman).map(entry => entry.original))
  const found: Record<string, number> = {}
  for (const row of rows) {
    const rate = Number(row[wer])
    if (wanted.has(row[model]) && row[wer]?.trim() && rate > 0 && rate < 100) found[row[model]] = rate
  }
  return found
}

/** One CSV line's fields; quotes allow commas inside a field. */
function csvFields(line: string): string[] {
  const fields: string[] = []
  let field = '', quoted = false
  for (let i = 0; i < line.length; i++) {
    const c = line[i]
    if (quoted && c === '"' && line[i + 1] === '"') { field += '"'; i++ }
    else if (c === '"') quoted = !quoted
    else if (c === ',' && !quoted) { fields.push(field.trim()); field = '' }
    else field += c
  }
  fields.push(field.trim())
  return fields
}

/** Today's numbers where the leaderboard has them, the shipped ones for the rest. */
export const germanErrors = (live: Record<string, number> = {}) => ({ ...shippedGermanErrors, ...live })

// MARK: - Speed

/** What a speed test on this computer found, kept beside the model (`<id>.speed.json`). */
export interface Speed {
  /** Seconds of work for 10 seconds of speech: what waiting after a dictation feels like. */
  secondsPer10: number
  /** ISO date of the test. */
  date: string
  /** The satz that measured it. */
  version: string
  /** Processor and core count. */
  machine: string
}

/** One run's wall time over a clip, as seconds per 10 s of speech. */
export const secondsPer10 = (elapsedMs: number, clipSeconds: number) => (elapsedMs / 1000) * 10 / clipSeconds

/** Measured on this computer with this satz; anything else is shown with its date. */
export const measuredHere = (speed: Speed, machine: string, version: string) => speed.machine === machine && speed.version === version

/**
 * The speed bar for a measured model: seconds per 10 s of speech on a log
 * scale, 0.2 s or less full, 1 s at 0.7, 3 s at 0.4, 10 s or more at 0.1.
 * Waiting feels like a ratio: 0.5 s against 1 s matters as much as 5 against 10.
 */
export function speedScore(secondsPer10: number): number {
  const points: [number, number][] = [[0.2, 1], [1, 0.7], [3, 0.4], [10, 0.1]]
  if (!(secondsPer10 > points[0][0])) return 1
  for (let i = 1; i < points.length; i++) {
    const [[s0, v0], [s1, v1]] = [points[i - 1], points[i]]
    if (secondsPer10 <= s1) return v0 + (v1 - v0) * (Math.log(secondsPer10 / s0) / Math.log(s1 / s0))
  }
  return 0.1
}

// MARK: - Words

const number = (value: number, digits: number, language: Language) =>
  value.toLocaleString(language === 'de' ? 'de-DE' : 'en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })

/** "981 MB", "1,4 GB" (decimal units, as the download's own file sizes). */
export function formatSize(bytes: number, language: Language): string {
  const mb = Math.round(bytes / 1e6)
  return mb < 1000 ? `${mb} MB` : `${number(bytes / 1e9, 1, language)} GB`
}

/** "0,7 s für 10 s Sprechen"; whole seconds from ten on. */
export function formatSpeed(seconds: number, language: Language): string {
  const shown = number(Math.max(0.1, seconds), seconds < 10 ? 1 : 0, language)
  return language === 'de' ? `${shown} s für 10 s Sprechen` : `${shown} s per 10 s of speech`
}

export function formatGermanErrors(rate: number, language: Language): string {
  return language === 'de' ? `${number(rate, 1, language)} % Fehler auf Deutsch` : `${number(rate, 1, language)} % errors in German`
}

/** A language's name in German or English ("Kantonesisch"). */
export const languageName = (code: string, language: Language) => new Intl.DisplayNames([language], { type: 'language' }).of(code) ?? code

/**
 * The card's globe line: "Nur Englisch", "Deutsch und Englisch",
 * "Englisch, Deutsch, Spanisch, Französisch", "25 Sprachen"; the help says
 * how the model knows which one it hears, and lists them where the line
 * only counts them.
 */
export function languageLine(model: LocalModel, language: Language): { text: string; help: string } {
  const t = (de: string, en: string) => (language === 'de' ? de : en)
  const names = model.languages.map(code => languageName(code, language))
  const text = names.length === 1 ? t(`Nur ${names[0]}`, `${names[0]} only`)
    : names.length === 2 ? t(`${names[0]} und ${names[1]}`, `${names[0]} and ${names[1]}`)
      : names.length <= 5 ? names.join(', ') : t(`${names.length} Sprachen`, `${names.length} languages`)
  const how = model.language === 'spoken' ? t('Hört auf die Sprache unter „Gesprochen auf“.', 'Listens for the language set under "Spoken in".')
    : model.language !== 'auto' ? t('Schreibt nur diese Sprache.', 'Writes this language only.')
      : model.engine === 'whisper' ? t('Erkennt selbst, ob Deutsch oder Englisch gesprochen wird.', 'Tells German from English by itself.')
        : t('Erkennt die Sprache selbst.', 'Tells the language by itself.')
  return { text, help: names.length > 5 ? `${how} ${names.join(', ')}.` : how }
}

/** A bar on a model's card: how full, and the numbers behind it. */
export interface Bar { value: number; help: string }

/**
 * The two bars on a model's card. Accuracy is Handy's score, with the
 * published German error rate in its help where there is one. Speed comes
 * from the measurement on this computer once there is one, else from the
 * fixed score, and says which. A model typed in by hand has no accuracy and
 * a speed only once measured.
 */
export function modelBars(id: string, language: Language, options: { speed?: Speed | null; here?: boolean; errors?: Record<string, number>; downloaded?: boolean } = {}): { accuracy?: Bar; speed?: Bar } {
  const t = (de: string, en: string) => (language === 'de' ? de : en)
  const model = localModel(id)
  const rate = model && hearsGerman(model) ? germanErrors(options.errors)[model.original] : undefined
  const accuracy = model && {
    value: model.accuracy,
    help: rate === undefined ? t('Geschätzt', 'Estimated')
      : `${formatGermanErrors(rate, language)} ${t('(FLEURS, Originalmodell, nicht die geladene Fassung)', '(FLEURS, full model, not the downloaded build)')}`,
  }
  const measured = options.speed
  let speed: Bar | undefined
  if (measured) {
    const date = new Date(measured.date).toLocaleDateString(language === 'de' ? 'de-DE' : 'en-US')
    speed = { value: speedScore(measured.secondsPer10), help: `${formatSpeed(measured.secondsPer10, language)}, ${options.here
      ? t('gemessen auf diesem Computer', 'measured on this computer')
      : t(`gemessen am ${date} mit satz ${measured.version} auf ${measured.machine}`, `measured on ${date} with satz ${measured.version} on ${measured.machine}`)}` }
  } else if (model) {
    speed = { value: model.speed, help: options.downloaded
      ? t('Geschätzt, noch nicht auf diesem Computer gemessen', 'Estimated, not measured on this computer yet')
      : t('Geschätzt. satz misst das Tempo nach dem Laden.', 'Estimated. satz measures the speed after downloading.') }
  }
  return { ...(accuracy ? { accuracy } : {}), ...(speed ? { speed } : {}) }
}

// MARK: - Language

/**
 * Whisper's language guess, between German and English only: its pick over
 * all its languages made the small models hear Dutch, and a model without a
 * language table failed every dictation. `logits` are the scores of the first
 * token after the start; a token the model does not have never wins.
 */
export function germanOrEnglish(logits: ArrayLike<number>, tokens: { de?: number | null; en?: number | null }): number | undefined {
  const usable = [tokens.de, tokens.en].filter((token): token is number => typeof token === 'number' && token >= 0 && token < logits.length)
  return usable.reduce<number | undefined>((best, next) => (best === undefined || logits[next] > logits[best] ? next : best), undefined)
}

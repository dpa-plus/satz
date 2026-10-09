import type { Language } from './language'

/**
 * The Whisper builds satz offers for the provider "Lokal", one row each in
 * Settings: what each downloads, the published German error rate of its
 * original model, and how fast it ran on this computer once measured. The one
 * place these models are named; the settings, the download's progress bar and
 * the model menus all read it.
 *
 * All are onnx-community repos whose three files satz loads (localFiles.ts)
 * exist and whose 4-bit decoders take no `cache_position`, which
 * transformers.js 4.3.1 never sends; each was run end to end on 09.10.2026.
 * Left out on purpose: the *.en models (one model for English alone is
 * enough: Distil Large v3.5), lite-whisper (no language table),
 * whisper-small-ONNX and whisper-large-v3-turbo-ONNX (their 4-bit decoders
 * want `cache_position`) and Xenova/whisper-large* (no 4-bit decoder).
 */
export interface LocalModel {
  id: string
  name: string
  /** A quiet word after the name, where the model is a trade-off. */
  tag?: { de: string; en: string }
  /** The 8-bit encoder, the 4-bit decoder and tokenizer.json, from the repo's file list; the few kB of JSON beside them are left out. */
  bytes: number
  /** The original model, as the benchmarks name it. */
  original: string
  /** Who made the original, for the model menus. */
  maker: string
  /**
   * What it is made for. A model for one language is always told that one
   * (onlyLanguage), never asked which it hears: Distil Large v3.5 writes
   * English only, and primeLine tuned theirs on German alone.
   */
  language: 'both' | Language
}

const either = { language: 'both', maker: 'OpenAI' } as const

/** The default first, then by how well they hear German; the single-language ones after, the roughest last. */
export const localModels: LocalModel[] = [
  { id: 'onnx-community/whisper-large-v3-turbo', name: 'Whisper Large v3 Turbo', bytes: 981_450_034, original: 'openai/whisper-large-v3-turbo', ...either },
  { id: 'onnx-community/whisper-large-v3-ONNX', name: 'Whisper Large v3', tag: { de: 'am genauesten, langsam', en: 'most accurate, slow' }, bytes: 1_445_984_744, original: 'openai/whisper-large-v3', ...either },
  { id: 'onnx-community/whisper-medium-ONNX', name: 'Whisper Medium', bytes: 786_438_953, original: 'openai/whisper-medium', ...either },
  { id: 'onnx-community/whisper-small', name: 'Whisper Small', bytes: 327_955_953, original: 'openai/whisper-small', ...either },
  { id: 'onnx-community/whisper-base', name: 'Whisper Base', tag: { de: 'schnell, ungenau', en: 'fast, rough' }, bytes: 149_284_199, original: 'openai/whisper-base', ...either },
  { id: 'onnx-community/whisper-large-v3-turbo-german-ONNX', name: 'Whisper Large v3 Turbo German', tag: { de: 'nur Deutsch', en: 'German only' }, bytes: 982_774_635, original: 'primeLine/whisper-large-v3-turbo-german', maker: 'primeLine', language: 'de' },
  { id: 'onnx-community/distil-large-v3.5-ONNX', name: 'Distil-Whisper Large v3.5', tag: { de: 'nur Englisch', en: 'English only' }, bytes: 949_690_520, original: 'distil-whisper/distil-large-v3.5', maker: 'Hugging Face', language: 'en' },
  { id: 'onnx-community/whisper-tiny', name: 'Whisper Tiny', tag: { de: 'sehr ungenau', en: 'very rough' }, bytes: 99_319_158, original: 'openai/whisper-tiny', ...either },
]

/** The catalog's entry for an id, undefined for one typed in by hand earlier. */
export const localModel = (id: string) => localModels.find(model => model.id === id)

/** The rows Settings shows: the catalog, and the model in use when it is not in it. */
export const localModelIds = (inUse: string) => [...localModels.map(model => model.id), ...(inUse && !localModel(inUse) ? [inUse] : [])]

/** The language a single-language model always decodes in; undefined where Whisper tells German from English itself (and for a model typed in by hand). */
export function onlyLanguage(id: string): Language | undefined {
  const language = localModel(id)?.language
  return language === 'both' ? undefined : language
}

/** A German error rate means something only for a model that writes German. */
const hearsGerman = (model: LocalModel) => model.language !== 'en'

// MARK: - German errors

/**
 * Word error rate in German on FLEURS, of the original models (satz runs an
 * 8-bit encoder and a 4-bit decoder; nobody publishes numbers for those).
 * Large v3 and Turbo from the Open ASR Leaderboard's German file (checked
 * against it on 08.10.2026: 3.2 and 3.67), medium, small, base and tiny from
 * the Whisper paper (arXiv 2212.04356, Table 13), the only place they are
 * published. None for the German fine-tune (the leaderboard has no row for
 * it) and the English-only model (it writes no German): their tags say what
 * they are.
 */
export const shippedGermanErrors: Record<string, number> = {
  'openai/whisper-large-v3-turbo': 3.67,
  'openai/whisper-large-v3': 3.2,
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
  return language === 'de' ? `${number(rate, 1, language)} % Fehler Deutsch` : `${number(rate, 1, language)} % errors in German`
}

/** A fact on a model's second line, and the help that says where it comes from. */
export interface Fact { text: string; help?: string }

/**
 * The second line of a model's row: size, speed when measured, German errors.
 * A model typed in by hand has none; its speed shows once measured.
 */
export function localFacts(id: string, language: Language, options: { speed?: Speed | null; here?: boolean; errors?: Record<string, number> } = {}): Fact[] {
  const t = (de: string, en: string) => (language === 'de' ? de : en)
  const model = localModel(id)
  const facts: Fact[] = []
  if (model) facts.push({ text: formatSize(model.bytes, language) })
  const speed = options.speed
  if (speed) {
    const date = new Date(speed.date).toLocaleDateString(language === 'de' ? 'de-DE' : 'en-US')
    facts.push({ text: formatSpeed(speed.secondsPer10, language), help: options.here
      ? t('Auf diesem Computer gemessen', 'Measured on this computer')
      : t(`Gemessen am ${date} mit satz ${speed.version} auf ${speed.machine}`, `Measured on ${date} with satz ${speed.version} on ${speed.machine}`) })
  }
  const rate = model && hearsGerman(model) ? germanErrors(options.errors)[model.original] : undefined
  if (rate !== undefined) facts.push({ text: formatGermanErrors(rate, language), help: t('FLEURS, Originalmodell, nicht die geladene Fassung', 'FLEURS, full model, not the downloaded build') })
  return facts
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

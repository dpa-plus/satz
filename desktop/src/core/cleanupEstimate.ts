import type { Language } from './language'
import { characters, conversation, levelFactor, tokens, type CleanupLevel } from './cleanup'
import { catalogModel, cleanupProviders, type CleanupProviderId, type Note } from './cleanupProviders'

/**
 * What cleanup adds to a dictation: seconds, and dollars per hour of talking
 * (like the transcription prices, so the two can be added up). Estimated
 * from the catalog and the user's own dictations until satz has measured it
 * on this computer.
 */

/** Dollars per million tokens. */
export interface Price { input: number; output: number }
export interface Sample { seconds: number; dollars?: number; date: string }

/** About 30 s of talking, for a user with too few dictations to go by. */
export const typicalChars = 400
/** People say about 14 characters a second. */
const charsPerSecond = 14

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/** How long the user's dictations are: the median of the last 50 (as said, before cleanup), once there are 5. */
export function averageChars(history: { text: string; original?: string }[]): number {
  const lengths = history.slice(0, 50).map(entry => characters(entry.original ?? entry.text))
  return lengths.length >= 5 ? median(lengths) : typicalChars
}

/** The characters sent besides the dictation: the system prompt, the examples, and a little for the wrapping. */
export function promptChars(level: CleanupLevel, vocabulary: string[], customPrompt = ''): number {
  const chat = conversation(level, '', vocabulary, customPrompt)
  return characters(chat.system) + chat.turns.slice(0, -1).reduce((sum, turn) => sum + characters(turn.content), 0) + 40
}

export const measurementKey = (provider: CleanupProviderId, model: string) => `${provider}|${model}`

/** The newest last, at most 20 per model: a model that got faster shows it soon. */
export function addSample(samples: Record<string, Sample[]>, key: string, sample: Sample): Record<string, Sample[]> {
  return { ...samples, [key]: [...(samples[key] ?? []), sample].slice(-20) }
}

/** The measured time once there are two runs; one could have loaded the model. */
export function measuredSeconds(samples: Sample[] | undefined): number | undefined {
  return samples && samples.length >= 2 ? median(samples.map(sample => sample.seconds)) : undefined
}

/** What a run cost: OpenRouter says so; elsewhere the tokens at the catalog's price. */
export function runDollars(result: { dollars?: number; inputTokens?: number; outputTokens?: number }, price: Price | undefined): number | undefined {
  if (result.dollars !== undefined) return result.dollars
  if (!price || result.inputTokens === undefined || result.outputTokens === undefined) return undefined
  return (result.inputTokens * price.input + result.outputTokens * price.output) / 1e6
}

interface Facts { name: string; maker: Note; price?: Price; free: boolean; byDeployment: boolean; seconds?: number; tps?: number; tokenFactor: number; note?: Note }

const plainNote = (name: string): Note => ({ de: name, en: name })

/**
 * What satz knows about a model: the catalog, OpenRouter's live price (it
 * wins; a typed id gets its price only from there), an Azure deployment
 * priced like the OpenAI model its name contains. A model typed by hand is
 * made by the Mac's rules (CleanupCatalog.model): its maker is the provider's
 * name ("Microsoft" for Azure, "Eigener" / "Custom" for Custom), and Claude's
 * tokenizer counts more wherever the id is Claude's.
 */
export function modelFacts(provider: CleanupProviderId, model: string, livePrice?: Price): Facts {
  const entry = cleanupProviders[provider]
  const known = catalogModel(provider, model)
  if (known) {
    const price = livePrice ?? (known.input !== undefined && known.output !== undefined ? { input: known.input, output: known.output } : undefined)
    return { name: known.name, maker: plainNote(known.maker), price, free: false, byDeployment: false, seconds: known.seconds, tps: known.tps, tokenFactor: known.tokenFactor ?? 1, note: known.note }
  }
  const unknown = entry.unknownModel ?? {}
  let price = livePrice
  if (provider === 'azure') {
    const like = [...cleanupProviders.openai.models].sort((a, b) => b.id.length - a.id.length).find(candidate => model.toLowerCase().includes(candidate.id))
    if (like) price = { input: like.input!, output: like.output! }
  }
  const maker = model.includes('/') && provider === 'openrouter' ? plainNote(model.split('/')[0]) : provider === 'azure' ? plainNote('Microsoft') : entry.name
  const claude = provider === 'openrouter' && model.startsWith('anthropic/')
  return {
    name: model, maker, price, free: unknown.free === true, byDeployment: provider === 'azure' && !price, seconds: unknown.seconds, tps: unknown.tps,
    tokenFactor: claude ? claudeTokens : entry.anyModel?.tokenFactor ?? 1, note: unknown.note,
  }
}

/** Claude's tokenizer counts about 1.5 times the input and twice the output tokens of the others: 1.7 (the catalog's). */
const claudeTokens = 1.7

export interface Estimate {
  name: string
  maker: Note
  /** Added per dictation; undefined until measured where there is no catalog time. */
  seconds?: number
  measured: boolean
  /** Per hour of talking; 0 for free; undefined where unknown. */
  dollarsPerHour?: number
  /** Costs nothing: on this computer, or priced at 0. */
  free: boolean
  byDeployment: boolean
  /** The length of dictation the estimate is for, in seconds of talking, to 5 s. */
  talkingSeconds: number
  note?: Note
}

export interface EstimateInput {
  provider: CleanupProviderId
  model: string
  level: CleanupLevel
  vocabulary: string[]
  customPrompt?: string
  avgChars: number
  livePrice?: Price
  samples?: Sample[]
}

/** The numbers for the menu and the facts line (the spec's 5.1). */
export function estimate(input: EstimateInput): Estimate {
  const facts = modelFacts(input.provider, input.model, input.livePrice)
  const said = tokens(input.avgChars)
  const outTokens = said * levelFactor(input.level)
  const inTokens = tokens(promptChars(input.level, input.vocabulary, input.customPrompt)) + said
  const perHour = 3600 / (input.avgChars / charsPerSecond)
  const dollarsPerHour = facts.free ? 0 : facts.price ? (inTokens * facts.price.input + outTokens * facts.price.output) / 1e6 * facts.tokenFactor * perHour : undefined
  const measured = measuredSeconds(input.samples)
  const estimated = facts.seconds !== undefined && facts.tps !== undefined
    ? Math.max(facts.seconds * 0.6, facts.seconds + (outTokens * facts.tokenFactor - 80) / facts.tps) : undefined
  return {
    name: facts.name, maker: facts.maker,
    seconds: measured ?? estimated, measured: measured !== undefined,
    dollarsPerHour, free: facts.free || (facts.price !== undefined && facts.price.input === 0 && facts.price.output === 0), byDeployment: facts.byDeployment,
    talkingSeconds: Math.max(5, Math.round(input.avgChars / charsPerSecond / 5) * 5),
    note: facts.note,
  }
}

// MARK: - Words

const number = (value: number, digits: number, language: Language) =>
  value.toLocaleString(language === 'de' ? 'de-DE' : 'en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })

const secondsText = (seconds: number, language: Language) => `+${number(seconds, 1, language)} s`

/** "0,04 $" / "$0.04", and "unter 0,01 $" / "under $0.01" for less. */
function dollars(value: number, language: Language): string {
  if (value < 0.01) return language === 'de' ? 'unter 0,01 $' : 'under $0.01'
  return language === 'de' ? `${number(value, 2, language)} $` : `$${number(value, 2, language)}`
}

/** "Claude Haiku 5.5 · Anthropic · +1,3 s · 0,01 $ pro Stunde". */
export function menuTitle(e: Estimate, language: Language): string {
  const maker = e.maker[language]
  const parts = [e.name === maker ? e.name : `${e.name} · ${maker}`]
  if (e.seconds !== undefined) parts.push(secondsText(e.seconds, language))
  if (e.free) parts.push(language === 'de' ? 'kostenlos' : 'free')
  else if (e.dollarsPerHour !== undefined) parts.push(language === 'de' ? `${dollars(e.dollarsPerHour, language)} pro Stunde` : `${dollars(e.dollarsPerHour, language)} an hour`)
  return parts.join(' · ')
}

/**
 * The line under the model: what a dictation costs in time and money, for
 * dictations as long as the user's, then the catalog's note. The two
 * sentences with a time and a price are the spec's (5.3); the others, where
 * the time or the price is not known, are the Mac's words.
 */
export function factsLine(e: Estimate, language: Language): string {
  const de = language === 'de'
  const hour = !e.free && e.dollarsPerHour !== undefined
    ? (de ? `${dollars(e.dollarsPerHour, language)} pro Stunde Sprechen` : `${dollars(e.dollarsPerHour, language)} per hour of talking`) : undefined
  const forLength = de ? `für Diktate von etwa ${e.talkingSeconds} Sekunden` : `for dictations of about ${e.talkingSeconds} seconds`
  const priceUnknown = e.byDeployment ? (de ? 'Preis je nach Bereitstellung.' : 'Price depends on the deployment.') : (de ? 'Preis unbekannt.' : 'Price unknown.')
  let line: string
  if (e.seconds !== undefined && hour !== undefined) {
    line = e.measured
      ? `${secondsText(e.seconds, language)} ${de ? 'pro Diktat, gemessen auf diesem Computer, und' : 'per dictation, measured on this computer, and'} ${hour}.`
      : `${de ? 'Etwa' : 'About'} ${secondsText(e.seconds, language)} ${de ? 'pro Diktat und' : 'per dictation and'} ${hour}, ${forLength}.`
  } else if (e.seconds !== undefined) {
    const time = e.measured
      ? `${secondsText(e.seconds, language)} ${de ? 'pro Diktat, gemessen auf diesem Computer' : 'per dictation, measured on this computer'}`
      : `${de ? 'Etwa' : 'About'} ${secondsText(e.seconds, language)} ${de ? 'pro Diktat' : 'per dictation'}`
    line = e.free ? `${time}.` : `${time}. ${priceUnknown}`
  } else if (hour !== undefined) {
    // The first letter up, as "Unter 0,01 $ …" begins a sentence.
    line = `${de ? 'Zeit: noch nicht gemessen.' : 'Time: not measured yet.'} ${hour[0].toUpperCase()}${hour.slice(1)}.`
  } else {
    line = de ? 'Zeit: noch nicht gemessen.' : 'Time: not measured yet.'
    if (!e.free) line += ` ${priceUnknown}`
  }
  return e.note ? `${line} ${e.note[language]}` : line
}

/**
 * A single cleanup's cost, a fraction of a cent: "0,0002 $", four decimals
 * (the Mac's smallDollars); from a cent on the two decimals of the menu;
 * "unter 0,0001 $" where four decimals would all be zeros, and "0 $" for what
 * cost nothing.
 */
export function smallDollars(value: number, language: Language): string {
  const money = (amount: string) => (language === 'de' ? `${amount} $` : `$${amount}`)
  if (value >= 0.01) return money(number(value, 2, language))
  if (value <= 0) return money('0')
  // Judged as it will be shown: 0.00005 rounds up to 0,0001, not down to 0,0000.
  if (Math.round(value * 1e4) < 1) return `${language === 'de' ? 'unter' : 'under'} ${money(number(0.0001, 4, language))}`
  return money(number(value, 4, language))
}

/** What a try took and, where known, cost: "0,7 s · 0,0001 $". */
export function tryLine(seconds: number, cost: number | undefined, language: Language): string {
  const time = `${number(seconds, 1, language)} s`
  return cost === undefined ? time : `${time} · ${smallDollars(cost, language)}`
}

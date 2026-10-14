import type { Language } from './language'
import { allowsAddress } from './address'
import { needsMessage, type Need } from './browse'
import type { Provider } from './transcriber'

/**
 * Where cleanup sends the text, and the models each place offers. Apple's
 * on-device model is a provider on the Mac only: Foundation Models exist on
 * macOS 26 and nowhere else, so Windows and Linux have none of it.
 *
 * Only OpenRouter was called with a real key (14.10.2026, ~1,500 calls); the
 * direct providers are written from their documentation and tested against a
 * stand-in server. Every extra body field they get is sent again without it
 * when a 400 names it (cleanupRequest.ts), so a provider that changed its API
 * still works.
 */
export type CleanupProviderId = 'openrouter' | 'openai' | 'anthropic' | 'google' | 'groq' | 'cerebras' | 'mistral' | 'deepseek' | 'xai' | 'azure' | 'ollama' | 'lmstudio' | 'custom'
export type Family = 'openai' | 'anthropic' | 'gemini'

export interface Note { de: string; en: string }

export interface CatalogModel {
  id: string
  name: string
  maker: string
  /** Dollars per million tokens, in and out. */
  input?: number
  output?: number
  /** Seconds a dictation of about 60 words took (Munich, 14.10.2026, ±50 %), and output tokens per second to scale it. */
  seconds?: number
  tps?: number
  /** Claude counts about 1.5 times the input and twice the output tokens of the others for the same text. */
  tokenFactor?: number
  /** Body fields that turn thinking off or down; for Gemini they go into generationConfig. */
  extras?: Record<string, unknown>
  /** Refuses `temperature`. */
  noTemperature?: boolean
  /** OpenRouter: what the reasoning rule gives without the live list (cleanupRequest.ts, openRouterReasoning). */
  reasoning?: Record<string, unknown>
  note?: Note
}

export interface CleanupProvider {
  id: CleanupProviderId
  name: Note
  family: Family
  /** The key file's name; shared with transcription where the provider is the same, so one key serves both. */
  account: string | null
  keyOptional?: boolean
  /** Fixed, a default the user may change, or typed by the user. */
  address: string | null
  addressKind: 'fixed' | 'default' | 'typed'
  /** '' where the user types it (Azure, Custom) or the first installed one is taken (Ollama, LM Studio). */
  defaultModel: string
  models: CatalogModel[]
  keyPlaceholder: Note
  keyPage?: string
  keyNote?: Note
  /** OpenAI and Azure: `max_completion_tokens` instead of `max_tokens`. */
  completionTokens?: boolean
  /** Runs on this computer: free, and the first call loads the model. */
  local?: boolean
  /** Lists what is installed at `{address}/models`. */
  lists?: boolean
  /** Extras for every model, typed or listed (Ollama), whether they refuse `temperature`, and the tokenizer's factor (a typed Claude id counts like Claude). */
  anyModel?: { extras?: Record<string, unknown>; noTemperature?: boolean; tokenFactor?: number }
  /** Price, time and note of a model not in the catalog. */
  unknownModel?: { seconds?: number; tps?: number; free?: boolean; note?: Note }
}

const plain = (name: string): Note => ({ de: name, en: name })
const thinksBriefly: Note = { de: 'Denkt kurz nach.', en: 'Thinks briefly.' }
const bestQuality: Note = { de: 'Beste Qualität.', en: 'Best quality.' }
const fastest: Note = { de: 'Am schnellsten.', en: 'The fastest.' }
const alwaysThinks: Note = { de: 'Denkt immer nach: mehrere Sekunden pro Diktat.', en: 'Always thinks: several seconds per dictation.' }
const googleKey: Note = {
  de: 'Mit einem kostenlosen Schlüssel darf Google den Text zur Verbesserung seiner Produkte nutzen, mit eingeschalteter Abrechnung nicht.',
  en: 'With a free key Google may use the text to improve its products; with billing switched on it may not.',
}
const both = (a: Note, b: Note): Note => ({ de: `${a.de} ${b.de}`, en: `${a.en} ${b.en}` })
const onThisComputer: Note = {
  de: 'Läuft auf diesem Computer, kostenlos. Kleine Modelle beantworten manchmal Fragen im Text; satz fügt dann das Original ein.',
  en: 'Runs on this computer, free. Small models sometimes answer questions in the text; satz then pastes the original.',
}

/**
 * OpenRouter, each maker's current generation only (Eli: "we should provide
 * the latest models"), in the menu's order. All 17 were run through 14 tricky
 * dictations at "Leicht" and "Ausformuliert": none answered, followed or
 * translated. Left out on purpose: older generations a listed model replaces
 * (Gemini 2.5 Flash-Lite, GPT-5.x, Grok 4.3 and older, Mistral Small 3,
 * Qwen3.7, GLM-5.2 and older); qwen/qwen3.8-max-0902 (thinks for 3.5 s and
 * once appended "Wait, I need…"); cohere/command-a-plus (writes its reasoning
 * into the answer); liquid/lfm-2.5-24b-a2b and inception/mercury-2.5 (empty
 * answers, the latter translated); mistralai/ministral-8b-2512 (told the joke,
 * Markdown, "um drei" became "15 Uhr"); nvidia/nemotron-3.5-lightning (told
 * jokes, translated); meta-llama/llama-4-maverick (garbled);
 * openai/gpt-5.4-nano (translated English phrases).
 */
const openRouterModels: CatalogModel[] = [
  { id: 'google/gemini-3.5-flash-lite', name: 'Gemini 3.5 Flash-Lite', maker: 'Google', input: 0.30, output: 2.50, seconds: 0.8, tps: 250, reasoning: { effort: 'minimal' },
    note: { de: 'Schnell. Schreibt bei „Ausformuliert“ wenig um.', en: 'Fast. Rewrites little at “Polished”.' } },
  { id: 'qwen/qwen3.8-27b', name: 'Qwen3.8 27B', maker: 'Qwen', input: 0.04, output: 2.30, seconds: 0.6, tps: 300, reasoning: { enabled: false }, note: fastest },
  { id: 'deepseek/deepseek-v4.1-flash', name: 'DeepSeek V4.1 Flash', maker: 'DeepSeek', input: 0.021, output: 0.891, seconds: 0.8, tps: 190, reasoning: { enabled: false } },
  { id: 'anthropic/claude-haiku-5.5', name: 'Claude Haiku 5.5', maker: 'Anthropic', input: 0.10, output: 0.50, seconds: 1.6, tps: 165, tokenFactor: 1.7, reasoning: { enabled: false },
    note: { de: 'Schreibt am besten um, gut für „Glatt“ und „Ausformuliert“.', en: 'Rewrites best, good for “Smooth” and “Polished”.' } },
  { id: 'openai/gpt-6-luna', name: 'GPT-6 Luna', maker: 'OpenAI', input: 0.10, output: 0.50, seconds: 1.5, tps: 112, reasoning: { effort: 'none' } },
  { id: 'z-ai/glm-5.3', name: 'GLM-5.3', maker: 'Z.ai', input: 0.079, output: 4.80, seconds: 0.9, tps: 100, reasoning: { effort: 'low' } },
  { id: 'minimax/minimax-m3', name: 'MiniMax M3', maker: 'MiniMax', input: 0.30, output: 1.20, seconds: 1.4, tps: 100, reasoning: { enabled: false } },
  { id: 'mistralai/mistral-large-4-0', name: 'Mistral Large 4', maker: 'Mistral', input: 0.68, output: 2.09, seconds: 1.7, tps: 100, reasoning: { effort: 'none' } },
  { id: 'google/gemini-3.8-flash', name: 'Gemini 3.8 Flash', maker: 'Google', input: 0.75, output: 3.75, seconds: 1.4, tps: 145, reasoning: { effort: 'low' } },
  { id: 'moonshotai/kimi-k3', name: 'Kimi K3', maker: 'Moonshot AI', input: 0.62, output: 15.00, seconds: 1.4, tps: 100, reasoning: { enabled: false } },
  { id: 'deepseek/deepseek-v4-pro-0813', name: 'DeepSeek V4 Pro', maker: 'DeepSeek', input: 1.32, output: 3.96, seconds: 1.2, tps: 100, reasoning: { enabled: false } },
  { id: 'anthropic/claude-sonnet-5.5', name: 'Claude Sonnet 5.5', maker: 'Anthropic', input: 2.00, output: 10.00, seconds: 1.4, tps: 100, tokenFactor: 1.7, reasoning: { effort: 'low' }, note: bestQuality },
  { id: 'openai/gpt-6-sol', name: 'GPT-6 Sol', maker: 'OpenAI', input: 2.00, output: 10.00, seconds: 1.4, tps: 100, reasoning: { effort: 'none' } },
  { id: 'openai/gpt-6.1-sol', name: 'GPT-6.1 Sol', maker: 'OpenAI', input: 2.00, output: 10.00, seconds: 2.1, tps: 50, reasoning: { effort: 'low' }, note: thinksBriefly },
  { id: 'google/gemini-4-argon', name: 'Gemini 4 Argon', maker: 'Google', input: 2.00, output: 10.00, seconds: 2.3, tps: 100, reasoning: { effort: 'low' }, note: thinksBriefly },
  { id: 'anthropic/claude-opus-5.5', name: 'Claude Opus 5.5', maker: 'Anthropic', input: 4.00, output: 20.00, seconds: 2.7, tps: 80, tokenFactor: 1.7, reasoning: { effort: 'low' }, note: thinksBriefly },
  { id: 'x-ai/grok-4.7', name: 'Grok 4.7', maker: 'xAI', input: 2.00, output: 6.00, seconds: 4.6, tps: 65, reasoning: { effort: 'low' }, note: alwaysThinks },
]

const openAIExtras = { extras: { reasoning_effort: 'none' }, noTemperature: true }
const sonnetExtras = { extras: { output_config: { effort: 'low' } }, noTemperature: true }
const gptOss = { reasoning_effort: 'low', include_reasoning: false }
const mistralExtras = { extras: { reasoning_effort: 'none' } }
const deepseekExtras = { extras: { thinking: { type: 'disabled' } } }

export const cleanupProviders: Record<CleanupProviderId, CleanupProvider> = {
  openrouter: { id: 'openrouter', name: plain('OpenRouter'), family: 'openai', account: 'openrouter', address: 'https://openrouter.ai/api/v1', addressKind: 'fixed',
    defaultModel: 'google/gemini-3.5-flash-lite', models: openRouterModels, keyPlaceholder: plain('sk-or-…'), keyPage: 'https://openrouter.ai/settings/keys' },
  openai: { id: 'openai', name: plain('OpenAI'), family: 'openai', account: 'openai', address: 'https://api.openai.com/v1', addressKind: 'fixed', defaultModel: 'gpt-6-luna',
    completionTokens: true, keyPlaceholder: plain('sk-…'), keyPage: 'https://platform.openai.com/api-keys', models: [
      { id: 'gpt-6-luna', name: 'GPT-6 Luna', maker: 'OpenAI', input: 0.10, output: 0.50, seconds: 1.5, tps: 112, ...openAIExtras },
      { id: 'gpt-6-sol', name: 'GPT-6 Sol', maker: 'OpenAI', input: 2.00, output: 10.00, seconds: 1.4, tps: 100, ...openAIExtras },
      // It cannot stop thinking.
      { id: 'gpt-6.1-sol', name: 'GPT-6.1 Sol', maker: 'OpenAI', input: 2.00, output: 10.00, seconds: 2.1, tps: 50, extras: { reasoning_effort: 'low' }, noTemperature: true, note: thinksBriefly },
    ] },
  // Claude 5.5 refuses sampling parameters, so the family sends none; a typed id gets Haiku's extras.
  anthropic: { id: 'anthropic', name: plain('Anthropic'), family: 'anthropic', account: 'anthropic', address: 'https://api.anthropic.com/v1', addressKind: 'fixed',
    defaultModel: 'claude-haiku-5-5', keyPlaceholder: plain('sk-ant-…'), keyPage: 'https://console.anthropic.com/settings/keys',
    anyModel: { extras: { thinking: { type: 'disabled' } }, noTemperature: true, tokenFactor: 1.7 }, models: [
      { id: 'claude-haiku-5-5', name: 'Claude Haiku 5.5', maker: 'Anthropic', input: 0.10, output: 0.50, seconds: 1.6, tps: 165, tokenFactor: 1.7, extras: { thinking: { type: 'disabled' } }, noTemperature: true },
      // Their thinking cannot be switched off, only down.
      { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', maker: 'Anthropic', input: 2.00, output: 10.00, seconds: 1.4, tps: 100, tokenFactor: 1.7, ...sonnetExtras, note: bestQuality },
      { id: 'claude-opus-5-5', name: 'Claude Opus 5.5', maker: 'Anthropic', input: 4.00, output: 20.00, seconds: 2.7, tps: 80, tokenFactor: 1.7, ...sonnetExtras },
    ] },
  google: { id: 'google', name: plain('Google'), family: 'gemini', account: 'google', address: 'https://generativelanguage.googleapis.com/v1beta', addressKind: 'fixed',
    defaultModel: 'gemini-3.5-flash-lite', keyPlaceholder: plain('AIza…'), keyPage: 'https://aistudio.google.com/apikey', unknownModel: { note: googleKey }, models: [
      { id: 'gemini-3.5-flash-lite', name: 'Gemini 3.5 Flash-Lite', maker: 'Google', input: 0.30, output: 2.50, seconds: 0.8, tps: 250, extras: { thinkingConfig: { thinkingLevel: 'minimal' } }, note: googleKey },
      { id: 'gemini-3.8-flash', name: 'Gemini 3.8 Flash', maker: 'Google', input: 0.75, output: 3.75, seconds: 1.4, tps: 145, extras: { thinkingConfig: { thinkingLevel: 'low' } },
        note: both({ de: 'Ab 2027 doppelt so teuer.', en: 'Twice the price from 2027.' }, googleKey) },
      { id: 'gemini-4-argon', name: 'Gemini 4 Argon', maker: 'Google', input: 2.00, output: 10.00, seconds: 2.3, tps: 100, extras: { thinkingConfig: { thinkingLevel: 'low' } }, note: both(thinksBriefly, googleKey) },
    ] },
  groq: { id: 'groq', name: plain('Groq'), family: 'openai', account: 'groq', address: 'https://api.groq.com/openai/v1', addressKind: 'fixed', defaultModel: 'openai/gpt-oss-120b',
    keyPlaceholder: plain('gsk_…'), keyPage: 'https://console.groq.com/keys', models: [
      { id: 'openai/gpt-oss-120b', name: 'gpt-oss-120b', maker: 'OpenAI', input: 0.15, output: 0.60, seconds: 0.7, tps: 470, extras: gptOss, note: thinksBriefly },
      { id: 'qwen/qwen3.8-27b', name: 'Qwen3.8 27B', maker: 'Qwen', input: 0.80, output: 4.00, seconds: 0.6, tps: 450, extras: { reasoning_effort: 'none' }, note: { de: 'Vorschau bei Groq.', en: 'Preview at Groq.' } },
      { id: 'openai/gpt-oss-20b', name: 'gpt-oss-20b', maker: 'OpenAI', input: 0.075, output: 0.30, seconds: 0.6, tps: 950, extras: gptOss },
    ] },
  cerebras: { id: 'cerebras', name: plain('Cerebras'), family: 'openai', account: 'cerebras', address: 'https://api.cerebras.ai/v1', addressKind: 'fixed', defaultModel: 'qwen-3.8-27b',
    keyPlaceholder: plain('csk-…'), keyPage: 'https://cloud.cerebras.ai/', models: [
      { id: 'qwen-3.8-27b', name: 'Qwen3.8 27B', maker: 'Qwen', input: 0.99, output: 1.49, seconds: 0.5, tps: 1800, extras: { reasoning_effort: 'none' }, note: fastest },
      { id: 'gpt-oss-120b', name: 'gpt-oss-120b', maker: 'OpenAI', input: 0.35, output: 0.75, seconds: 0.5, tps: 1500, extras: { reasoning_effort: 'low', reasoning_format: 'hidden' } },
    ] },
  // "-latest" is Mistral's own alias for its newest model.
  mistral: { id: 'mistral', name: plain('Mistral'), family: 'openai', account: 'mistral', address: 'https://api.mistral.ai/v1', addressKind: 'fixed', defaultModel: 'mistral-small-latest',
    keyPlaceholder: { de: 'API-Schlüssel', en: 'API key' }, keyPage: 'https://console.mistral.ai/api-keys', models: [
      { id: 'mistral-small-latest', name: 'Mistral Small', maker: 'Mistral', input: 0.15, output: 0.60, seconds: 0.9, tps: 146, ...mistralExtras },
      { id: 'mistral-large-latest', name: 'Mistral Large', maker: 'Mistral', input: 0.68, output: 2.09, seconds: 1.7, tps: 100, ...mistralExtras },
      { id: 'mistral-medium-latest', name: 'Mistral Medium', maker: 'Mistral', input: 1.50, output: 7.50, seconds: 2.2, tps: 166, ...mistralExtras },
    ] },
  // DeepSeek's path is /chat/completions without /v1; it refuses reasoning_effort "none".
  deepseek: { id: 'deepseek', name: plain('DeepSeek'), family: 'openai', account: 'deepseek', address: 'https://api.deepseek.com', addressKind: 'fixed', defaultModel: 'deepseek-flash',
    keyPlaceholder: plain('sk-…'), keyPage: 'https://platform.deepseek.com/api_keys', models: [
      { id: 'deepseek-flash', name: 'DeepSeek V4.1 Flash', maker: 'DeepSeek', input: 0.30, output: 1.20, seconds: 1.1, tps: 190, ...deepseekExtras, note: { de: 'Nachts (UTC) halb so teuer.', en: 'Half price at night (UTC).' } },
      { id: 'deepseek-v4-pro-0813', name: 'DeepSeek V4 Pro', maker: 'DeepSeek', input: 1.32, output: 3.96, seconds: 1.5, tps: 100, ...deepseekExtras },
    ] },
  xai: { id: 'xai', name: plain('xAI'), family: 'openai', account: 'xai', address: 'https://api.x.ai/v1', addressKind: 'fixed', defaultModel: 'grok-4.7',
    keyPlaceholder: plain('xai-…'), keyPage: 'https://console.x.ai/', models: [
      { id: 'grok-4.7', name: 'Grok 4.7', maker: 'xAI', input: 2.00, output: 6.00, seconds: 4.6, tps: 65, extras: { reasoning_effort: 'low' }, note: alwaysThinks },
    ] },
  // The deployment is typed; its price is that of the OpenAI model its name contains (cleanupEstimate.ts).
  azure: { id: 'azure', name: plain('Microsoft Azure'), family: 'openai', account: 'azure-openai', address: null, addressKind: 'typed', defaultModel: '', completionTokens: true,
    keyPlaceholder: { de: 'API-Schlüssel', en: 'API key' },
    keyNote: { de: 'Ein Schlüssel einer Azure-OpenAI- oder Foundry-Ressource, nicht der Speech-Schlüssel.', en: 'A key of an Azure OpenAI or Foundry resource, not the Speech key.' },
    anyModel: { noTemperature: true }, unknownModel: { seconds: 1.5, tps: 100 }, models: [] },
  ollama: { id: 'ollama', name: plain('Ollama'), family: 'openai', account: null, address: 'http://localhost:11434/v1', addressKind: 'default', defaultModel: '', local: true, lists: true,
    keyPlaceholder: plain(''), anyModel: { extras: { reasoning_effort: 'none' } }, unknownModel: { free: true, note: onThisComputer }, models: [] },
  lmstudio: { id: 'lmstudio', name: plain('LM Studio'), family: 'openai', account: null, address: 'http://localhost:1234/v1', addressKind: 'default', defaultModel: '', local: true, lists: true,
    keyPlaceholder: plain(''), unknownModel: { free: true, note: onThisComputer }, models: [] },
  custom: { id: 'custom', name: { de: 'Eigener', en: 'Custom' }, family: 'openai', account: 'custom-cleanup', keyOptional: true, address: null, addressKind: 'typed', defaultModel: '',
    keyPlaceholder: { de: 'API-Schlüssel (optional)', en: 'API key (optional)' }, models: [] },
}

/** The menu's order (the Mac puts Apple first). */
export const cleanupProviderOrder: CleanupProviderId[] = ['openrouter', 'openai', 'anthropic', 'google', 'groq', 'cerebras', 'mistral', 'deepseek', 'xai', 'azure', 'ollama', 'lmstudio', 'custom']

export const isCleanupProvider = (value: unknown): value is CleanupProviderId => typeof value === 'string' && Object.hasOwn(cleanupProviders, value)

/** Every key file cleanup may read or write: the table's, never a name a page sends. */
export const cleanupAccounts = [...new Set(cleanupProviderOrder.map(id => cleanupProviders[id].account).filter((account): account is string => account !== null))]

/**
 * Until the user picks one: the transcription provider where it can clean
 * up too (its key is already there), else OpenRouter.
 */
export function defaultCleanupProvider(transcription: Provider): CleanupProviderId {
  return transcription === 'openrouter' || transcription === 'openai' || transcription === 'google' || transcription === 'groq' ? transcription : 'openrouter'
}

export const catalogModel = (provider: CleanupProviderId, model: string) => cleanupProviders[provider].models.find(entry => entry.id === model)

/** The seconds a dictation took when measured: the catalog's, or what is known of a model typed for the provider (an Azure deployment). */
export const modelSeconds = (provider: CleanupProviderId, model: string): number | undefined =>
  catalogModel(provider, model)?.seconds ?? cleanupProviders[provider].unknownModel?.seconds

const here = (hostname: string) => ['localhost', '127.0.0.1', '[::1]'].includes(hostname)

/**
 * An address a key may travel to: https, or http on this computer or the
 * own network (an Ollama on the NAS), the rule transcription addresses
 * follow too (core/address.ts). Pasted without a scheme it is taken as
 * https. Without a trailing slash; null for one that is none.
 */
export function usableAddress(raw: string | undefined): string | null {
  const typed = raw?.trim()
  if (!typed) return null
  let url: URL
  try { url = new URL(typed.includes('://') ? typed : `https://${typed}`) } catch { return null }
  if (!url.host || !allowsAddress(url)) return null
  return `${url.origin}${url.pathname}`.replace(/\/+$/, '')
}

export const isOnThisComputer = (address: string) => { try { return here(new URL(address).hostname) } catch { return false } }

/**
 * Where requests go: the fixed address, Ollama's and LM Studio's default
 * unless the user typed another, Azure's resource (its origin, then
 * /openai/v1), or Custom's. Null while there is none to use.
 */
export function cleanupBase(provider: CleanupProviderId, typed: string | undefined): string | null {
  const entry = cleanupProviders[provider]
  if (entry.addressKind === 'fixed') return entry.address
  if (entry.addressKind === 'default') return usableAddress(typed?.trim() || entry.address!)
  const address = usableAddress(typed)
  if (!address) return null
  return provider === 'azure' ? `${new URL(address).origin}/openai/v1` : address
}

/** The model dictations go to: the one chosen, the default, or (Ollama, LM Studio) the first installed. */
export function chosenModel(provider: CleanupProviderId, chosen: string | undefined, installed: string[] = []): string {
  return chosen?.trim() || cleanupProviders[provider].defaultModel || installed[0] || ''
}

/**
 * What a cleanup provider still lacks, in the order it is filled in: a key
 * (Custom's is optional), an address, a model (Azure's deployment, Custom's,
 * or for Ollama and LM Studio one installed). The same words as the switch
 * row then name it (browse.ts, needsMessage).
 */
export function cleanupNeeds(provider: CleanupProviderId, facts: { hasKey: boolean; address?: string; model?: string; installed?: string[] }): Need[] {
  const entry = cleanupProviders[provider]
  const needs: Need[] = []
  if (entry.account && !entry.keyOptional && !facts.hasKey) needs.push('key')
  if (cleanupBase(provider, facts.address) === null) needs.push('address')
  if (!chosenModel(provider, facts.model, facts.installed)) needs.push('model')
  return needs
}

/** The row under the toggle while cleanup is on and cannot work: what is missing, as the switch row says it. */
export function cleanupMissing(needs: Need[], promptMissing: boolean, language: Language): string | null {
  const missing = needsMessage(needs, language)
  if (missing) return missing
  // The Mac's words; the full stop is the one every message here ends with (needsMessage).
  return promptMissing ? (language === 'de' ? 'Erst den Prompt eintragen.' : 'Enter the prompt first.') : null
}

/** An option of the menu; the provider in use says so wherever the menu stands (the Mac's menu items read the same). */
export function cleanupProviderLabel(provider: CleanupProviderId, inUse: CleanupProviderId, language: Language): string {
  const name = cleanupProviders[provider].name[language]
  return provider === inUse ? `${name} · ${language === 'de' ? 'in Benutzung' : 'in use'}` : name
}

/**
 * While the menu shows a provider cleanup does not go to: where it goes, and
 * the one button that switches, offered once the shown one has what it needs.
 * Looking is not switching (browse.ts).
 */
export function cleanupSwitchRow(shown: CleanupProviderId, inUse: CleanupProviderId, language: Language, needs: Need[] = []): { text: string; button: string | null } | null {
  if (shown === inUse) return null
  const name = cleanupProviders[inUse].name
  const where = inUse === 'custom' ? (language === 'de' ? `„${name.de}“` : `“${name.en}”`) : name[language]
  const goesTo = language === 'de' ? `Aufräumen geht an ${where}.` : `Cleanup goes to ${where}.`
  const missing = needsMessage(needs, language)
  if (missing) return { text: `${goesTo} ${missing}`, button: null }
  return { text: goesTo, button: language === 'de' ? `${shown === 'custom' ? 'Eigenen' : cleanupProviders[shown].name.de} benutzen` : `Use ${cleanupProviders[shown].name.en}` }
}

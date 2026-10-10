import { localModels } from './localModels'
import { providers, type Provider } from './transcriber'

/**
 * Which transcription models a provider has now, and what satz knows about
 * each: the price per hour of speech and how many words it gets wrong. The
 * list comes from the provider (OpenRouter without a key, OpenAI and Groq with
 * one), so new models show up without a new satz. Ported from ModelChoice.swift,
 * where the testing behind the table (07.10.2026) is written down.
 */
export interface ModelChoice {
  id: string
  name: string
  maker: string
  /** Dollars per hour of speech: measured where possible, else from the listing. */
  dollarsPerHour?: number
  /** Artificial Analysis' word error rate in percent (AA-WER), lower is better. */
  errorRate?: number
}

interface Known { name?: string; maker?: string; measured?: number; errorRate?: number; hidden?: string }

export const known: Record<string, Known> = {
  'microsoft/mai-transcribe-2': { name: 'MAI-Transcribe 2', maker: 'Microsoft', measured: 0.10, errorRate: 2.0 },
  'microsoft/mai-transcribe-1.5': { name: 'MAI-Transcribe 1.5', maker: 'Microsoft', measured: 0.36, errorRate: 2.4 },
  'openai/gpt-transcribe': { name: 'GPT Transcribe', maker: 'OpenAI', measured: 0.28, errorRate: 3.3 },
  'openai/gpt-4o-transcribe': { name: 'GPT-4o Transcribe', maker: 'OpenAI', measured: 0.23, errorRate: 4.0 },
  'openai/gpt-4o-mini-transcribe': { name: 'GPT-4o mini Transcribe', maker: 'OpenAI', measured: 0.12, errorRate: 4.5 },
  'openai/whisper-1': { name: 'Whisper', maker: 'OpenAI', measured: 0.37, errorRate: 4.1 },
  'openai/whisper-large-v3': { name: 'Whisper Large v3', maker: 'OpenAI', measured: 0.03 },
  'openai/whisper-large-v3-turbo': { name: 'Whisper Large v3 Turbo', maker: 'OpenAI', measured: 0.01, errorRate: 4.6 },
  'assemblyai/universal-3-5-pro': { name: 'Universal-3.5 Pro', maker: 'AssemblyAI', measured: 0.44 },
  'mistralai/voxtral-mini-transcribe': { name: 'Voxtral Mini Transcribe', maker: 'Mistral', measured: 0.15 },
  'mistralai/voxtral-small-24b-2507-stt': { name: 'Voxtral Small', maker: 'Mistral', measured: 0.18, errorRate: 2.8 },
  'mistralai/voxtral-mini-3b-2507': { name: 'Voxtral Mini 3B', maker: 'Mistral', measured: 0.06, errorRate: 3.8 },
  'qwen/qwen3-asr-flash-2026-02-10': { name: 'Qwen3 ASR Flash', maker: 'Qwen', measured: 0.11 },
  'qwen/qwen3-asr-1.7b': { name: 'Qwen3 ASR 1.7B', maker: 'Qwen', measured: 0.03 },
  'qwen/qwen3-asr-0.6b': { name: 'Qwen3 ASR 0.6B', maker: 'Qwen', measured: 0.01 },
  'x-ai/grok-stt-1.0': { name: 'Grok STT', maker: 'xAI', measured: 0.10, errorRate: 4.0 },
  'google/chirp-3': { name: 'Chirp 3', maker: 'Google', measured: 1.00, errorRate: 4.3 },
  'fish-audio/transcribe-1': { name: 'Transcribe 1', maker: 'Fish Audio', measured: 0.37 },
  'google/gemini-3.5-transcribe': { hidden: 'the provider refuses the request, even with nothing but the audio' },
  'meta/muse-voice-transcribe-1.0': { hidden: 'needs an age check on the OpenRouter account' },
  'deepgram/nova-3': { hidden: 'returns no text for German' },
  'fish-audio/transcribe-1-pro': { hidden: 'puts speaker tags into the text' },
  'nvidia/parakeet-tdt-0.6b-v3': { hidden: 'split German compounds wrongly in the test' },
  'nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b': { hidden: 'split German compounds wrongly in the test' },
  'gpt-transcribe': { name: 'GPT Transcribe', maker: 'OpenAI', errorRate: 3.3 },
  'gpt-4o-transcribe': { name: 'GPT-4o Transcribe', maker: 'OpenAI', errorRate: 4.0 },
  'gpt-4o-mini-transcribe': { name: 'GPT-4o mini Transcribe', maker: 'OpenAI', errorRate: 4.5 },
  'whisper-1': { name: 'Whisper', maker: 'OpenAI', errorRate: 4.1 },
  'whisper-large-v3-turbo': { name: 'Whisper Large v3 Turbo', maker: 'OpenAI', errorRate: 4.6 },
  'whisper-large-v3': { name: 'Whisper Large v3', maker: 'OpenAI' },
  // On this computer: free, and AA measured none of these builds (localModels.ts has what is known).
  ...Object.fromEntries(localModels.map(model => [model.id, { name: model.name, maker: model.maker, measured: 0 }])),
}

const shipped: Record<Provider, string[]> = {
  openrouter: [
    'microsoft/mai-transcribe-2', 'microsoft/mai-transcribe-1.5', 'openai/gpt-transcribe', 'openai/gpt-4o-transcribe',
    'openai/gpt-4o-mini-transcribe', 'openai/whisper-1', 'openai/whisper-large-v3', 'openai/whisper-large-v3-turbo',
    'assemblyai/universal-3-5-pro', 'mistralai/voxtral-mini-transcribe', 'mistralai/voxtral-small-24b-2507-stt',
    'mistralai/voxtral-mini-3b-2507', 'qwen/qwen3-asr-flash-2026-02-10', 'qwen/qwen3-asr-1.7b', 'qwen/qwen3-asr-0.6b',
    'x-ai/grok-stt-1.0', 'google/chirp-3', 'fish-audio/transcribe-1',
  ],
  openai: ['gpt-transcribe', 'gpt-4o-transcribe', 'gpt-4o-mini-transcribe', 'whisper-1'],
  groq: ['whisper-large-v3-turbo', 'whisper-large-v3'],
  custom: [],
  local: localModels.map(model => model.id),
}

/** The list satz ships with: before the provider's list arrives, and whenever it cannot. */
export const models: Record<Provider, ModelChoice[]> = Object.fromEntries(
  (Object.keys(shipped) as Provider[]).map(provider => [provider, sorted(shipped[provider].map(id => describe(id, provider)), providers[provider].defaultModel)]),
) as Record<Provider, ModelChoice[]>

/** Where each provider lists its models. OpenRouter's list is public. */
export const listURL: Record<Provider, string | null> = {
  openrouter: 'https://openrouter.ai/api/v1/models?output_modalities=transcription',
  openai: 'https://api.openai.com/v1/models',
  groq: 'https://api.groq.com/openai/v1/models',
  custom: null,
  local: null,
}

/** `{data: [{id, name?, pricing?}]}`: OpenRouter's shape, and OpenAI's and Groq's, which list every model they have. */
export function parse(json: unknown, provider: Provider): ModelChoice[] {
  const data = (json as { data?: { id: string; name?: string; pricing?: Record<string, string> }[] })?.data ?? []
  const list = data.filter(model => {
    if (provider !== 'openrouter') {
      const id = model.id.toLowerCase()
      // Their lists hold every model; these transcribe, and need no other endpoint.
      if (!id.includes('transcribe') && !id.includes('whisper')) return false
      if (id.includes('realtime') || id.includes('diarize')) return false
    }
    return !known[model.id]?.hidden
  }).map(model => describe(model.id, provider, model.name, model.pricing))
  return sorted(list, providers[provider].defaultModel)
}

export function describe(id: string, provider: Provider, listedName?: string, pricing?: Record<string, string>): ModelChoice {
  const entry = known[id]
  // OpenRouter names its models "Maker: Name".
  const parts = listedName?.split(': ')
  // An id without a slash ("gpt-5-transcribe" at OpenAI or Groq) names no maker: the provider is the one.
  const maker = entry?.maker ?? (parts && parts.length > 1 ? parts[0] : undefined) ?? (id.includes('/') ? id.split('/')[0] : providers[provider].name())
  const name = entry?.name ?? parts?.[parts.length - 1] ?? id
  return { id, name, maker, dollarsPerHour: entry?.measured ?? listedPrice(pricing), errorRate: entry?.errorRate }
}

/**
 * OpenRouter's list gives a price without a unit. For speech models priced on
 * the audio alone it is per hour when 0.01 or more and per second below that,
 * which matches every model satz measured. A price per token (a completion
 * price is listed too) cannot become a price per hour here.
 */
export function listedPrice(pricing?: Record<string, string>): number | undefined {
  const prompt = Number(pricing?.prompt)
  if (!pricing || !(prompt > 0) || Number(pricing.completion) > 0) return undefined
  return prompt >= 0.01 ? prompt : prompt * 3600
}

/** The default first, then the fewest errors, then the cheapest; unscored after scored. */
export function sorted(list: ModelChoice[], defaultId: string): ModelChoice[] {
  return [...list].sort((a, b) => {
    if ((a.id === defaultId) !== (b.id === defaultId)) return a.id === defaultId ? -1 : 1
    if (a.errorRate !== undefined && b.errorRate !== undefined && a.errorRate !== b.errorRate) return a.errorRate - b.errorRate
    if ((a.errorRate === undefined) !== (b.errorRate === undefined)) return a.errorRate === undefined ? 1 : -1
    return (a.dollarsPerHour ?? Infinity) - (b.dollarsPerHour ?? Infinity) || a.name.localeCompare(b.name)
  })
}

/** The menu's entry for a model id in a list, undefined for one typed in by hand. */
export const choiceFor = (list: ModelChoice[], id: string) => list.find(model => model.id === id)

import type { Provider } from './transcriber'

/**
 * The models in the settings' menu, the default first. Anything else can still
 * be typed in under "Other". Ported from ModelChoice.swift, where the testing
 * behind the OpenRouter list (07.10.2026) and what was left out are written
 * down; `dollarsPerHour` is what OpenRouter billed then.
 */
export interface ModelChoice { id: string; name: string; maker: string; dollarsPerHour?: number }

const m = (id: string, name: string, maker: string, dollarsPerHour?: number): ModelChoice => ({ id, name, maker, dollarsPerHour })

export const models: Record<Provider, ModelChoice[]> = {
  openrouter: [
    m('microsoft/mai-transcribe-2', 'MAI-Transcribe 2', 'Microsoft', 0.10),
    m('openai/gpt-transcribe', 'GPT Transcribe', 'OpenAI', 0.28),
    m('openai/gpt-4o-transcribe', 'GPT-4o Transcribe', 'OpenAI', 0.23),
    m('openai/gpt-4o-mini-transcribe', 'GPT-4o mini Transcribe', 'OpenAI', 0.12),
    m('openai/whisper-1', 'Whisper', 'OpenAI', 0.37),
    m('openai/whisper-large-v3', 'Whisper Large v3', 'OpenAI', 0.03),
    m('openai/whisper-large-v3-turbo', 'Whisper Large v3 Turbo', 'OpenAI', 0.01),
    m('assemblyai/universal-3-5-pro', 'Universal-3.5 Pro', 'AssemblyAI', 0.44),
    m('mistralai/voxtral-mini-transcribe', 'Voxtral Mini Transcribe', 'Mistral', 0.15),
    m('mistralai/voxtral-small-24b-2507-stt', 'Voxtral Small', 'Mistral', 0.18),
    m('mistralai/voxtral-mini-3b-2507', 'Voxtral Mini 3B', 'Mistral', 0.06),
    m('qwen/qwen3-asr-flash-2026-02-10', 'Qwen3 ASR Flash', 'Qwen', 0.11),
    m('qwen/qwen3-asr-1.7b', 'Qwen3 ASR 1.7B', 'Qwen', 0.03),
    m('qwen/qwen3-asr-0.6b', 'Qwen3 ASR 0.6B', 'Qwen', 0.01),
    m('x-ai/grok-stt-1.0', 'Grok STT', 'xAI', 0.10),
    m('google/chirp-3', 'Chirp 3', 'Google', 1.00),
    m('fish-audio/transcribe-1', 'Transcribe 1', 'Fish Audio', 0.37),
  ],
  openai: [
    m('gpt-transcribe', 'GPT Transcribe', 'OpenAI'),
    m('gpt-4o-transcribe', 'GPT-4o Transcribe', 'OpenAI'),
    m('gpt-4o-mini-transcribe', 'GPT-4o mini Transcribe', 'OpenAI'),
    m('whisper-1', 'Whisper', 'OpenAI'),
  ],
  groq: [
    m('whisper-large-v3-turbo', 'Whisper Large v3 Turbo', 'OpenAI'),
    m('whisper-large-v3', 'Whisper Large v3', 'OpenAI'),
  ],
  custom: [],
}

/** The menu's entry for a model id, undefined for one typed in by hand. */
export const choiceFor = (provider: Provider, id: string) => models[provider].find(model => model.id === id)

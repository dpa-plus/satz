import { de } from './language'

/**
 * Where the audio goes to become text. OpenAI, Groq and Custom take
 * `POST {base}/audio/transcriptions` as multipart in OpenAI's format, and
 * OpenRouter the same address with JSON. Microsoft (Azure AI Speech) and
 * Google (the Gemini API) have requests of their own, built below. 'local' is
 * the exception: Whisper runs on this computer and nothing is sent anywhere.
 * Ported from Provider.swift and Transcriber.swift.
 */
export type Provider = 'openai' | 'openrouter' | 'groq' | 'microsoft' | 'google' | 'custom' | 'local'

export const providers: Record<Provider, { name: () => string; baseURL: string | null; defaultModel: string; keyPlaceholder: () => string }> = {
  openai: { name: () => 'OpenAI', baseURL: 'https://api.openai.com/v1', defaultModel: 'gpt-transcribe', keyPlaceholder: () => 'sk-…' },
  // 2.0% word errors on Artificial Analysis in Sept. 2026 against 3.3% for GPT
  // Transcribe, at a third of the price, and it has a clean mode.
  openrouter: { name: () => 'OpenRouter', baseURL: 'https://openrouter.ai/api/v1', defaultModel: 'microsoft/mai-transcribe-2', keyPlaceholder: () => 'sk-or-…' },
  groq: { name: () => 'Groq', baseURL: 'https://api.groq.com/openai/v1', defaultModel: 'whisper-large-v3-turbo', keyPlaceholder: () => 'gsk_…' },
  // MAI-Transcribe 2 straight from Microsoft: no OpenRouter in between. The
  // host depends on the region of the user's Speech resource (microsoftHost).
  microsoft: { name: () => 'Microsoft', baseURL: null, defaultModel: 'mai-transcribe-2', keyPlaceholder: () => de('Schlüssel 1 oder 2', 'Key 1 or 2') },
  google: { name: () => 'Google', baseURL: 'https://generativelanguage.googleapis.com/v1beta', defaultModel: 'gemini-3.5-transcribe', keyPlaceholder: () => 'AIza…' },
  custom: { name: () => de('Eigener', 'Custom'), baseURL: null, defaultModel: '', keyPlaceholder: () => de('API-Schlüssel', 'API key') },
  local: { name: () => de('Lokal', 'Local'), baseURL: null, defaultModel: 'onnx-community/whisper-large-v3-turbo', keyPlaceholder: () => '' },
}

/** Every provider but the one on this computer wants a key. */
export const needsKey = (provider: Provider) => provider !== 'local'

/** Where a key comes from, for the providers whose key is not obvious to find. Opened by main.ts from this table only. */
export const keyPages: Partial<Record<Provider, string>> = {
  microsoft: 'https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices',
  google: 'https://aistudio.google.com/apikey',
}

/**
 * The regions of Azure AI Speech that run MAI-Transcribe 2 (Microsoft's
 * list, 10.10.2026). A key only works in the region of its own resource.
 * North Europe first: the default, and the one in the EU.
 */
export const microsoftRegions = [
  { id: 'northeurope', name: 'North Europe (EU)' },
  { id: 'eastus', name: 'East US' },
  { id: 'westus', name: 'West US' },
  { id: 'westus2', name: 'West US 2' },
  { id: 'centralindia', name: 'Central India' },
  { id: 'southeastasia', name: 'Southeast Asia' },
]
export const defaultMicrosoftRegion = microsoftRegions[0].id

/**
 * Where Microsoft's requests go: the resource's own address when the user
 * gave one (it wins over the region), else the regional host. Only https, or
 * http to this computer (a stand-in server in a test): the key travels with
 * it. Only the origin is kept, so a pasted address with a path still works.
 * Null for an address that is none, or a region that cannot be one.
 */
export function microsoftHost(region?: string, endpoint?: string): string | null {
  const own = endpoint?.trim()
  if (own) {
    let url: URL
    try { url = new URL(own.includes('://') ? own : `https://${own}`) } catch { return null }
    const here = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && here)) return null
    return url.origin
  }
  const id = (region?.trim() || defaultMicrosoftRegion).toLowerCase()
  return /^[a-z0-9]+$/.test(id) ? `https://${id}.api.cognitive.microsoft.com` : null
}

/**
 * Whether a model has a clean mode ("Füllwörter weglassen"). MAI-Transcribe 2
 * does, wherever it runs (1.5 refused the whole request with it); Gemini's
 * transcribe model has "smart".
 */
export const hasCleanMode = (provider: Provider, model: string) =>
  provider === 'google' || (model.trim() || providers[provider].defaultModel).toLowerCase().includes('mai-transcribe-2')

export interface TranscriberSettings {
  provider: Provider
  model: string
  customBaseURL?: string
  /** Microsoft: the region of the Speech resource, and optionally its own address, which wins (microsoftHost). */
  microsoftRegion?: string
  microsoftEndpoint?: string
  vocabulary: string[]
  removesFillers: boolean
  language?: string
  /** Seconds before the first byte; one more second per four of audio. */
  timeout?: number
  attempts?: number
  /** Seconds to wait before asking a second time with the same audio; null
   *  never does. MAI-Transcribe usually answers in a second or two but now
   *  and then takes ten or more; the second request is usually back long
   *  before. The first answer wins. */
  backupAfter?: number | null
}

/**
 * tooLarge: the provider's upload limit (25 MB, about 13 minutes at OpenAI and
 * Groq); Retry would fail the same way. noCredit: the account is empty
 * (OpenRouter 402, OpenAI 429 insufficient_quota), not a busy provider.
 */
export type FailureKind = 'noKey' | 'unauthorized' | 'keyOrRegion' | 'rateLimited' | 'offline' | 'timedOut' | 'server' | 'unreadableResponse' | 'tooLarge' | 'noCredit'

export class TranscriptionFailure extends Error {
  constructor(readonly kind: FailureKind, readonly status?: number, readonly detail?: string) {
    super(detail ?? kind)
  }

  /** Two or three words, for the card and the menu. */
  get short(): string {
    switch (this.kind) {
      case 'noKey': return de('Kein Schlüssel', 'No key')
      case 'unauthorized': return de('Schlüssel abgelehnt', 'Key rejected')
      // Microsoft answers 401 for both: a key from another region reads like a wrong one.
      case 'keyOrRegion': return de('Schlüssel oder Region falsch', 'Key or region wrong')
      case 'rateLimited': return de('Anbieter drosselt', 'Provider busy')
      case 'offline': return de('Keine Verbindung', 'No connection')
      case 'timedOut': return de('Zeitüberschreitung', 'Timed out')
      // With the status: a wrong model (404) and a server fault (500) read alike.
      case 'server': return this.status ? de(`Fehler beim Anbieter (${this.status})`, `Provider error (${this.status})`) : de('Fehler beim Anbieter', 'Provider error')
      case 'unreadableResponse': return de('Antwort unlesbar', 'Unreadable answer')
      case 'tooLarge': return de('Zu lang für den Anbieter', 'Too long for the provider')
      case 'noCredit': return de('Kein Guthaben beim Anbieter', 'No credit left')
    }
  }
}

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: BodyInit; signal: AbortSignal }) => Promise<Response>

export function resolved(settings: TranscriberSettings) {
  const provider = providers[settings.provider]
  const baseURL = (provider.baseURL ?? settings.customBaseURL ?? '').replace(/\/+$/, '')
  const model = settings.model.trim() || provider.defaultModel
  return { baseURL, model, json: settings.provider === 'openrouter' }
}

function base64(bytes: Uint8Array): string {
  return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64')
}

/** The JSON OpenRouter wants; vocabulary goes to Azure's phrase list, since OpenRouter ignores `prompt` for MAI. */
export function openRouterBody(settings: TranscriberSettings, wav: Uint8Array) {
  const { model } = resolved(settings)
  const azure: Record<string, unknown> = {
    enhancedMode: { modelOptions: { transcribeStyle: settings.removesFillers ? 'clean' : 'verbatim' } },
  }
  if (settings.vocabulary.length > 0) azure.phraseList = { phrases: settings.vocabulary }
  const body: Record<string, unknown> = {
    model,
    input_audio: { data: base64(wav), format: 'wav' },
  }
  // Only MAI-Transcribe 2 takes these: MAI-Transcribe 1.5, also at Azure,
  // refused the whole request when they came along.
  if (model.includes('mai-transcribe-2')) body.provider = { options: { azure } }
  if (settings.language) body.language = settings.language
  if (settings.vocabulary.length > 0) body.prompt = settings.vocabulary.join(', ')
  return body
}

/** A language as Microsoft and Google want it (BCP 47), for the one place a fixed language is given. */
const locale = (language: string) => (language === 'de' ? 'de-DE' : language === 'en' ? 'en-US' : language)

/**
 * The model in Microsoft's request: "Azure Speech" is the plain fast
 * transcription, without `enhancedMode`; MAI-Transcribe 2 is `enhancedMode`
 * with the model named the way Microsoft spells it; an id typed in by hand is
 * passed on as typed.
 */
export function microsoftModel(id: string): string | null {
  const model = id.trim()
  if (model.toLowerCase() === 'azure-speech') return null
  return model.toLowerCase() === 'mai-transcribe-2' ? 'MAI-Transcribe-2' : model
}

/**
 * Azure AI Speech's `definition` part (fast transcription, api-version
 * 2025-10-15). The phrase list is the word list and the trigger phrases of the
 * replacements, as Microsoft's hint to spell them right. No `locales` unless a
 * language is fixed: Microsoft detects German and English by itself.
 */
export function microsoftDefinition(settings: TranscriberSettings) {
  const enhanced = microsoftModel(resolved(settings).model)
  const definition: Record<string, unknown> = {}
  if (enhanced) {
    definition.enhancedMode = { enabled: true, model: enhanced, modelOptions: { transcribeStyle: settings.removesFillers ? 'clean' : 'verbatim' } }
  }
  if (settings.vocabulary.length > 0) definition.phraseList = { phrases: settings.vocabulary }
  if (settings.language) definition.locales = [locale(settings.language)]
  return definition
}

/**
 * The Gemini API takes 20 MB for a whole request with the audio inline
 * (base64, a third more than the WAV): about 7.8 minutes of 16 kHz speech.
 * Kept just under, so a recording that would be refused is not sent at all.
 */
export const googleInlineLimit = 20_000_000
/** What the JSON around the audio adds, at most, with a long word list. */
const googleOverhead = 64_000

/**
 * Gemini 3.5 Transcribe, "interactions" API. `mode: "smart"` leaves out
 * fillers and self-corrections (the clean mode); without it the text is
 * verbatim. The word list is `custom_vocabulary` (up to 1000 terms).
 */
export function googleBody(settings: TranscriberSettings, wav: Uint8Array) {
  const { model } = resolved(settings)
  const transcription: Record<string, unknown> = { language_codes: settings.language ? [locale(settings.language)] : [] }
  if (settings.vocabulary.length > 0) transcription.custom_vocabulary = settings.vocabulary.slice(0, 1000)
  if (settings.removesFillers) transcription.mode = 'smart'
  return {
    model,
    input: [{ type: 'audio', data: base64(wav), mime_type: 'audio/wav' }],
    generation_config: { transcription_config: transcription },
  }
}

export function makeRequest(settings: TranscriberSettings, wav: Uint8Array, apiKey: string) {
  const { baseURL, model, json } = resolved(settings)
  const timeout = ((settings.timeout ?? 30) + Math.max(0, wav.length - 44) / 32_000 / 4) * 1000
  if (settings.provider === 'microsoft') {
    const host = microsoftHost(settings.microsoftRegion, settings.microsoftEndpoint)
    if (!host) throw new TranscriptionFailure('server', undefined, 'no usable region or address')
    const form = new FormData()
    form.append('audio', new Blob([wav as unknown as ArrayBuffer], { type: 'audio/wav' }), 'speech.wav')
    form.append('definition', JSON.stringify(microsoftDefinition(settings)))
    return { url: `${host}/speechtotext/transcriptions:transcribe?api-version=2025-10-15`, headers: { 'Ocp-Apim-Subscription-Key': apiKey } as Record<string, string>, body: form as BodyInit, timeout }
  }
  if (settings.provider === 'google') {
    // Before the audio is turned into a string a third larger.
    if (Math.ceil(wav.length / 3) * 4 + googleOverhead > googleInlineLimit) throw new TranscriptionFailure('tooLarge')
    return { url: `${baseURL}/interactions`, headers: { 'x-goog-api-key': apiKey, 'Content-Type': 'application/json' } as Record<string, string>, body: JSON.stringify(googleBody(settings, wav)) as BodyInit, timeout }
  }
  const url = `${baseURL}/audio/transcriptions`
  const headers: Record<string, string> = { Authorization: `Bearer ${apiKey}` }
  let body: BodyInit
  if (json) {
    headers['Content-Type'] = 'application/json'
    body = JSON.stringify(openRouterBody(settings, wav))
  } else {
    const form = new FormData()
    form.append('model', model)
    if (settings.vocabulary.length > 0) form.append('prompt', settings.vocabulary.join(', '))
    if (settings.language) form.append('language', settings.language)
    form.append('response_format', 'json')
    form.append('file', new Blob([wav as unknown as ArrayBuffer], { type: 'audio/wav' }), 'speech.wav')
    body = form
  }
  return { url, headers, body, timeout }
}

/** Seconds to wait after a 429: the header, OpenRouter's metadata, or 2; at most 5. */
export function retryDelay(retryAfter: string | null, body: string): number {
  let seconds = retryAfter !== null && retryAfter !== '' && !Number.isNaN(Number(retryAfter)) ? Number(retryAfter) : undefined
  if (seconds === undefined) {
    try {
      const value = JSON.parse(body)?.error?.metadata?.retry_after_seconds
      if (typeof value === 'number') seconds = value
    } catch { /* not JSON */ }
  }
  return Math.min(5, Math.max(0, seconds ?? 2))
}

/** The provider's own words for what went wrong: `{error: {message}}` (OpenAI, OpenRouter, Google) or Microsoft's `{code, message}`. */
function messageIn(body: string): string | undefined {
  try {
    const json = JSON.parse(body)
    const message = json?.error?.message ?? json?.message
    return typeof message === 'string' ? message : undefined
  } catch { return undefined }
}

/**
 * A refusal that means "too long for me", which Retry cannot cure. 413 is
 * that everywhere; Microsoft and Google also say it as a 400 with words.
 */
function isTooLarge(provider: Provider, status: number, message: string | undefined): boolean {
  if (status === 413) return true
  return (provider === 'microsoft' || provider === 'google') && status === 400 && /too (long|large|big)|exceeds?|maximum|payload size/i.test(message ?? '')
}

/** Google answers a wrong key with 400 "API key not valid", not 401. */
const isWrongGoogleKey = (provider: Provider, status: number, message: string | undefined) =>
  provider === 'google' && status === 400 && /api key not valid|API_KEY_INVALID/i.test(message ?? '')

/** `{"text": "…"}`, the answer of every provider but the two below. */
function plainText(json: unknown): string | undefined {
  const value = (json as { text?: unknown })?.text
  return typeof value === 'string' ? value : undefined
}

/** `combinedPhrases[].text`, Microsoft's whole text; the phrases themselves if it is missing. Empty for no speech. */
export function microsoftText(json: unknown): string | undefined {
  const answer = json as { combinedPhrases?: { text?: unknown }[]; phrases?: { text?: unknown }[] } | null
  const list = Array.isArray(answer?.combinedPhrases) ? answer.combinedPhrases : Array.isArray(answer?.phrases) ? answer.phrases : undefined
  return list?.map(item => (typeof item?.text === 'string' ? item.text.trim() : '')).filter(Boolean).join(' ')
}

/**
 * The text of a Gemini answer. Written against the documentation, not a real
 * answer, so it takes every shape the docs show: `steps[].content[]` with
 * `{type: "text"}` (the interactions API), `output_text`, and the older
 * `candidates[].content.parts[]` with `audioTranscription` or `text`. A
 * recognised answer with no text in it is silence: empty, not an error.
 */
export function googleText(json: unknown): string | undefined {
  const answer = json as {
    steps?: { content?: { type?: string; text?: unknown }[] }[]
    output_text?: unknown
    candidates?: { content?: { parts?: { text?: unknown; audioTranscription?: unknown }[] } }[]
  } | null
  if (!answer || typeof answer !== 'object') return undefined
  const found: string[] = []
  const add = (value: unknown) => {
    if (typeof value === 'string') found.push(value)
    else if (value && typeof value === 'object') add((value as { text?: unknown; transcript?: unknown }).text ?? (value as { transcript?: unknown }).transcript)
  }
  for (const step of Array.isArray(answer.steps) ? answer.steps : [])
    for (const item of Array.isArray(step?.content) ? step.content : [])
      if (item && (item.type === undefined || item.type === 'text' || item.type === 'output_text')) add(item.text)
  if (found.length === 0) add(answer.output_text)
  if (found.length === 0)
    for (const candidate of Array.isArray(answer.candidates) ? answer.candidates : [])
      for (const part of Array.isArray(candidate?.content?.parts) ? candidate.content.parts : []) add(part?.audioTranscription ?? part?.text)
  if (found.length > 0) return found.map(piece => piece.trim()).filter(Boolean).join(' ')
  return Array.isArray(answer.steps) || Array.isArray(answer.candidates) || typeof answer.output_text === 'string' ? '' : undefined
}

/** The text in a provider's answer; undefined where the answer is not one of its shapes. */
export function textIn(provider: Provider, body: string): string | undefined {
  let json: unknown
  try { json = JSON.parse(body) } catch { return undefined }
  const text = provider === 'microsoft' ? microsoftText(json) : provider === 'google' ? googleText(json) : plainText(json)
  return text?.trim()
}

export async function transcribe(settings: TranscriberSettings, wav: Uint8Array, apiKey: string, fetcher: Fetch = fetch as unknown as Fetch, sleep = (ms: number) => new Promise(r => setTimeout(r, ms))): Promise<string> {
  if (!apiKey) throw new TranscriptionFailure('noKey')
  const base = settings.backupAfter === undefined ? 2.5 : settings.backupAfter
  // OpenRouter only, where the slow answers were measured; counted from the
  // start of the upload, so a second more for every ten seconds of audio.
  if (base === null || settings.provider !== 'openrouter') return attempt(settings, wav, apiKey, fetcher, sleep)
  // Plus the time the upload takes at 1 Mbit/s: on a slow line the second
  // copy started while the first was still sending, and both ran out of time.
  const delay = base + (Math.max(0, wav.length - 44) * 8) / 1_000_000

  const controllers: AbortController[] = []
  const ask = () => { const c = new AbortController(); controllers.push(c); return attempt(settings, wav, apiKey, fetcher, sleep, c.signal) }
  return new Promise<string>((resolve, reject) => {
    let running = 1
    let backedUp = false
    let done = false
    let firstFailure: unknown
    const finish = (settle: () => void) => {
      if (done) return
      done = true
      clearTimeout(timer)
      controllers.forEach(c => c.abort())
      settle()
    }
    const follow = (request: Promise<string>) => request.then(
      text => finish(() => resolve(text)),
      error => {
        running--
        firstFailure ??= error
        // A failure before the second request went out is the answer:
        // rejected keys and the like do not get better.
        if (!backedUp || running === 0) finish(() => reject(firstFailure))
      },
    )
    follow(ask())
    const timer = setTimeout(() => { backedUp = true; running++; follow(ask()) }, delay * 1000)
  })
}

/** One request, tried again while the provider throttles. */
async function attempt(settings: TranscriberSettings, wav: Uint8Array, apiKey: string, fetcher: Fetch, sleep: (ms: number) => Promise<unknown>, cancel?: AbortSignal): Promise<string> {
  const request = makeRequest(settings, wav, apiKey)
  const attempts = settings.attempts ?? 3
  for (let attempt = 1; ; attempt++) {
    let response: Response
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), request.timeout)
    cancel?.addEventListener('abort', () => controller.abort())
    try {
      response = await fetcher(request.url, { method: 'POST', headers: request.headers, body: request.body, signal: controller.signal })
    } catch (error) {
      clearTimeout(timer)
      if ((error as Error).name === 'AbortError') throw new TranscriptionFailure('timedOut')
      throw new TranscriptionFailure('offline', undefined, (error as Error).message)
    }
    let text: string
    try {
      text = await response.text()
    } catch (error) {
      // Broken off while the answer came in: said as such, not a bare "Fehler".
      clearTimeout(timer)
      if ((error as Error).name === 'AbortError') throw new TranscriptionFailure('timedOut')
      throw new TranscriptionFailure('offline', undefined, (error as Error).message)
    }
    clearTimeout(timer)
    if (response.status === 402 || (response.status === 429 && /insufficient_quota/.test(text))) throw new TranscriptionFailure('noCredit', response.status)
    if (response.status === 429 && attempt < attempts) {
      await sleep(retryDelay(response.headers.get('retry-after'), text) * 1000)
      // The other request answered meanwhile, or the dictation was thrown away.
      if (cancel?.aborted) throw new TranscriptionFailure('timedOut')
      continue
    }
    const message = response.status >= 200 && response.status < 300 ? undefined : messageIn(text)
    if (response.status === 401 || response.status === 403 || isWrongGoogleKey(settings.provider, response.status, message)) {
      throw new TranscriptionFailure(settings.provider === 'microsoft' ? 'keyOrRegion' : 'unauthorized', response.status)
    }
    if (response.status === 429) throw new TranscriptionFailure('rateLimited', 429)
    if (isTooLarge(settings.provider, response.status, message)) throw new TranscriptionFailure('tooLarge', response.status)
    if (response.status < 200 || response.status >= 300) throw new TranscriptionFailure('server', response.status, message)
    const value = textIn(settings.provider, text)
    if (value === undefined) throw new TranscriptionFailure('unreadableResponse')
    return value
  }
}

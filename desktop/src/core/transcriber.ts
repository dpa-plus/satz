import { de } from './language'

/**
 * Where the audio goes to become text. Every provider takes
 * `POST {base}/audio/transcriptions`: multipart in OpenAI's format, or JSON for
 * OpenRouter. 'local' is the exception: Whisper runs on this computer and
 * nothing is sent anywhere. Ported from Provider.swift and Transcriber.swift.
 */
export type Provider = 'openai' | 'openrouter' | 'groq' | 'custom' | 'local'

export const providers: Record<Provider, { name: () => string; baseURL: string | null; defaultModel: string; keyPlaceholder: () => string }> = {
  openai: { name: () => 'OpenAI', baseURL: 'https://api.openai.com/v1', defaultModel: 'gpt-transcribe', keyPlaceholder: () => 'sk-…' },
  // 2.0% word errors on Artificial Analysis in Sept. 2026 against 3.3% for GPT
  // Transcribe, at a third of the price, and it has a clean mode.
  openrouter: { name: () => 'OpenRouter', baseURL: 'https://openrouter.ai/api/v1', defaultModel: 'microsoft/mai-transcribe-2', keyPlaceholder: () => 'sk-or-…' },
  groq: { name: () => 'Groq', baseURL: 'https://api.groq.com/openai/v1', defaultModel: 'whisper-large-v3-turbo', keyPlaceholder: () => 'gsk_…' },
  custom: { name: () => de('Eigener', 'Custom'), baseURL: null, defaultModel: '', keyPlaceholder: () => de('API-Schlüssel', 'API key') },
  local: { name: () => de('Lokal', 'Local'), baseURL: null, defaultModel: 'onnx-community/whisper-large-v3-turbo', keyPlaceholder: () => '' },
}

/** Every provider but the one on this computer wants a key. */
export const needsKey = (provider: Provider) => provider !== 'local'


export interface TranscriberSettings {
  provider: Provider
  model: string
  customBaseURL?: string
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

export type FailureKind = 'noKey' | 'unauthorized' | 'rateLimited' | 'offline' | 'timedOut' | 'server' | 'unreadableResponse'

export class TranscriptionFailure extends Error {
  constructor(readonly kind: FailureKind, readonly status?: number, readonly detail?: string) {
    super(detail ?? kind)
  }

  /** Two or three words, for the card and the menu. */
  get short(): string {
    switch (this.kind) {
      case 'noKey': return de('Kein Schlüssel', 'No key')
      case 'unauthorized': return de('Schlüssel abgelehnt', 'Key rejected')
      case 'rateLimited': return de('Anbieter drosselt', 'Provider busy')
      case 'offline': return de('Keine Verbindung', 'No connection')
      case 'timedOut': return de('Zeitüberschreitung', 'Timed out')
      case 'server': return de('Fehler beim Anbieter', 'Provider error')
      case 'unreadableResponse': return de('Antwort unlesbar', 'Unreadable answer')
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

export function makeRequest(settings: TranscriberSettings, wav: Uint8Array, apiKey: string) {
  const { baseURL, model, json } = resolved(settings)
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
  const timeout = ((settings.timeout ?? 30) + Math.max(0, wav.length - 44) / 32_000 / 4) * 1000
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

function messageIn(body: string): string | undefined {
  try {
    const message = JSON.parse(body)?.error?.message
    return typeof message === 'string' ? message : undefined
  } catch { return undefined }
}

export async function transcribe(settings: TranscriberSettings, wav: Uint8Array, apiKey: string, fetcher: Fetch = fetch as unknown as Fetch, sleep = (ms: number) => new Promise(r => setTimeout(r, ms))): Promise<string> {
  if (!apiKey) throw new TranscriptionFailure('noKey')
  const base = settings.backupAfter === undefined ? 2.5 : settings.backupAfter
  // OpenRouter only, where the slow answers were measured; counted from the
  // start of the upload, so a second more for every ten seconds of audio.
  if (base === null || settings.provider !== 'openrouter') return attempt(settings, wav, apiKey, fetcher, sleep)
  const delay = base + Math.max(0, wav.length - 44) / 32_000 / 10

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
    const text = await response.text()
    clearTimeout(timer)
    if (response.status === 429 && attempt < attempts) {
      await sleep(retryDelay(response.headers.get('retry-after'), text) * 1000)
      continue
    }
    if (response.status === 401 || response.status === 403) throw new TranscriptionFailure('unauthorized', response.status)
    if (response.status === 429) throw new TranscriptionFailure('rateLimited', 429)
    if (response.status < 200 || response.status >= 300) throw new TranscriptionFailure('server', response.status, messageIn(text))
    try {
      const value = JSON.parse(text)?.text
      if (typeof value !== 'string') throw new Error()
      return value.trim()
    } catch {
      throw new TranscriptionFailure('unreadableResponse')
    }
  }
}

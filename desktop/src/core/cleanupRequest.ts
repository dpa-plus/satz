import { characters, cleanAnswer, conversation, guard, levelFactor, tokens, type CleanupLevel, type CleanupReason } from './cleanup'
import { catalogModel, cleanupProviders, isOnThisComputer, modelSeconds, type CatalogModel, type CleanupProviderId } from './cleanupProviders'

/**
 * The three request shapes cleanup speaks: OpenAI's chat completions (and
 * everything that copies it: OpenRouter, Groq, Cerebras, Mistral, DeepSeek,
 * xAI, Azure, Ollama, LM Studio, Custom), Anthropic's messages and Gemini's
 * generateContent. Built and read here, without the network; the main
 * process hands in its fetch.
 */

/** OpenRouter's live `reasoning` facts about a model (cleanupPrices in the main process). */
export interface ReasoningFacts { supported_efforts?: string[]; mandatory?: boolean }

export interface CleanupJob {
  provider: CleanupProviderId
  /** The base address, already checked (cleanupProviders.ts, cleanupBase). */
  base: string
  model: string
  key: string | null
  level: CleanupLevel
  customPrompt: string
  /** The user's words only, not the replacements' phrases. */
  vocabulary: string[]
  text: string
  /** OpenRouter's live list knows the model: its reasoning facts, or null where the list does not have it. Undefined: no list. */
  reasoning?: ReasoningFacts | null
}

export interface Request { url: string; headers: Record<string, string>; body: Record<string, unknown> }

/**
 * Room for the answer: twice the dictation and a margin, plus room for the
 * model's thinking where the request does not switch it off, never more than
 * 8000. Thinking spends the same budget, and an answer cut off is never
 * pasted ("Antwort abgeschnitten"); billing is per generated token, so the
 * bigger ceiling costs nothing by itself, and the guard still throws out a
 * runaway answer.
 */
export const maxTokens = (text: string, thinkingRoom = 0) => Math.min(8000, 2 * tokens(characters(text)) + 200 + thinkingRoom)

/** What a model that thinks may spend before it answers. */
const thinkingTokens = 2000

/**
 * Whether the request switches thinking fully off: OpenRouter's `enabled:
 * false` or effort "none", `reasoning_effort: "none"`, Anthropic's and
 * DeepSeek's `thinking: {type: "disabled"}`, Gemini's `thinkingBudget: 0`.
 * "low" or "minimal", Anthropic's `output_config`, Gemini's `thinkingLevel`
 * and an id nothing is known about leave it on. `fields` are the body's, with
 * Gemini's `thinkingConfig` taken out of its generationConfig.
 */
export function thinkingRoom(fields: Record<string, unknown>): number {
  const reasoning = fields.reasoning as { enabled?: unknown; effort?: unknown } | undefined
  if (reasoning) return reasoning.enabled === false || reasoning.effort === 'none' ? 0 : thinkingTokens
  if (fields.reasoning_effort === 'none') return 0
  if ((fields.thinking as { type?: unknown } | undefined)?.type === 'disabled') return 0
  if ((fields.thinkingConfig as { thinkingBudget?: unknown } | undefined)?.thinkingBudget === 0) return 0
  return thinkingTokens
}

/**
 * Sets the answer's limit for the body as it is now, in the family's own
 * field: asked again after a retry, which may have taken the switch that kept
 * the model from thinking out of the body.
 */
function setBudget(body: Record<string, unknown>, text: string) {
  const config = body.generationConfig as Record<string, unknown> | undefined
  const limit = maxTokens(text, thinkingRoom(config ? { ...body, thinkingConfig: config.thinkingConfig } : body))
  if (config) config.maxOutputTokens = limit
  else if ('max_completion_tokens' in body) body.max_completion_tokens = limit
  else body.max_tokens = limit
}

const efforts = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']

/**
 * Thinking off through OpenRouter, from the live list: "none" where the model
 * has it, else off where it may be, else the least it takes. A model the list
 * does not have gets "off" (and "low" once a 400 names reasoning); with no
 * list at all, what the rule gave when the catalog was made.
 */
export function openRouterReasoning(facts: ReasoningFacts | null | undefined, catalog?: CatalogModel): Record<string, unknown> {
  if (facts === undefined) return catalog?.reasoning ?? { enabled: false }
  if (facts === null) return { enabled: false }
  const supported = facts.supported_efforts ?? []
  if (supported.includes('none')) return { effort: 'none' }
  if (facts.mandatory !== true) return { enabled: false }
  return { effort: efforts.find(effort => supported.includes(effort)) ?? 'low' }
}

/** The extras a model gets: the catalog's, else what the provider gives any model (Anthropic: Haiku's; Gemini: by its generation). */
function extrasFor(job: CleanupJob): { extras: Record<string, unknown>; noTemperature: boolean } {
  const entry = cleanupProviders[job.provider]
  const known = catalogModel(job.provider, job.model)
  if (known) return { extras: { ...known.extras }, noTemperature: known.noTemperature === true }
  if (entry.family === 'gemini') return { extras: { thinkingConfig: job.model.includes('2.5') ? { thinkingBudget: 0 } : { thinkingLevel: 'minimal' } }, noTemperature: false }
  return { extras: { ...entry.anyModel?.extras }, noTemperature: entry.anyModel?.noTemperature === true }
}

/** The request, before any field was dropped for a provider that refused it. */
export function buildRequest(job: CleanupJob): Request {
  const entry = cleanupProviders[job.provider]
  const chat = conversation(job.level, job.text, job.vocabulary, job.customPrompt)
  const { extras, noTemperature } = extrasFor(job)
  // The limit is set last, from the body as it is (setBudget); 0 holds the place.
  const limit = 0
  if (entry.family === 'anthropic') {
    const body = { model: job.model, max_tokens: limit, system: chat.system, messages: chat.turns, ...extras }
    setBudget(body, job.text)
    return {
      url: `${job.base}/messages`,
      headers: { 'x-api-key': job.key ?? '', 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      // No sampling parameters at all: Claude 5.5 refuses them.
      body,
    }
  }
  if (entry.family === 'gemini') {
    const model = job.model.replace(/^models\//, '')
    const body = {
      systemInstruction: { parts: [{ text: chat.system }] },
      contents: chat.turns.map(turn => ({ role: turn.role === 'assistant' ? 'model' : 'user', parts: [{ text: turn.content }] })),
      generationConfig: { temperature: 0, maxOutputTokens: limit, ...extras },
    }
    setBudget(body, job.text)
    return {
      url: `${job.base}/models/${encodeURIComponent(model)}:generateContent`,
      headers: { 'x-goog-api-key': job.key ?? '', 'Content-Type': 'application/json' },
      body,
    }
  }
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (job.key) {
    if (job.provider === 'azure') headers['api-key'] = job.key
    else headers.Authorization = `Bearer ${job.key}`
  }
  const body: Record<string, unknown> = {
    model: job.model,
    messages: [{ role: 'system', content: chat.system }, ...chat.turns],
    ...(noTemperature ? {} : { temperature: 0 }),
    [entry.completionTokens ? 'max_completion_tokens' : 'max_tokens']: limit,
    stream: false,
    ...extras,
  }
  if (job.provider === 'openrouter') {
    body.reasoning = openRouterReasoning(job.reasoning, catalogModel('openrouter', job.model))
    // The answer then says what it cost.
    body.usage = { include: true }
    body.provider = { sort: 'latency' }
  }
  setBudget(body, job.text)
  return { url: `${job.base}/chat/completions`, headers, body }
}

/**
 * The same request without the fields a 400 named, so a provider that
 * changed its API still answers. OpenRouter's `reasoning`, when the 400 names
 * it: "off" becomes "low" once (a model that must think), any other value
 * goes. Null when nothing named can go.
 */
export function withoutRefused(request: Request, message: string, dropped: Set<string>, text?: string): Request | null {
  const said = message.toLowerCase()
  const body = structuredClone(request.body)
  let changed = false
  const reasoning = body.reasoning as Record<string, unknown> | undefined
  if (reasoning && said.includes('reasoning') && !dropped.has('reasoning')) {
    if (reasoning.enabled === false) body.reasoning = { effort: 'low' }
    else delete body.reasoning
    dropped.add('reasoning')
    changed = true
  }
  const config = body.generationConfig as Record<string, unknown> | undefined
  if (config?.thinkingConfig && said.includes('thinking') && !dropped.has('thinkingConfig')) {
    delete config.thinkingConfig
    dropped.add('thinkingConfig')
    changed = true
  }
  for (const field of ['reasoning_effort', 'include_reasoning', 'reasoning_format', 'thinking', 'output_config', 'temperature']) {
    if (field in body && said.includes(field) && !dropped.has(field)) {
      delete body[field]
      dropped.add(field)
      changed = true
    }
  }
  if (!changed) return null
  // With the dictation known, the limit follows: a model that was kept from thinking by the field that went may think now.
  if (text !== undefined) setBudget(body, text)
  return { ...request, body }
}

// MARK: - The answer

/** `truncated`: the answer hit max_tokens, so its end is missing (thinking models spend the same budget on their thinking). */
export interface Parsed { text: string; refused: boolean; truncated: boolean; inputTokens?: number; outputTokens?: number; dollars?: number }

const joinText = (parts: unknown) => Array.isArray(parts)
  ? parts.map(part => (typeof part === 'string' ? part : typeof (part as { text?: unknown })?.text === 'string' ? (part as { text: string }).text : '')).join('')
  : typeof parts === 'string' ? parts : ''

const count = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)

/** The text of an answer; undefined for one that is none of the shapes. */
export function parseAnswer(provider: CleanupProviderId, json: unknown): Parsed | undefined {
  if (!json || typeof json !== 'object') return undefined
  const family = cleanupProviders[provider].family
  if (family === 'anthropic') {
    const answer = json as { content?: { type?: string; text?: string }[]; stop_reason?: string; usage?: { input_tokens?: number; output_tokens?: number } }
    if (!Array.isArray(answer.content)) return undefined
    return {
      text: answer.content.filter(item => item?.type === 'text').map(item => item.text ?? '').join(''),
      refused: answer.stop_reason === 'refusal',
      truncated: answer.stop_reason === 'max_tokens',
      inputTokens: count(answer.usage?.input_tokens), outputTokens: count(answer.usage?.output_tokens),
    }
  }
  if (family === 'gemini') {
    const answer = json as { candidates?: { content?: { parts?: { text?: string; thought?: boolean }[] }; finishReason?: string }[]; usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number } }
    if (!Array.isArray(answer.candidates)) return undefined
    const first = answer.candidates[0]
    // Parts marked as thought are the model thinking, not its answer.
    const parts = (first?.content?.parts ?? []).filter(part => part && part.thought !== true)
    return {
      text: parts.map(part => part.text ?? '').join(''),
      refused: first?.finishReason === 'SAFETY' || first?.finishReason === 'PROHIBITED_CONTENT',
      truncated: first?.finishReason === 'MAX_TOKENS',
      inputTokens: count(answer.usageMetadata?.promptTokenCount), outputTokens: count(answer.usageMetadata?.candidatesTokenCount),
    }
  }
  const answer = json as { choices?: { message?: { content?: unknown; refusal?: unknown }; finish_reason?: string }[]; usage?: { prompt_tokens?: number; completion_tokens?: number; cost?: number } }
  if (!Array.isArray(answer.choices)) return undefined
  const message = answer.choices[0]?.message
  return {
    text: joinText(message?.content),
    refused: typeof message?.refusal === 'string' && message.refusal.trim() !== '',
    truncated: answer.choices[0]?.finish_reason === 'length',
    inputTokens: count(answer.usage?.prompt_tokens), outputTokens: count(answer.usage?.completion_tokens),
    dollars: count(answer.usage?.cost),
  }
}

/** What a status says, in the reasons the history and the log use. */
export function reasonForStatus(status: number, body = ''): CleanupReason {
  // Google answers a key it does not know with 400 INVALID_ARGUMENT, not 401 (transcriber.ts, the Mac's CleanupFailure).
  if (status === 401 || status === 403 || (status === 400 && /api key not valid|API_KEY_INVALID/i.test(body))) return 'keyRejected'
  if (status === 402 || (status === 429 && /insufficient_quota/.test(body))) return 'noCredit'
  if (status === 404) return 'modelNotFound'
  if (status === 429) return 'tooManyRequests'
  if (status >= 500) return 'providerError'
  return 'refused'
}

/** The provider's own short words for what went wrong, for the log only: never the body itself. */
export function providerMessage(body: string): string {
  try {
    const json = JSON.parse(body)
    const message = json?.error?.message ?? json?.message ?? json?.error
    return typeof message === 'string' ? message.slice(0, 200) : ''
  } catch { return '' }
}

// MARK: - Running it

/**
 * Seconds before giving up: the answer's tokens at a slow pace on top of a
 * fixed wait, and never less than three times the seconds the model took
 * when measured (Grok 4.7 thinks for 4.6 s: the plain rule is 8 s, and a
 * slow minute on the network must not cut it off). On this computer longer:
 * the first call loads the model. The characters are the Mac's, scalars.
 */
export function cleanupTimeout(job: Pick<CleanupJob, 'provider' | 'base' | 'model' | 'text' | 'level'>): number {
  const out = tokens(characters(job.text)) * levelFactor(job.level)
  const slow = 3 * (modelSeconds(job.provider, job.model) ?? 0)
  const local = cleanupProviders[job.provider].local || isOnThisComputer(job.base)
  return local ? Math.min(60, Math.max(20 + out / 15, slow)) : Math.min(30, Math.max(6 + out / 40, slow))
}

export type CleanupResult =
  | { kind: 'cleaned'; text: string; answer: string; changed: boolean; seconds: number; inputTokens?: number; outputTokens?: number; dollars?: number }
  | { kind: 'failed'; reason: CleanupReason; status?: number; message?: string; answer?: string; seconds?: number }

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<Response>

/**
 * One cleanup: the request, at most one more per field a 400 named, the
 * answer cleaned and judged. Never throws; a failure says why, and the
 * caller pastes the original.
 */
export async function runCleanup(job: CleanupJob, fetcher: Fetch, options: { timeout?: number; signal?: AbortSignal; now?: () => number } = {}): Promise<CleanupResult> {
  // Cancelled before it started (a Try cancelled while Ollama listed its models): an abort listener never fires for that.
  if (options.signal?.aborted) return { kind: 'failed', reason: 'unreachable', message: 'cancelled' }
  // The model gets the text without the line breaks and spaces at its ends and
  // the guard judges that; the breaks the dictation began or ended with come
  // back on the answer (cleanAnswer). The Mac does the same.
  const original = job.text
  const sent: CleanupJob = { ...job, text: original.trim() }
  const now = options.now ?? Date.now
  const started = now()
  const elapsed = () => (now() - started) / 1000
  const deadline = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => { timedOut = true; deadline.abort() }, (options.timeout ?? cleanupTimeout(sent)) * 1000)
  const cancel = () => deadline.abort()
  options.signal?.addEventListener('abort', cancel)
  const broken = (error: unknown): CleanupResult => {
    if (timedOut) return { kind: 'failed', reason: 'tooSlow' }
    return { kind: 'failed', reason: 'unreachable', message: (error as Error)?.message?.slice(0, 200) }
  }
  try {
    let request = buildRequest(sent)
    const dropped = new Set<string>()
    for (;;) {
      let response: Response, body: string
      try {
        response = await fetcher(request.url, { method: 'POST', headers: request.headers, body: JSON.stringify(request.body), signal: deadline.signal })
        body = await response.text()
      } catch (error) { return broken(error) }
      if (response.status === 400) {
        const message = providerMessage(body)
        const next = withoutRefused(request, message, dropped, sent.text)
        if (next) { request = next; continue }
      }
      if (response.status < 200 || response.status >= 300) return { kind: 'failed', reason: reasonForStatus(response.status, body), status: response.status, message: providerMessage(body) }
      let json: unknown
      try { json = JSON.parse(body) } catch { return { kind: 'failed', reason: 'providerError', status: response.status, message: 'unreadable answer' } }
      const parsed = parseAnswer(job.provider, json)
      if (!parsed) return { kind: 'failed', reason: 'providerError', status: response.status, message: 'unreadable answer' }
      const seconds = elapsed()
      if (parsed.refused) return { kind: 'failed', reason: 'answerRefused', seconds }
      const answer = cleanAnswer(parsed.text, original)
      if (answer.trim() === '') return { kind: 'failed', reason: 'empty', seconds }
      // The end of the dictation is missing, and the guard lets "Leicht" keep only 55 % of the words: never paste that.
      if (parsed.truncated) return { kind: 'failed', reason: 'cutOff', answer, seconds }
      if (!guard(sent.text, answer, job.level, job.vocabulary)) return { kind: 'failed', reason: 'rejected', answer, seconds }
      return { kind: 'cleaned', text: answer, answer, changed: answer !== original, seconds, inputTokens: parsed.inputTokens, outputTokens: parsed.outputTokens, dollars: parsed.dollars }
    }
  } finally {
    clearTimeout(timer)
    options.signal?.removeEventListener('abort', cancel)
  }
}

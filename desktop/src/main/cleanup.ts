import fs from 'node:fs'
import path from 'node:path'
import { reasonCode, reasonText, worthCleaning, type CleanupLevel, type CleanupReason } from '../core/cleanup'
import { addSample, measurementKey, runDollars, modelFacts, type Price, type Sample } from '../core/cleanupEstimate'
import { catalogModel, chosenModel, cleanupBase, cleanupProviders, isOnThisComputer, type CleanupProviderId } from '../core/cleanupProviders'
import { runCleanup, type CleanupJob, type ReasoningFacts } from '../core/cleanupRequest'

/**
 * Cleanup in the main process: the keys, the network and the files around
 * the request that core/cleanupRequest.ts builds. Apart from main.ts and
 * Electron, so a test runs it against a stand-in server.
 */

/** What cleanup goes by, for the provider in use or one Settings shows. */
export interface CleanupSettings {
  provider: CleanupProviderId
  /** As chosen; '' for the provider's default (Ollama, LM Studio: the first installed). */
  model: string
  /** As typed; '' for the default. */
  address: string
  level: CleanupLevel
  customPrompt: string
  vocabulary: string[]
}

export interface CleanerDeps {
  /** satz's data folder: the measurements and OpenRouter's list live there. */
  dir: string
  /** The settings for a provider, the one in use when none is named. */
  settings(provider?: CleanupProviderId): CleanupSettings
  readAccount(account: string): string | null
  /** Electron's net.fetch in the app: the system proxy and certificates. */
  fetcher: typeof fetch
  log(message: string): void
  /** Settings is told: a list or a measurement arrived. */
  changed(): void
  /** Test mode: requests go only to this computer (a stand-in server), never to a provider that costs money. */
  onlyThisComputer?: boolean
  now?: () => number
}

/** A cleanup's outcome: the text to paste, "ok" or the reason, and what the model said. */
export interface CleanupRun {
  text: string
  /** "ok" or the short reason in the language of the page, as the history keeps it. */
  outcome: 'ok' | string
  /** "ok" or the stable word for the reason (no-key, too-slow, refused-422 …): the same list as the Mac, for the test mode's state. */
  code: 'ok' | string
  reason?: CleanupReason
  /** The model's answer, also when the guard threw it out ("Ausprobieren" shows it). */
  answer?: string
  rejected: boolean
  seconds?: number
  dollars?: number
  provider: CleanupProviderId
  model: string
}

interface Listed { input?: number; output?: number; reasoning: ReasoningFacts | null }
interface Installed { state: 'loading' | 'ok' | 'down'; models: string[]; fetched: number }

const day = 24 * 3600_000

export class Cleaner {
  /**
   * The cleanup of the dictation delivered last, for the test mode's `state`:
   * null when that one was not cleaned up, as the Mac's lastCleanup. Set by
   * `delivered`, so a dictation thrown away during its cleanup never shows.
   * Never logged.
   */
  last: (CleanupRun & { original: string }) | null = null
  private latest: (CleanupRun & { original: string }) | null = null
  private samples: Record<string, Sample[]>
  private listed: { fetched: number; models: Record<string, Listed> } | null
  private fetchingList = false
  private listFailed = -Infinity
  private installed = new Map<string, Installed>()

  constructor(private deps: CleanerDeps) {
    this.samples = this.read<Record<string, Sample[]>>('cleanup-speeds.json') ?? {}
    this.listed = this.read('models/openrouter-cleanup.json')
  }

  private get now() { return this.deps.now?.() ?? Date.now() }

  private read<T>(name: string): T | null {
    try { return JSON.parse(fs.readFileSync(path.join(this.deps.dir, name), 'utf8')) as T } catch { return null }
  }

  /** Beside the file and moved over it, so a write cut short leaves the old one (store.ts does the same). */
  private write(name: string, value: unknown) {
    const target = path.join(this.deps.dir, name)
    try {
      fs.mkdirSync(path.dirname(target), { recursive: true })
      fs.writeFileSync(`${target}.new`, JSON.stringify(value))
      fs.renameSync(`${target}.new`, target)
    } catch (error) { this.deps.log(`cleanup: ${name} not written (${(error as Error).message})`) }
  }

  // MARK: - Running

  /**
   * One cleanup, for a dictation or for "Ausprobieren" (`provider` is then
   * the one Settings shows). Never throws: whatever fails, the original
   * comes back with the reason. Never logs the text or the key.
   */
  async run(text: string, options: { provider?: CleanupProviderId; signal?: AbortSignal; trying?: boolean } = {}): Promise<CleanupRun> {
    const settings = this.deps.settings(options.provider)
    const { provider } = settings
    const entry = cleanupProviders[provider]
    const base = cleanupBase(provider, settings.address)
    let model = chosenModel(provider, settings.model, base && entry.lists ? this.installedAt(provider, base).models : [])
    const finish = (run: CleanupRun) => this.finish(run, text, options.trying === true)
    const failed = (reason: CleanupReason): CleanupRun => ({ text, outcome: reasonText(reason), code: reasonCode(reason), reason, rejected: false, provider, model })
    if (!worthCleaning(text)) return finish({ text, outcome: 'ok', code: 'ok', rejected: false, provider, model })
    // What is missing, in the Mac's order: the prompt, the key, the address, the model.
    if (settings.level === 'custom' && !settings.customPrompt.trim()) return finish(failed('noPrompt'))
    const key = entry.account ? this.deps.readAccount(entry.account) : null
    if (entry.account && !entry.keyOptional && !key) return finish(failed('noKey'))
    if (!base) return finish(failed('noAddress'))
    // Ollama and LM Studio without a model chosen: the first one there, asked now if not known yet.
    if (!model && entry.lists) model = (await this.listInstalled(provider, base))[0] ?? ''
    if (!model) return finish(failed('noModel'))
    if (this.deps.onlyThisComputer && !isOnThisComputer(base)) {
      this.deps.log(`cleanup: test mode sends nothing to ${provider}`)
      return finish(failed('unreachable'))
    }
    const job: CleanupJob = {
      provider, base, model, key, level: settings.level, customPrompt: settings.customPrompt, vocabulary: settings.vocabulary, text,
      reasoning: provider === 'openrouter' ? this.reasoningFacts(model) : undefined,
    }
    const result = await runCleanup(job, this.deps.fetcher as never, { signal: options.signal, now: this.deps.now })
    const price = this.price(provider, model)
    let run: CleanupRun
    if (result.kind === 'cleaned') {
      run = { text: result.text, outcome: 'ok', code: 'ok', answer: result.answer, rejected: false, seconds: result.seconds, dollars: runDollars(result, price), provider, model }
    } else {
      run = { ...failed(result.reason), outcome: reasonText(result.reason, result.status), code: reasonCode(result.reason, result.status), answer: result.answer, rejected: result.reason === 'rejected', seconds: result.seconds }
      // The status and the provider's own short words; never the text or the key.
      if (result.status || result.message) this.deps.log(`cleanup: ${provider} answered ${result.status ?? 'nothing'}${result.message ? `: ${result.message}` : ''}`)
    }
    // Only a run that got an answer says how long the model takes.
    if (run.seconds !== undefined && !options.signal?.aborted) this.record(provider, model, { seconds: run.seconds, ...(run.dollars !== undefined ? { dollars: run.dollars } : {}), date: new Date(this.now).toISOString() })
    return finish(run)
  }

  /** Lengths and times only in the log. */
  private finish(run: CleanupRun, original: string, trying: boolean): CleanupRun {
    this.deps.log(`cleanup${trying ? ' (try)' : ''}: ${run.provider} ${run.model || '-'}, ${run.reason ?? 'ok'}${run.seconds !== undefined ? ` after ${run.seconds.toFixed(1)} s` : ''}, ${original.length} characters${run.answer !== undefined ? ` in, ${run.answer.length} back` : ''}`)
    if (!trying) this.latest = { ...run, original }
    return run
  }

  /** A dictation was delivered: `cleaned` when it went through cleanup, then this run is the one the state shows. */
  delivered(cleaned: boolean) {
    this.last = cleaned ? this.latest : null
  }

  private record(provider: CleanupProviderId, model: string, sample: Sample) {
    this.samples = addSample(this.samples, measurementKey(provider, model), sample)
    this.write('cleanup-speeds.json', this.samples)
    this.deps.changed()
  }

  /** The runs measured for a provider's models, by model id. */
  measured(provider: CleanupProviderId): Record<string, Sample[]> {
    const prefix = `${provider}|`
    return Object.fromEntries(Object.entries(this.samples).filter(([key]) => key.startsWith(prefix)).map(([key, list]) => [key.slice(prefix.length), list]))
  }

  // MARK: - OpenRouter's list

  /** The live price where OpenRouter's list has the model; Azure and the catalog are cleanupEstimate.ts's. */
  livePrice(model: string): Price | undefined {
    const listed = this.listed?.models[model]
    return listed?.input !== undefined && listed.output !== undefined ? { input: listed.input, output: listed.output } : undefined
  }

  /** What a run is priced at for its measured cost; a model on this computer costs nothing (the Mac says "0 $" too). */
  private price(provider: CleanupProviderId, model: string): Price | undefined {
    const facts = modelFacts(provider, model, provider === 'openrouter' ? this.livePrice(model) : undefined)
    return facts.free ? { input: 0, output: 0 } : facts.price
  }

  /** Undefined without a list (the catalog's value applies), null for a model the list does not have. */
  private reasoningFacts(model: string): ReasoningFacts | null | undefined {
    if (!this.listed) return catalogModel('openrouter', model) ? undefined : null
    return this.listed.models[model]?.reasoning ?? null
  }

  /** Asks OpenRouter again once a day, not within ten minutes of a failure. Public: it needs no key. */
  refreshList() {
    if (this.fetchingList || this.now - this.listFailed < 10 * 60_000) return
    if (this.listed && this.now - this.listed.fetched < day) return
    this.fetchingList = true
    this.deps.fetcher('https://openrouter.ai/api/v1/models', { signal: AbortSignal.timeout(15_000) })
      .then(async response => {
        if (!response.ok) throw new Error(`status ${response.status}`)
        const models = parseOpenRouterList(await response.json())
        if (Object.keys(models).length === 0) throw new Error('empty list')
        this.listed = { fetched: this.now, models }
        this.write('models/openrouter-cleanup.json', this.listed)
        this.deps.log(`cleanup: ${Object.keys(models).length} models from OpenRouter`)
        this.deps.changed()
      })
      .catch(error => {
        this.listFailed = this.now
        this.deps.log(`cleanup: OpenRouter's list not fetched (${(error as Error).message})`)
      })
      .finally(() => { this.fetchingList = false })
  }

  // MARK: - Ollama and LM Studio

  /** What is installed there, as last asked; asks again when that was more than ten seconds ago. */
  installedAt(provider: CleanupProviderId, base: string): Installed {
    const known = this.installed.get(`${provider}|${base}`)
    if (!known || (known.state !== 'loading' && this.now - known.fetched > 10_000)) void this.listInstalled(provider, base)
    return this.installed.get(`${provider}|${base}`) ?? { state: 'loading', models: [], fetched: 0 }
  }

  private async listInstalled(provider: CleanupProviderId, base: string): Promise<string[]> {
    const id = `${provider}|${base}`
    const before = this.installed.get(id)
    this.installed.set(id, { state: 'loading', models: before?.models ?? [], fetched: before?.fetched ?? 0 })
    let next: Installed
    try {
      const response = await this.deps.fetcher(`${base}/models`, { signal: AbortSignal.timeout(3_000) })
      if (!response.ok) throw new Error(`status ${response.status}`)
      const data = ((await response.json()) as { data?: { id?: unknown }[] })?.data
      // Embedding models answer no chat (the Mac leaves them out too).
      next = { state: 'ok', models: Array.isArray(data) ? data.map(model => model?.id).filter((id): id is string => typeof id === 'string' && !id.toLowerCase().includes('embed')) : [], fetched: this.now }
    } catch {
      next = { state: 'down', models: [], fetched: this.now }
    }
    this.installed.set(id, next)
    if (before?.state !== next.state || before.models.join() !== next.models.join()) this.deps.changed()
    return next.models
  }
}

/** `{data: [{id, pricing: {prompt, completion}, reasoning?}]}`: dollars per token as strings, kept per million. */
export function parseOpenRouterList(json: unknown): Record<string, Listed> {
  const data = (json as { data?: { id?: unknown; pricing?: { prompt?: unknown; completion?: unknown }; reasoning?: unknown }[] })?.data
  const out: Record<string, Listed> = {}
  for (const model of Array.isArray(data) ? data : []) {
    if (typeof model?.id !== 'string') continue
    const input = Number(model.pricing?.prompt), output = Number(model.pricing?.completion)
    const reasoning = model.reasoning && typeof model.reasoning === 'object' ? model.reasoning as Record<string, unknown> : null
    out[model.id] = {
      ...(input >= 0 && output >= 0 && model.pricing?.prompt !== undefined ? { input: input * 1e6, output: output * 1e6 } : {}),
      reasoning: reasoning ? {
        ...(Array.isArray(reasoning.supported_efforts) ? { supported_efforts: reasoning.supported_efforts.filter((e): e is string => typeof e === 'string') } : {}),
        ...(typeof reasoning.mandatory === 'boolean' ? { mandatory: reasoning.mandatory } : {}),
      } : null,
    }
  }
  return out
}

/**
 * The test mode's state for the last dictation, with the keys of the Mac's
 * dump: `outcome` is "ok" or the stable word for the reason, `reason` the
 * short one in the page's language (not there on "ok"), `cleaned` what the
 * model answered (null when nothing came back, also after a failure that
 * threw it out), `original` what went in. Null when that dictation was not
 * cleaned up.
 */
export function cleanupState(last: (CleanupRun & { original: string }) | null) {
  return last && {
    outcome: last.code,
    ...(last.code === 'ok' ? {} : { reason: last.outcome }),
    original: last.original,
    cleaned: last.answer ?? null,
    provider: last.provider,
    model: last.model,
    seconds: last.seconds ?? null,
  }
}

/** The same for "Ausprobieren": its answer, whether the guard threw it out, its time and cost. */
export function cleanupTryState(run: CleanupRun) {
  return {
    provider: run.provider,
    model: run.model,
    outcome: run.code,
    ...(run.code === 'ok' ? {} : { reason: run.outcome }),
    cleaned: run.answer ?? null,
    rejected: run.rejected,
    seconds: run.seconds ?? null,
    dollars: run.dollars ?? null,
  }
}

export interface CleanupView {
  /** OpenRouter's live prices for the menu's models and the one chosen, per million tokens. */
  prices: Record<string, Price>
  /** The runs measured on this computer, by model id. */
  samples: Record<string, Sample[]>
  /** Ollama and LM Studio: what is installed there, and whether it answered. */
  installed: { state: Installed['state']; models: string[] } | null
}

/** What Settings shows for a provider; asks OpenRouter and the local servers again where that is due. */
export function cleanupView(cleaner: Cleaner, provider: CleanupProviderId, chosen: string, address: string): CleanupView {
  cleaner.refreshList()
  const entry = cleanupProviders[provider]
  const base = cleanupBase(provider, address)
  const installed = entry.lists && base ? cleaner.installedAt(provider, base) : null
  const prices: Record<string, Price> = {}
  if (provider === 'openrouter') {
    for (const id of [...entry.models.map(model => model.id), chosen]) {
      const price = id ? cleaner.livePrice(id) : undefined
      if (price) prices[id] = price
    }
  }
  return { prices, samples: cleaner.measured(provider), installed: installed && { state: installed.state, models: installed.models } }
}

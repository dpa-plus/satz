import fs from 'node:fs'
import path from 'node:path'
import { listURL, models, parse, type ModelChoice } from '../core/models'
import type { Provider } from '../core/transcriber'

/**
 * The models each provider offers, for the settings' menu: the provider's own
 * list, fetched when the settings ask for it and kept on disk for a day, so
 * new models appear without a new satz. Until it arrives, and whenever it
 * cannot, the list satz ships with. Like ModelStore.swift on the Mac.
 */
export class ModelLists {
  private fetching = new Set<Provider>()
  /** When each provider last failed: Settings is drawn again for every change, and each drawing asked anew. */
  private failed = new Map<Provider, number>()

  /** @param fetcher Electron's net.fetch in the app: the system proxy and certificates. */
  constructor(private dir: string, private readKey: (provider: Provider) => string | null, private log: (message: string) => void, private changed: () => void,
    private fetcher: typeof fetch = fetch, private now: () => number = Date.now) {}

  private file(provider: Provider) { return path.join(this.dir, 'models', `${provider}.json`) }

  private kept(provider: Provider): { fetched: number; models: ModelChoice[] } | null {
    try { return JSON.parse(fs.readFileSync(this.file(provider), 'utf8')) } catch { return null }
  }

  get(provider: Provider): ModelChoice[] {
    // Local's models are cards, not a menu (core/localModels.ts has them): nothing to send.
    if (provider === 'local') return []
    return this.kept(provider)?.models ?? models[provider]
  }

  /** Asks the provider again when the kept list is older than a day, and not within ten minutes of a failure. */
  refresh(provider: Provider) {
    const url = listURL[provider]
    if (!url || this.fetching.has(provider)) return
    if (this.now() - (this.failed.get(provider) ?? -Infinity) < 10 * 60_000) return
    const kept = this.kept(provider)
    if (kept && this.now() - kept.fetched < 24 * 3600_000) return
    const key = provider === 'openrouter' ? null : this.readKey(provider)
    if (provider !== 'openrouter' && !key) return
    this.fetching.add(provider)
    this.fetcher(url, { headers: key ? { Authorization: `Bearer ${key}` } : {}, signal: AbortSignal.timeout(15_000) })
      .then(async response => {
        if (!response.ok) throw new Error(`status ${response.status}`)
        const list = parse(await response.json(), provider)
        if (list.length === 0) throw new Error('empty list')
        fs.mkdirSync(path.dirname(this.file(provider)), { recursive: true })
        fs.writeFileSync(this.file(provider), JSON.stringify({ fetched: this.now(), models: list }))
        this.log(`models: ${list.length} from ${provider}`)
        this.changed()
      })
      .catch(error => {
        this.failed.set(provider, this.now())
        this.log(`models: ${provider} list not fetched (${(error as Error).message})`)
      })
      .finally(() => this.fetching.delete(provider))
  }
}

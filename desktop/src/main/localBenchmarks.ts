import fs from 'node:fs'
import path from 'node:path'
import { germanErrors, germanErrorsURL, parseGermanErrors } from '../core/localModels'

/**
 * The German error rates the local models' rows show: the Open ASR
 * Leaderboard's file, fetched when the settings ask for it and kept on disk
 * for a day, the numbers satz ships with until then and whenever it cannot.
 * Like ModelLists for the cloud providers' menus.
 */
export class GermanErrors {
  private fetching = false
  /** When it last failed: Settings is drawn again for every percent of a download, and each drawing asked anew. */
  private failed = 0

  /** @param fetcher Electron's net.fetch in the app: the system proxy and certificates. */
  constructor(private dir: string, private log: (message: string) => void, private changed: () => void, private fetcher: typeof fetch = fetch) {}

  private file() { return path.join(this.dir, 'models', 'local-german-errors.json') }

  private kept(): { fetched: number; rates: Record<string, number> } | null {
    try { return JSON.parse(fs.readFileSync(this.file(), 'utf8')) } catch { return null }
  }

  /** Error rate in percent per original model ("openai/whisper-small"). */
  get(): Record<string, number> {
    return germanErrors(this.kept()?.rates)
  }

  /** Asks again when the kept numbers are older than a day; never in the way of anything. */
  refresh() {
    if (this.fetching || Date.now() - this.failed < 10 * 60_000) return
    const kept = this.kept()
    if (kept && Date.now() - kept.fetched < 24 * 3600_000) return
    this.fetching = true
    return this.fetcher(germanErrorsURL, { signal: AbortSignal.timeout(15_000) })
      .then(async response => {
        if (!response.ok) throw new Error(`status ${response.status}`)
        const rates = parseGermanErrors(await response.text())
        if (Object.keys(rates).length === 0) throw new Error('no Whisper rows')
        fs.mkdirSync(path.dirname(this.file()), { recursive: true })
        fs.writeFileSync(this.file(), JSON.stringify({ fetched: Date.now(), rates }))
        this.log(`models: German error rates for ${Object.keys(rates).length} local models`)
        this.changed()
      })
      .catch(error => {
        this.failed = Date.now()
        this.log(`models: German error rates not fetched (${(error as Error).message})`)
      })
      .finally(() => { this.fetching = false })
  }
}

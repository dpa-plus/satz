import { fetchRelease, type Release, type UpdateFetch, type UpdateState } from '../core/updates'

/** A check belongs to the app, so reopening a window never forgets an available version. */
export class Updates {
  state: UpdateState
  private release: Release | null = null
  private pending: Promise<void> | null = null
  private checkedAt: number | null = null

  constructor(installed: string, private readonly asset: string | null, private readonly fetcher: UpdateFetch,
    private readonly changed: () => void = () => {}, private readonly now = Date.now) {
    this.state = { kind: 'idle', currentVersion: installed, checking: false, manual: false }
  }

  get downloadURL(): string | null { return this.release?.downloadURL ?? null }

  open(manual = false): Promise<void> {
    this.state = { ...this.state, manual }
    return this.check(manual)
  }

  check(manual = false): Promise<void> {
    if (manual) { this.state = { ...this.state, manual: true }; this.changed() }
    if (this.pending) return this.pending
    if (!manual && this.checkedAt !== null && this.now() - this.checkedAt < 30 * 60_000) return Promise.resolve()
    if (!this.asset) return Promise.resolve()
    this.state = { ...this.state, checking: true }
    this.changed()
    this.pending = fetchRelease(this.fetcher, this.asset, this.state.currentVersion).then(release => {
      this.release = release
      this.state = { ...this.state, kind: release ? 'available' : 'current', version: release?.version }
    }, () => {
      // Offline never hides an update already found, or opens a window of its own.
      if (!this.release) this.state = { ...this.state, kind: 'unavailable' }
    }).finally(() => {
      this.checkedAt = this.now()
      this.pending = null
      this.state = { ...this.state, checking: false }
      this.changed()
    })
    return this.pending
  }
}

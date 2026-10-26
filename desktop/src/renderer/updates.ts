import type { UpdateState } from '../core/updates'
import type { Bridge } from './bridge'

/** An inline notice never opens a window or takes focus from a dictation. */
export class UpdateNotice {
  private readonly root = document.createElement('section')
  private readonly status = document.createElement('span')
  private readonly actions = document.createElement('div')
  private readonly action = document.createElement('button')
  private readonly later = document.createElement('button')
  private state: UpdateState | null = null
  private dismissed = false
  private feedback: 'opened' | 'download-failed' | 'check-failed' | null = null
  private opening = false
  private request = 0

  constructor(private readonly bridge: Bridge, after: HTMLElement, private readonly language: () => 'de' | 'en') {
    this.root.id = 'update-notice'
    this.root.hidden = true
    this.status.className = 'update-status'
    this.status.setAttribute('role', 'status')
    this.actions.className = 'update-actions'
    this.action.className = 'compact'
    this.later.className = 'quiet'
    this.action.type = this.later.type = 'button'
    this.actions.append(this.action, this.later)
    this.root.append(this.status, this.actions)
    after.insertAdjacentElement('afterend', this.root)
    this.later.onclick = () => {
      this.dismissed = true
      this.root.hidden = true
      document.querySelector<HTMLButtonElement>('#tabs [aria-selected="true"]')?.focus()
    }
    this.action.onclick = () => { void this.act() }
    this.bridge.on('updates:changed', () => { void this.refresh() })
    void this.refresh()
  }

  opened() { this.dismissed = false; this.feedback = null; void this.refresh() }
  languageChanged() { this.render() }
  private t(de: string, en: string) { return this.language() === 'de' ? de : en }

  private async refresh() {
    const request = ++this.request
    try {
      const state = await this.bridge.invoke('updates:get') as UpdateState
      if (request !== this.request) return
      this.state = state
      this.render()
    } catch { /* The rest of the window works even if the update bridge is unavailable. */ }
  }

  private async act() {
    if (!this.state || this.opening) return
    this.feedback = null
    this.opening = true
    this.render()
    try {
      if (this.state.kind === 'available') {
        const opened = await this.bridge.invoke('updates:download')
        this.feedback = opened ? 'opened' : 'download-failed'
      } else {
        await this.bridge.invoke('updates:check')
        await this.refresh()
      }
    } catch { this.feedback = 'check-failed' }
    finally { this.opening = false; this.render() }
  }

  private render() {
    const state = this.state
    this.root.hidden = this.dismissed || !state || (state.kind !== 'available' && !state.manual)
    if (!state || this.root.hidden) return
    this.root.setAttribute('aria-label', this.t('Updates', 'Updates'))
    const available = state.kind === 'available'
    const checking = state.checking && !available
    const message = available ? this.t(`satz ${state.version} ist verfügbar.`, `satz ${state.version} is available.`)
      : checking ? this.t('Suche nach Updates…', 'Checking for updates…')
      : state.kind === 'current' ? this.t(`satz ${state.currentVersion} ist aktuell.`, `satz ${state.currentVersion} is up to date.`)
      : this.t('Updates konnten nicht geprüft werden.', 'Could not check for updates.')
    const feedback = this.feedback === 'opened' ? this.t('Download im Browser geöffnet.', 'Download opened in your browser.')
      : this.feedback === 'download-failed' ? this.t('Download konnte nicht geöffnet werden.', 'Could not open the download.')
      : this.feedback === 'check-failed' ? this.t('Updates konnten nicht geprüft werden.', 'Could not check for updates.') : ''
    this.status.textContent = feedback ? `${message} ${feedback}` : message
    this.action.textContent = available ? this.t('Herunterladen', 'Download') : this.t('Erneut prüfen', 'Check again')
    this.action.hidden = checking
    this.action.disabled = this.opening || state.checking
    this.later.textContent = this.t('Später', 'Later')
  }
}

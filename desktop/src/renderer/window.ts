import { satz } from './bridge'

/**
 * satz's one window: History and Settings as two pages. Two windows for them
 * meant a second one popping up beside the first. Ctrl+1 and Ctrl+2 switch.
 */
type Page = 'history' | 'settings'
let language: 'de' | 'en' = 'en'
let page: Page = new URLSearchParams(location.search).get('page') === 'settings' ? 'settings' : 'history'

const t = (de: string, en: string) => (language === 'de' ? de : en)

function show(next: Page) {
  page = next
  for (const name of ['history', 'settings'] as const) {
    document.getElementById(`${name}-page`)!.hidden = name !== page
    const tab = document.getElementById(`tab-${name}`)!
    tab.setAttribute('aria-selected', String(name === page))
    tab.textContent = name === 'history' ? t('Verlauf', 'History') : t('Einstellungen', 'Settings')
  }
  document.title = page === 'history' ? t('satz Verlauf', 'satz History') : t('satz Einstellungen', 'satz Settings')
}

Array.from(document.querySelectorAll<HTMLButtonElement>('#tabs button')).forEach(tab => { tab.onclick = () => show(tab.dataset.page as Page) })
document.addEventListener('keydown', event => {
  if (!(event.ctrlKey || event.metaKey)) return
  if (event.key === '1') show('history')
  if (event.key === '2') show('settings')
})
satz.on('window:page', (next: Page) => show(next))
// The settings page says when the language changed.
// The document's language too, for screen readers.
document.addEventListener('satz-language', event => { language = (event as CustomEvent).detail; document.documentElement.lang = language; show(page) })
satz.invoke('settings:get').then(info => { language = info.prefs.language; document.documentElement.lang = language; show(page) })
show(page)

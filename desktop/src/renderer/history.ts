import { satz } from './bridge'

/**
 * Everything dictated, newest first, by day. What opens when satz is started
 * again from the app menu. Search narrows it, a click copies, × forgets one.
 */
interface Entry { id: string; text: string; date: string; pasted: boolean }
interface Info { entries: Entry[]; limit: number; language: 'de' | 'en' }

const KEEP_ALL = 100_000
const app = document.getElementById('app')!
let info: Info
let query = ''
let copiedId: string | null = null

const t = (de: string, en: string) => (info?.language === 'de' ? de : en)

function el<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...children: (Node | string)[]): HTMLElementTagNameMap[K] {
  const node = Object.assign(document.createElement(tag), props)
  node.append(...children)
  return node
}

function dayTitle(date: Date): string {
  const start = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  const days = Math.round((start(new Date()) - start(date)) / 86_400_000)
  if (days === 0) return t('Heute', 'Today')
  if (days === 1) return t('Gestern', 'Yesterday')
  return date.toLocaleDateString(info.language, { weekday: 'long', day: 'numeric', month: 'long' })
}

function row(entry: Entry): HTMLElement {
  const time = new Date(entry.date).toLocaleTimeString(info.language, { hour: '2-digit', minute: '2-digit' })
  const meta = entry.id === copiedId ? t('Kopiert', 'Copied') : `${entry.pasted ? t('Eingefügt', 'Pasted') : t('Zwischenablage', 'Clipboard')} · ${time}`
  const copy = el('button', { className: 'copy', title: t('Kopieren', 'Copy') },
    el('span', { className: 'text', textContent: entry.text }),
    el('span', { className: 'meta', textContent: meta }))
  copy.onclick = async () => {
    await satz.invoke('history:copy', entry.text)
    copiedId = entry.id
    render()
    setTimeout(() => { if (copiedId === entry.id) { copiedId = null; render() } }, 1200)
  }
  const remove = el('button', { className: 'remove', textContent: '×', title: t('Aus dem Verlauf entfernen', 'Remove from history') })
  remove.setAttribute('aria-label', t('Aus dem Verlauf entfernen', 'Remove from history'))
  remove.onclick = () => satz.invoke('history:remove', entry.id)
  return el('div', { className: 'entry' }, copy, remove)
}

function render() {
  document.title = t('satz Verlauf', 'satz History')
  const settings = el('button', { textContent: t('Einstellungen', 'Settings') })
  settings.onclick = () => satz.invoke('history:open-settings')
  const children: Node[] = [el('header', {}, el('h1', { textContent: t('Verlauf', 'History') }), settings)]

  if (info.entries.length > 0) {
    // Kept when the page is drawn again, with the cursor where it was.
    const search = el('input', { type: 'text', id: 'search', className: 'search', placeholder: t('Suchen', 'Search'), value: query })
    search.oninput = () => { query = search.value; render() }
    search.onkeydown = e => { if (e.key === 'Escape' && query) { query = ''; render() } }
    children.push(search)
  }

  const words = query.trim().toLowerCase()
  const shown = words ? info.entries.filter(e => e.text.toLowerCase().includes(words)) : info.entries
  if (info.limit === 0 && info.entries.length === 0) {
    children.push(el('p', { className: 'quiet', textContent: t('Der Verlauf ist aus. In den Einstellungen lässt er sich wieder einschalten.', 'History is off. It can be switched back on in Settings.') }))
  } else if (info.entries.length === 0) {
    children.push(el('p', { className: 'quiet', textContent: t('Noch nichts diktiert. Rechte Strg-Taste zweimal tippen und sprechen.', 'Nothing dictated yet. Tap right Ctrl twice and talk.') }))
  } else if (shown.length === 0) {
    children.push(el('p', { className: 'quiet', textContent: t(`Nichts gefunden für „${query}“.`, `Nothing found for “${query}”.`) }))
  } else {
    const list = el('div', { className: 'list' })
    let day: HTMLElement | null = null
    let title = ''
    for (const entry of shown) {
      const next = dayTitle(new Date(entry.date))
      if (next !== title || !day) {
        title = next
        day = el('div', { className: 'box' })
        list.append(el('section', { className: 'day' }, el('h2', { textContent: title }), day))
      }
      day.append(row(entry))
    }
    children.push(list)
  }
  if (info.limit > 0) {
    children.push(el('footer', { textContent: info.limit >= KEEP_ALL
      ? t('Alles wird behalten. Ändern in den Einstellungen.', 'Everything is kept. Change it in Settings.')
      : t(`Die letzten ${info.limit} werden behalten. Ändern in den Einstellungen.`, `The last ${info.limit} are kept. Change it in Settings.`) }))
  }

  const focused = (document.activeElement as HTMLInputElement | null)
  const caret = focused?.id === 'search' ? focused.selectionStart : null
  const scroll = app.querySelector('.list')?.scrollTop ?? 0
  app.replaceChildren(...children)
  const list = app.querySelector('.list')
  if (list) list.scrollTop = scroll
  if (caret !== null) {
    const search = document.getElementById('search') as HTMLInputElement | null
    search?.focus()
    search?.setSelectionRange(caret, caret)
  }
}

async function load() {
  info = await satz.invoke('history:get')
  render()
}

satz.on('history:changed', load)
load()

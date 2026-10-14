import { satz } from './bridge'
import { KEEP_ALL } from '../core/historyLimits'

/**
 * Everything dictated, newest first, by day. What opens when satz is started
 * again from the app menu. Search narrows it, a click copies, × forgets one.
 */

/** The same icons as the Mac's: two sheets for copy, a tick once copied. */
const COPY_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5.5" y="5.5" width="8" height="8" rx="1.6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M10.5 5.5V4.1A1.6 1.6 0 0 0 8.9 2.5H4.1A1.6 1.6 0 0 0 2.5 4.1v4.8a1.6 1.6 0 0 0 1.6 1.6h1.4" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>'
const COPIED_ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3.5 8.5 3 3 6-7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>'
/** `original`: as said, where cleanup changed it; `cleanup`: "ok" or why it failed, while cleanup was on. */
interface Entry { id: string; text: string; date: string; pasted: boolean; original?: string; cleanup?: string }
interface Info { entries: Entry[]; limit: number; language: 'de' | 'en' }

const app = document.getElementById('history-page')!
let info: Info
let query = ''
let copiedId: string | null = null
/** The rows showing the text as it was said instead of the cleaned one. */
const showsOriginal = new Set<string>()

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
  // The row copies what it shows: the cleaned text, or the original once swapped.
  const original = entry.original !== undefined && showsOriginal.has(entry.id)
  const shown = original ? entry.original! : entry.text
  const failed = entry.cleanup !== undefined && entry.cleanup !== 'ok'
  const copy = el('button', { className: 'copy', title: t('Kopieren', 'Copy') },
    el('span', { className: 'text', textContent: shown }),
    ...(failed ? [el('span', { className: 'cleanup-note', textContent: t(`Nicht aufgeräumt: ${entry.cleanup}`, `Not cleaned up: ${entry.cleanup}`) })] : []),
    el('span', { className: 'meta', textContent: meta }))
  copy.onclick = async () => {
    await satz.invoke('history:copy', shown)
    copiedId = entry.id
    render()
    setTimeout(() => { if (copiedId === entry.id) { copiedId = null; render() } }, 1200)
  }
  const remove = el('button', { className: 'remove', textContent: '×', title: t('Aus dem Verlauf entfernen', 'Remove from history') })
  remove.setAttribute('aria-label', t('Aus dem Verlauf entfernen', 'Remove from history'))
  remove.onclick = () => satz.invoke('history:remove', entry.id)
  // Says what a click on the row does. The row is the button for the
  // keyboard and screen readers, so this one is skipped by both.
  const icon = el('button', { className: 'copy-icon', title: t('Kopieren', 'Copy'), tabIndex: -1,
    innerHTML: entry.id === copiedId ? COPIED_ICON : COPY_ICON })
  icon.setAttribute('aria-hidden', 'true')
  icon.onclick = () => copy.click()
  if (entry.original === undefined) return el('div', { className: 'entry' }, copy, remove, icon)
  const swap = el('button', { className: 'swap', textContent: original ? t('Aufgeräumt', 'Cleaned up') : 'Original',
    title: original ? t('Den aufgeräumten Text zeigen', 'Show the cleaned-up text') : t('Den Text zeigen, wie er gesagt wurde', 'Show the text as it was said') })
  swap.onclick = () => {
    if (original) showsOriginal.delete(entry.id); else showsOriginal.add(entry.id)
    render()
  }
  return el('div', { className: 'entry' }, copy, swap, remove, icon)
}

function render() {
  const children: Node[] = []

  if (info.entries.length > 0) {
    // Kept when the page is drawn again, with the cursor where it was.
    const search = el('input', { type: 'text', id: 'search', className: 'search', placeholder: t('Suchen', 'Search'), value: query })
    // Not while an input method is composing (Pinyin): redrawn then, the
    // field kept the letters typed so far next to the character chosen.
    search.oninput = event => { if ((event as InputEvent).isComposing) return; query = search.value; render() }
    search.addEventListener('compositionend', () => { query = search.value; render() })
    search.onkeydown = e => { if (e.key === 'Escape' && query) { query = ''; render() } }
    children.push(search)
  }

  const words = query.trim().toLowerCase()
  const shown = words ? info.entries.filter(e => e.text.toLowerCase().includes(words) || e.original?.toLowerCase().includes(words)) : info.entries
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
// The language is set on the settings page, in the same window.
document.addEventListener('satz-language', () => load())
load()

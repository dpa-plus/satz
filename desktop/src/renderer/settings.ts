import { satz } from './bridge'

/**
 * Settings: the provider and its key, the vocabulary, the Ersetzungen with
 * their spoken language, the shortcut mode, language and start at login.
 * Rebuilt from scratch on every change: it is a short page.
 */
type Provider = 'openai' | 'openrouter' | 'groq' | 'custom'
interface Replacement { id: string; spoken: string; written: string; isOn: boolean }
interface Info {
  prefs: {
    provider: Provider; models: Record<string, string>; customBaseURL: string; words: string[]; triggerMode: 'tap' | 'hold'
    language: 'de' | 'en'; spokenLanguage: 'de' | 'en' | null; replacements: Replacement[]; usesReplacements: boolean; removesFillers: boolean
  }
  hasKey: boolean; keyboard: string; wayland: boolean; platform: string; startAtLogin: boolean; spokenLanguage: 'de' | 'en'
}

const app = document.getElementById('app')!
let info: Info
let editingKey = false
let keyProblem = ''

const t = (de: string, en: string) => (info.prefs.language === 'de' ? de : en)
const defaults: Record<Provider, string> = { openai: 'gpt-transcribe', openrouter: 'microsoft/mai-transcribe-2', groq: 'whisper-large-v3-turbo', custom: '' }
const shown = (written: string) => (written === '\n' ? '↵' : written === '\n\n' ? '¶' : written)

function el<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, unknown> = {}, ...children: (Node | string)[]): HTMLElementTagNameMap[K] {
  const node = Object.assign(document.createElement(tag), props)
  node.append(...children)
  return node
}

async function update(change: Partial<Info['prefs']>) {
  await satz.invoke('settings:update', change)
  await load()
}

function section(title: string, ...children: Node[]) {
  return el('section', {}, el('h2', { textContent: title }), ...children)
}

function select<T extends string>(value: T, options: [T, string][], onChange: (v: T) => void) {
  const s = el('select')
  for (const [v, label] of options) s.append(el('option', { value: v, textContent: label, selected: v === value }))
  s.onchange = () => onChange(s.value as T)
  return s
}

function render() {
  const p = info.prefs
  document.title = t('satz Einstellungen', 'satz Settings')

  // Shortcut
  const shortcut = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: p.triggerMode === 'tap'
      ? t('Rechte Strg-Taste zweimal tippen: starten, nochmal: einfügen', 'Tap right Ctrl twice to start, again to paste')
      : t('Rechte Strg-Taste zweimal tippen und halten: sprechen, loslassen: einfügen', 'Tap right Ctrl twice and hold to talk, let go to paste') }),
      select(p.triggerMode, [['tap', t('Tippen', 'Tap')], ['hold', t('Halten', 'Hold')]], v => update({ triggerMode: v }))))
  // Only worth a line when something is missing.
  const shortcutHint = el('div', { className: 'hint', textContent: '' })
  if (info.wayland && info.keyboard?.startsWith('Wayland')) {
    shortcutHint.textContent = t(
      'Wayland lässt Apps die Tastatur nicht mitlesen. Entweder in den System-Einstellungen eine Tastenkombination anlegen, die „satz --toggle“ ausführt, oder einmal „sudo usermod -aG input $USER“ ausführen und neu anmelden.',
      'Wayland does not let apps watch the keyboard. Either add a keyboard shortcut in the system settings that runs "satz --toggle", or run "sudo usermod -aG input $USER" once and sign in again.')
  }

  // Provider and key
  const keyRow = el('div', { className: 'row' })
  if (editingKey || !info.hasKey) {
    const input = el('input', { type: 'password', className: 'grow', placeholder: p.provider === 'openrouter' ? 'sk-or-…' : p.provider === 'groq' ? 'gsk_…' : 'sk-…' })
    const save = el('button', { className: 'accent', textContent: t('Sichern', 'Save') })
    const commit = async () => {
      if (!input.value.trim()) return
      const ok = await satz.invoke('settings:store-key', input.value)
      keyProblem = ok ? '' : t('Konnte nicht gesichert werden.', 'Could not be saved.')
      editingKey = false
      await load()
    }
    save.onclick = commit
    input.onkeydown = e => { if (e.key === 'Enter') commit(); if (e.key === 'Escape' && info.hasKey) { editingKey = false; render() } }
    keyRow.append(el('span', { textContent: t('Schlüssel', 'Key') }), input, save)
    if (info.hasKey) { const cancel = el('button', { textContent: '×', title: t('Abbrechen', 'Cancel') }); cancel.onclick = () => { editingKey = false; render() }; keyRow.append(cancel) }
    setTimeout(() => input.focus())
  } else {
    const change = el('button', { textContent: t('Ändern', 'Change') })
    change.onclick = () => { editingKey = true; render() }
    keyRow.append(el('span', { className: 'grow', textContent: t('Schlüssel gesichert', 'Key saved') }), change)
  }
  const model = el('input', { type: 'text', className: 'grow', value: p.models[p.provider] ?? '', placeholder: defaults[p.provider] })
  model.onchange = () => update({ models: { ...p.models, [p.provider]: model.value.trim() } })
  const providerBox = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Anbieter', 'Provider') }),
      select(p.provider, [['openrouter', 'OpenRouter'], ['openai', 'OpenAI'], ['groq', 'Groq'], ['custom', t('Eigener', 'Custom')]], v => { editingKey = false; update({ provider: v }) })),
    keyRow,
    el('div', { className: 'row' }, el('span', { textContent: t('Modell', 'Model') }), model))
  if (p.provider === 'custom') {
    const url = el('input', { type: 'text', className: 'grow', value: p.customBaseURL, placeholder: 'https://…/v1' })
    url.onchange = () => update({ customBaseURL: url.value.trim() })
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Adresse', 'Address') }), url))
  }
  if (p.provider === 'openrouter') {
    const box = el('input', { type: 'checkbox', checked: p.removesFillers })
    box.onchange = () => update({ removesFillers: box.checked })
    providerBox.append(el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Füllwörter weglassen', 'Remove filler words'), box)))
  }

  // Vocabulary
  const words = el('div', { className: 'chips' })
  for (const word of p.words) {
    const remove = el('button', { textContent: '×' })
    remove.onclick = () => update({ words: p.words.filter(w => w !== word) })
    words.append(el('span', { className: 'chip' }, word, remove))
  }
  const newWord = el('input', { type: 'text', placeholder: t('+ Wort', '+ Word') })
  newWord.onkeydown = e => {
    if (e.key === 'Enter' && newWord.value.trim() && !p.words.some(w => w.toLowerCase() === newWord.value.trim().toLowerCase())) update({ words: [...p.words, newWord.value.trim()] })
    if (e.key === 'Escape') newWord.value = ''
  }
  words.append(newWord)

  // Ersetzungen
  const useBox = el('input', { type: 'checkbox', checked: p.usesReplacements })
  useBox.onchange = () => update({ usesReplacements: useBox.checked })
  const replacementBox = el('div', { className: 'box' }, el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Gesprochene Zeichen ersetzen', 'Replace spoken symbols'), useBox)))
  if (p.usesReplacements) {
    replacementBox.append(el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Gesprochen auf', 'Spoken in') }),
      select(info.spokenLanguage, [['de', 'Deutsch'], ['en', 'English']], v => update({ spokenLanguage: v }))))
    const chips = el('div', { className: 'chips' })
    for (const rule of p.replacements.filter(r => r.isOn)) {
      const remove = el('button', { textContent: '×' })
      remove.onclick = () => update({ replacements: p.replacements.filter(r => r.id !== rule.id) })
      chips.append(el('span', { className: 'chip' }, `${rule.spoken} → `, el('code', { textContent: shown(rule.written) }), remove))
    }
    const spoken = el('input', { type: 'text', placeholder: t('gesprochen', 'spoken') })
    const written = el('input', { type: 'text', placeholder: t('wird zu', 'becomes'), size: 6 })
    const add = el('button', { textContent: '+' })
    add.onclick = () => {
      if (!spoken.value.trim() || !written.value) return
      update({ replacements: [...p.replacements, { id: `u${Date.now()}`, spoken: spoken.value.trim(), written: written.value, isOn: true }] })
    }
    chips.append(spoken, written, add)
    replacementBox.append(chips)
  }

  // General
  const startBox = el('input', { type: 'checkbox', checked: info.startAtLogin })
  startBox.onchange = async () => { await satz.invoke('settings:start-at-login', startBox.checked); await load() }
  const clear = el('button', { textContent: t('Leeren', 'Clear') })
  clear.onclick = () => satz.invoke('settings:clear-history')
  const general = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Sprache', 'Language') }),
      select(p.language, [['de', 'Deutsch'], ['en', 'English']], v => update({ language: v }))),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Beim Anmelden starten', 'Start at login'), startBox)),
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Verlauf', 'History') }), clear))

  app.replaceChildren(
    el('h1', { textContent: t('Einstellungen', 'Settings') }),
    section(t('Kurzbefehl', 'Shortcut'), shortcut, shortcutHint),
    section(t('Anbieter', 'Provider'), providerBox, ...(keyProblem ? [el('div', { className: 'error', textContent: keyProblem })] : [])),
    section(t('Wortschatz', 'Vocabulary'), el('div', { className: 'box' }, words)),
    section(t('Ersetzungen', 'Replacements'), replacementBox),
    section(t('Allgemein', 'General'), general),
  )
}

async function load() {
  info = await satz.invoke('settings:get')
  render()
}

load()

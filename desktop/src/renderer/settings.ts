import { satz } from './bridge'
import { choiceFor, type ModelChoice } from '../core/models'

/**
 * Settings: the provider and its key, the vocabulary, the Ersetzungen with
 * their spoken language, the shortcut mode, language and start at login.
 * Rebuilt from scratch on every change: it is a short page.
 */
type Provider = 'openai' | 'openrouter' | 'groq' | 'custom' | 'local'
type LocalState = { kind: 'missing' | 'preparing' | 'ready' } | { kind: 'downloading'; fraction: number } | { kind: 'failed'; message: string }
interface Replacement { id: string; spoken: string; written: string; isOn: boolean }
interface Info {
  prefs: {
    provider: Provider; models: Record<string, string>; customBaseURL: string; words: string[]; triggerMode: 'tap' | 'hold'
    language: 'de' | 'en'; spokenLanguage: 'de' | 'en' | null; replacements: Replacement[]; usesReplacements: boolean; removesFillers: boolean
    keepsOnClipboard: boolean; historyLimit: number; pausesMedia: boolean
  }
  hasKey: boolean; keyboard: string; wayland: boolean; platform: string; startAtLogin: boolean; spokenLanguage: 'de' | 'en'
  /** The provider's live list, or the shipped one until it arrives. */
  models: ModelChoice[]
  /** The local model chosen, whether it is on this computer, and how big it is. */
  local: { state: LocalState; size: string | null }
}

const app = document.getElementById('settings-page')!
let info: Info
let editingKey = false
let keyProblem = ''
/** Focus the key field: on the first look without a key, and after "Change". */
let wantsKeyFocus = true
/** "Other model" was chosen: the field for typing an id stays open. */
let typingModel = false
/** Select the id once the field is drawn, so typing replaces it. */
let selectModelId = false
/** The field to put the cursor in after the next drawing, by id. */
let focusNext: string | null = null

const t = (de: string, en: string) => (info.prefs.language === 'de' ? de : en)
const defaults: Record<Provider, string> = { openai: 'gpt-transcribe', openrouter: 'microsoft/mai-transcribe-2', groq: 'whisper-large-v3-turbo', custom: '', local: 'onnx-community/whisper-large-v3-turbo' }
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

/** `label` names the menu for screen readers, which otherwise read only its value. */
function select<T extends string>(value: T, options: [T, string][], onChange: (v: T) => void, label?: string) {
  const s = el('select')
  if (label) s.setAttribute('aria-label', label)
  for (const [v, label] of options) s.append(el('option', { value: v, textContent: label, selected: v === value }))
  s.onchange = () => onChange(s.value as T)
  return s
}

function render() {
  const p = info.prefs

  // Shortcut
  const shortcut = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: p.triggerMode === 'tap'
      ? t('Rechte Strg-Taste zweimal tippen: starten, nochmal: einfügen', 'Tap right Ctrl twice to start, again to paste')
      : t('Rechte Strg-Taste zweimal tippen und halten: sprechen, loslassen: einfügen', 'Tap right Ctrl twice and hold to talk, let go to paste') }),
      select(p.triggerMode, [['tap', t('Tippen', 'Tap')], ['hold', t('Halten', 'Hold')]], v => update({ triggerMode: v }), t('Tippen oder halten', 'Tap or hold'))))
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
    const input = el('input', { type: 'password', id: 'key', className: 'grow', placeholder: p.provider === 'openrouter' ? 'sk-or-…' : p.provider === 'groq' ? 'gsk_…' : 'sk-…' })
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
    // Only when asked for: on every drawing it took the cursor out of
    // whatever field the user was typing in.
    if (wantsKeyFocus) { wantsKeyFocus = false; focusNext = 'key' }
  } else {
    const change = el('button', { textContent: t('Ändern', 'Change') })
    change.onclick = () => { editingKey = true; wantsKeyFocus = true; render() }
    keyRow.append(el('span', { className: 'grow', textContent: t('Schlüssel gesichert', 'Key saved') }), change)
  }
  // A menu of what the provider offers now, best first, with how many words
  // each gets wrong and what an hour costs, and "Other" for one typed in by
  // hand: a plain text field let one stray keystroke break every dictation.
  const currentModel = p.models[p.provider] || defaults[p.provider]
  const modelField = el('input', { type: 'text', id: 'model', className: 'grow', value: p.models[p.provider] ?? '', placeholder: defaults[p.provider] })
  // Saved on Return, or quietly when the field is left: drawing the page
  // again right then closed the model menu the user had just opened.
  const saveModel = (redraw: boolean) => {
    const id = modelField.value.trim()
    typingModel = false
    if (redraw) update({ models: { ...p.models, [p.provider]: id } })
    else satz.invoke('settings:update', { models: { ...p.models, [p.provider]: id } }).then(next => { info.prefs = next })
  }
  modelField.onchange = () => saveModel(false)
  modelField.onkeydown = event => {
    if (event.key === 'Enter') saveModel(true)
    // Escape keeps the model there was. The old id goes back first: the field
    // closing counts as leaving it, which saved the half-typed one.
    if (event.key === 'Escape') { modelField.value = p.models[p.provider] ?? ''; typingModel = false; render() }
  }
  const modelMenu = el('select', { id: 'model-menu', className: 'grow' })
  modelMenu.setAttribute('aria-label', t('Modell', 'Model'))
  const number = (value: number, digits: number) => value.toLocaleString(p.language === 'de' ? 'de-DE' : 'en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })
  const title = (model: ModelChoice) => [
    `${model.name} · ${model.maker}`,
    ...(model.errorRate === undefined ? [] : [t(`${number(model.errorRate, 1)} % Fehler`, `${number(model.errorRate, 1)} % errors`)]),
    ...(model.dollarsPerHour === undefined ? [] : model.dollarsPerHour === 0 ? [t('kostenlos', 'free')]
      : [t(`${number(model.dollarsPerHour, 2)} $ pro Stunde`, `$${number(model.dollarsPerHour, 2)} an hour`)]),
  ].join(' · ')
  for (const model of info.models) modelMenu.append(el('option', { value: model.id, textContent: title(model) }))
  modelMenu.append(el('option', { value: '', textContent: t('Anderes Modell …', 'Other model …') }))
  const chosen = choiceFor(info.models, currentModel)
  const known = chosen !== undefined
  const facts = el('div', { className: 'hint', textContent: !chosen ? t('Ein Modell, das nicht in der Liste steht.', 'A model that is not in the list.')
    : p.provider === 'local' ? t('Läuft auf diesem Computer, ohne Internet und kostenlos. Erkennt Deutsch und Englisch von selbst.',
      'Runs on this computer, offline and free. Tells German from English by itself.') : [
    chosen.errorRate === undefined ? t('Noch ohne Fehlerquote von Artificial Analysis', 'No error rate from Artificial Analysis yet')
      : t(`${number(chosen.errorRate, 1)} % falsche Wörter laut Artificial Analysis`, `${number(chosen.errorRate, 1)} % wrong words per Artificial Analysis`),
    ...(chosen.dollarsPerHour === undefined ? [] : [t(`${number(chosen.dollarsPerHour, 2)} $ pro Stunde Sprechen`, `$${number(chosen.dollarsPerHour, 2)} per hour of talking`)]),
  ].join(', ') })
  modelMenu.value = known && !typingModel ? currentModel : ''
  modelMenu.onchange = () => {
    if (!modelMenu.value) { typingModel = true; selectModelId = true; focusNext = 'model'; render(); return }
    typingModel = false
    update({ models: { ...p.models, [p.provider]: modelMenu.value } })
  }
  const showsModelField = p.provider === 'custom' || typingModel || !known
  const providerBox = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Anbieter', 'Provider') }),
      select(p.provider, [['openrouter', 'OpenRouter'], ['openai', 'OpenAI'], ['groq', 'Groq'], ['custom', t('Eigener', 'Custom')], ['local', t('Lokal', 'Local')]], v => { editingKey = false; typingModel = false; update({ provider: v }) }, t('Anbieter', 'Provider'))),
    // Nothing to paste for a model on this computer: it is downloaded instead.
    ...(p.provider === 'local' ? [] : [keyRow]),
    ...(p.provider === 'custom' ? [] : [el('div', { className: 'row' }, el('span', { textContent: t('Modell', 'Model') }), modelMenu), facts]),
    ...(p.provider === 'local' ? [localRow()] : []),
    ...(showsModelField ? [el('div', { className: 'row' }, el('span', { textContent: p.provider === 'custom' ? t('Modell', 'Model') : t('Modell-ID', 'Model ID') }), modelField)] : []))
  if (p.provider === 'custom') {
    const url = el('input', { type: 'text', id: 'custom-url', className: 'grow', value: p.customBaseURL, placeholder: 'https://…/v1' })
    url.onchange = () => update({ customBaseURL: url.value.trim() })
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Adresse', 'Address') }), url))
  }
  // Only MAI-Transcribe has a clean mode; elsewhere the switch would do nothing.
  if (currentModel.includes('mai-transcribe')) {
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
  const newWord = el('input', { type: 'text', id: 'new-word', placeholder: t('+ Wort', '+ Word') })
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
      select(info.spokenLanguage, [['de', 'Deutsch'], ['en', 'English']], v => update({ spokenLanguage: v }), t('Gesprochen auf', 'Spoken in'))))
    const chips = el('div', { className: 'chips' })
    for (const rule of p.replacements.filter(r => r.isOn)) {
      const remove = el('button', { textContent: '×' })
      remove.onclick = () => update({ replacements: p.replacements.filter(r => r.id !== rule.id) })
      chips.append(el('span', { className: 'chip' }, `${rule.spoken} → `, el('code', { textContent: shown(rule.written) }), remove))
    }
    const spoken = el('input', { type: 'text', id: 'new-spoken', placeholder: t('gesprochen', 'spoken') })
    const written = el('input', { type: 'text', id: 'new-written', placeholder: t('wird zu', 'becomes'), size: 6 })
    const add = el('button', { textContent: '+' })
    add.onclick = () => {
      if (!spoken.value.trim() || !written.value) return
      focusNext = 'new-spoken'
      update({ replacements: [...p.replacements, { id: `u${Date.now()}`, spoken: spoken.value.trim(), written: written.value, isOn: true }] })
    }
    written.onkeydown = e => { if (e.key === 'Enter') add.click() }
    chips.append(spoken, written, add)
    replacementBox.append(chips)
  }

  // General
  const startBox = el('input', { type: 'checkbox', checked: info.startAtLogin })
  startBox.onchange = async () => { await satz.invoke('settings:start-at-login', startBox.checked); await load() }
  const mediaBox = el('input', { type: 'checkbox', checked: p.pausesMedia })
  mediaBox.onchange = () => update({ pausesMedia: mediaBox.checked })
  // Off: whatever was copied before comes back after pasting.
  const keepBox = el('input', { type: 'checkbox', checked: p.keepsOnClipboard })
  keepBox.onchange = () => update({ keepsOnClipboard: keepBox.checked })
  // Deleting history asks first: one click on "Off" took every dictation.
  // Counted when asked: this page is not drawn again for every dictation.
  const count = async () => ((await satz.invoke('history:get')).entries as unknown[]).length
  const clear = el('button', { textContent: t('Leeren', 'Clear') })
  clear.onclick = async () => {
    const all = await count()
    if (all > 0 && confirm(t(`Alle ${all} Diktate aus dem Verlauf löschen? Das lässt sich nicht rückgängig machen.`, `Delete all ${all} dictations from the history? This cannot be undone.`)))
      satz.invoke('settings:clear-history')
  }
  const keep = select(String(p.historyLimit ?? 50), [['0', t('Aus', 'Off')], ['10', '10'], ['50', '50'], ['200', '200'], ['100000', t('Alle', 'All')]],
    async v => {
      const limit = Number(v)
      const all = await count()
      const gone = all - limit
      if (gone > 0 && !confirm(limit === 0
        ? t(`Alle ${all} Diktate aus dem Verlauf löschen? Das lässt sich nicht rückgängig machen.`, `Delete all ${all} dictations from the history? This cannot be undone.`)
        : t(`Die ältesten ${gone} Diktate löschen? Das lässt sich nicht rückgängig machen.`, `Delete the oldest ${gone} dictations? This cannot be undone.`))) { render(); return }
      satz.invoke('history:set-limit', limit).then(load)
    })
  keep.id = 'history-limit'
  keep.setAttribute('aria-label', t('Verlauf behalten', 'Keep history'))
  const show = el('button', { textContent: t('Ansehen', 'Show') })
  show.onclick = () => satz.invoke('history:open')
  const general = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Sprache', 'Language') }),
      select(p.language, [['de', 'Deutsch'], ['en', 'English']], v => update({ language: v }), t('Sprache', 'Language'))),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Beim Anmelden starten', 'Start at login'), startBox)),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Musik beim Diktieren pausieren', 'Pause music while dictating'), mediaBox)),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Text in der Zwischenablage behalten', 'Keep text on the clipboard'), keepBox)),
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Verlauf behalten', 'Keep history') }), keep, show, clear))

  // The page is drawn anew after every change; the cursor stays in the field
  // it was in, so several words can be typed one after the other.
  const focused = (document.activeElement as HTMLElement | null)?.id || null
  app.replaceChildren(
    section(t('Kurzbefehl', 'Shortcut'), shortcut, shortcutHint),
    section(t('Anbieter', 'Provider'), providerBox, ...(keyProblem ? [el('div', { className: 'error', textContent: keyProblem })] : [])),
    section(t('Wortschatz', 'Vocabulary'), el('div', { className: 'box' }, words)),
    section(t('Ersetzungen', 'Replacements'), replacementBox),
    section(t('Allgemein', 'General'), general),
  )
  const target = focusNext ?? focused
  focusNext = null
  const field = target ? document.getElementById(target) as HTMLInputElement | null : null
  field?.focus()
  if (selectModelId && target === 'model') field?.select()
  selectModelId = false
}

/** Whether the local model is on this computer, and the one button that changes that. */
function localRow() {
  const { state, size } = info.local
  const row = el('div', { className: 'row', id: 'local-row' })
  const sized = (de: string, en: string) => t(size ? `${de}, ${size}` : de, size ? `${en}, ${size}` : en)
  switch (state.kind) {
    case 'ready': {
      const remove = el('button', { textContent: t('Entfernen', 'Remove'), title: t('Legt das Modell in den Papierkorb', 'Moves the model to the trash') })
      remove.onclick = () => satz.invoke('local:remove').then(load)
      row.append(el('span', { className: 'grow', textContent: `✓ ${sized('Auf diesem Computer', 'On this computer')}` }), remove)
      break
    }
    case 'missing': {
      const download = el('button', { className: 'accent', textContent: sized('Laden', 'Download') })
      download.onclick = () => satz.invoke('local:download').then(load)
      row.append(el('span', { className: 'grow', textContent: t('Noch nicht auf diesem Computer', 'Not on this computer yet') }), download)
      break
    }
    case 'downloading': {
      const bar = el('progress', { value: state.fraction, max: 1 })
      bar.setAttribute('aria-label', t('Fortschritt', 'Progress'))
      row.append(el('span', { className: 'grow', textContent: t('Wird geladen', 'Downloading') }), bar,
        el('span', { className: 'percent', textContent: `${Math.floor(state.fraction * 100)} %` }))
      break
    }
    case 'preparing':
      row.append(el('span', { className: 'grow', textContent: t('Wird für diesen Computer vorbereitet …', 'Getting ready for this computer …') }))
      break
    case 'failed': {
      const retry = el('button', { textContent: t('Nochmal', 'Try again') })
      retry.onclick = () => satz.invoke('local:download').then(load)
      row.append(el('span', { className: 'grow', textContent: t('Laden fehlgeschlagen', 'Download failed'), title: state.message }), retry)
      break
    }
  }
  return row
}

async function load() {
  info = await satz.invoke('settings:get')
  document.dispatchEvent(new CustomEvent('satz-language', { detail: info.prefs.language }))
  render()
}

// A new model list draws the page again, but not under someone typing: that
// emptied a half-typed word. It waits until the field is left.
function loadWhenFree() {
  const field = document.activeElement
  if (field instanceof HTMLInputElement && field.type !== 'checkbox' && field.closest('#settings-page')) {
    field.addEventListener('blur', () => load(), { once: true })
  } else load()
}
satz.on('models:changed', loadWhenFree)
satz.on('local:changed', loadWhenFree)
load()

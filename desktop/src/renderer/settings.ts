import { satz } from './bridge'
import { formatSize, languageLine, languageName, localModel, measuredHere, modelBars, toldLanguage, type Speed } from '../core/localModels'
import { choiceFor, type ModelChoice } from '../core/models'
import { localRowAction, providerLabel, providerOrder, shortcutHint, switchRow, useLocalModel } from '../core/browse'
import { HISTORY_LIMITS, KEEP_ALL } from '../core/historyLimits'
import { LoadAfterBlur } from './deferredLoad'

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
    language: 'de' | 'en'; spokenLanguage: 'de' | 'en' | null; toldLanguage?: string | null; replacements: Replacement[]; usesReplacements: boolean; removesFillers: boolean
    keepsOnClipboard: boolean; historyLimit: number; pausesMedia: boolean
  }
  /** The provider the page shows, which `hasKey` and `models` are about; dictations go to `prefs.provider`. */
  shown: Provider
  hasKey: boolean; wayland: boolean; platform: string; startAtLogin: boolean; spokenLanguage: 'de' | 'en'
  /** False where right Ctrl cannot start a dictation, so only "satz --toggle" does; missing counts as working. */
  shortcutWorks?: boolean
  /** The shown provider's live list, or the shipped one until it arrives. */
  models: ModelChoice[]
  /** The models for "Lokal", one card each, and the one in use. */
  local: {
    inUse: string
    models: { id: string; state: LocalState; measuring: boolean; speed: Speed | null }[]
    /** German error rate per original model, today's or the shipped one. */
    germanErrors: Record<string, number>
    /** This computer and satz, to tell a speed measured here from one brought along. */
    machine: string; version: string
  }
}

const app = document.getElementById('settings-page')!
let info: Info
/**
 * The provider the page shows, the page's own: looking at one is not using
 * it (core/browse.ts). Null until the first answer, and again whenever the
 * page is opened, so it starts at the provider in use.
 */
let shownProvider: Provider | null = null
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
/** `id` lets focus come back to the menu after the page is drawn again. */
function select<T extends string>(value: T, options: [T, string][], onChange: (v: T) => void, label?: string, id?: string) {
  const s = el('select')
  if (id) s.id = id
  if (label) s.setAttribute('aria-label', label)
  for (const [v, label] of options) s.append(el('option', { value: v, textContent: label, selected: v === value }))
  s.onchange = () => onChange(s.value as T)
  return s
}

function render() {
  const p = info.prefs
  // Everything in the provider box is about the provider shown, and is kept for it.
  const provider = info.shown
  // Local models are a list to choose from, each with its size, speed and
  // errors: nothing to paste (they are downloaded) and no id to type (an id
  // satz cannot run downloaded fine and then failed every dictation).
  const isLocal = provider === 'local'

  // Shortcut
  const shortcut = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: p.triggerMode === 'tap'
      ? t('Rechte Strg-Taste zweimal tippen: starten, nochmal: einfügen', 'Tap right Ctrl twice to start, again to paste')
      : t('Rechte Strg-Taste zweimal tippen und halten: sprechen, loslassen: einfügen', 'Tap right Ctrl twice and hold to talk, let go to paste') }),
      select(p.triggerMode, [['tap', t('Tippen', 'Tap')], ['hold', t('Halten', 'Hold')]], v => update({ triggerMode: v }), t('Tippen oder halten', 'Tap or hold'), 'trigger-mode')))
  // Only worth a line when something is missing.
  const shortcutNote = el('div', { className: 'hint', textContent: shortcutHint(info.shortcutWorks ?? true, info.wayland, p.language) })

  // Provider and key
  const keyRow = el('div', { className: 'row' })
  if (editingKey || !info.hasKey) {
    const input = el('input', { type: 'password', id: 'key', className: 'grow', placeholder: provider === 'openrouter' ? 'sk-or-…' : provider === 'groq' ? 'gsk_…' : 'sk-…' })
    const save = el('button', { className: 'accent', textContent: t('Sichern', 'Save') })
    const commit = async () => {
      if (!input.value.trim()) return
      const ok = await satz.invoke('settings:store-key', input.value, provider)
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
  const currentModel = p.models[provider] || defaults[provider]
  const modelField = el('input', { type: 'text', id: 'model', className: 'grow', value: p.models[provider] ?? '', placeholder: defaults[provider] })
  // Saved on Return, or quietly when the field is left: drawing the page
  // again right then closed the model menu the user had just opened.
  const saveModel = (redraw: boolean) => {
    const id = modelField.value.trim()
    typingModel = false
    if (redraw) update({ models: { ...p.models, [provider]: id } })
    else satz.invoke('settings:update', { models: { ...p.models, [provider]: id } }).then(next => { info.prefs = next })
  }
  modelField.onchange = () => saveModel(false)
  modelField.onkeydown = event => {
    if (event.key === 'Enter') saveModel(true)
    // Escape keeps the model there was. The old id goes back first: the field
    // closing counts as leaving it, which saved the half-typed one.
    if (event.key === 'Escape') { modelField.value = p.models[provider] ?? ''; typingModel = false; render() }
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
  // Not for Local, whose cards are its list.
  if (!isLocal) {
    for (const model of info.models) modelMenu.append(el('option', { value: model.id, textContent: title(model) }))
    modelMenu.append(el('option', { value: '', textContent: t('Anderes Modell …', 'Other model …') }))
  }
  const chosen = choiceFor(info.models, currentModel)
  const known = chosen !== undefined
  const facts = el('div', { className: 'hint', textContent: !chosen ? t('Ein Modell, das nicht in der Liste steht.', 'A model that is not in the list.') : [
    chosen.errorRate === undefined ? t('Noch ohne Fehlerquote von Artificial Analysis', 'No error rate from Artificial Analysis yet')
      : t(`${number(chosen.errorRate, 1)} % falsche Wörter laut Artificial Analysis`, `${number(chosen.errorRate, 1)} % wrong words per Artificial Analysis`),
    ...(chosen.dollarsPerHour === undefined ? [] : [t(`${number(chosen.dollarsPerHour, 2)} $ pro Stunde Sprechen`, `$${number(chosen.dollarsPerHour, 2)} per hour of talking`)]),
  ].join(', ') })
  modelMenu.value = known && !typingModel ? currentModel : ''
  modelMenu.onchange = () => {
    if (!modelMenu.value) { typingModel = true; selectModelId = true; focusNext = 'model'; render(); return }
    typingModel = false
    update({ models: { ...p.models, [provider]: modelMenu.value } })
  }
  const showsModelField = provider === 'custom' || typingModel || !known
  // Choosing in the menu only shows that provider. On Windows the arrow keys
  // step through a closed menu, one change each: that alone used to switch
  // dictations from provider to provider.
  const providerMenu = select(provider, providerOrder.map((option): [Provider, string] => [option, providerLabel(option, p.provider, p.language)]),
    v => { editingKey = false; typingModel = false; keyProblem = ''; wantsKeyFocus = false; shownProvider = v; load() }, t('Anbieter', 'Provider'), 'provider')
  // Where dictations go while another provider is shown, and the one way to change that.
  const switching = switchRow(provider, p.provider, p.language)
  const switchRows: HTMLElement[] = []
  if (switching) {
    const use = el('button', { id: 'use-provider', className: 'accent', textContent: switching.button })
    use.onclick = () => { editingKey = false; update({ provider }) }
    switchRows.push(el('div', { className: 'row switch-provider' }, el('span', { className: 'grow', textContent: switching.text }), use))
  }
  const providerBox = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Anbieter', 'Provider') }), providerMenu),
    ...switchRows,
    ...(isLocal ? [] : [
      keyRow,
      ...(provider === 'custom' ? [] : [el('div', { className: 'row' }, el('span', { textContent: t('Modell', 'Model') }), modelMenu), facts]),
      ...(showsModelField ? [el('div', { className: 'row' }, el('span', { textContent: provider === 'custom' ? t('Modell', 'Model') : t('Modell-ID', 'Model ID') }), modelField)] : []),
    ]))
  const localCaption = isLocal ? [el('div', { className: 'hint', textContent: t('Läuft auf diesem Computer, ohne Internet und kostenlos.', 'Runs on this computer, offline and free.') })] : []
  if (provider === 'custom') {
    const url = el('input', { type: 'text', id: 'custom-url', className: 'grow', value: p.customBaseURL, placeholder: 'https://…/v1' })
    url.onchange = () => update({ customBaseURL: url.value.trim() })
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Adresse', 'Address') }), url))
  }
  // Only MAI-Transcribe has a clean mode; elsewhere the switch would do nothing.
  // Only MAI-Transcribe 2 takes it: 1.5 refused the whole request with it.
  if (currentModel.includes('mai-transcribe-2')) {
    const box = el('input', { type: 'checkbox', id: 'removes-fillers', checked: p.removesFillers })
    box.onchange = () => update({ removesFillers: box.checked })
    providerBox.append(el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Füllwörter weglassen', 'Remove filler words'), box)))
  }

  // Vocabulary
  const words = el('div', { className: 'chips' })
  for (const word of p.words) {
    const remove = el('button', { textContent: '×', title: t('Entfernen', 'Remove') })
    remove.setAttribute('aria-label', `${t('Entfernen', 'Remove')}: ${word}`)
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
  const useBox = el('input', { type: 'checkbox', id: 'uses-replacements', checked: p.usesReplacements })
  useBox.onchange = () => update({ usesReplacements: useBox.checked })
  const replacementBox = el('div', { className: 'box' }, el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Gesprochene Zeichen ersetzen', 'Replace spoken symbols'), useBox)))
  if (p.usesReplacements) {
    replacementBox.append(el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Gesprochen auf', 'Spoken in') }),
      select(info.spokenLanguage, [['de', 'Deutsch'], ['en', 'English']], v => update({ spokenLanguage: v }), t('Gesprochen auf', 'Spoken in'), 'spoken-language')))
    const chips = el('div', { className: 'chips' })
    for (const rule of p.replacements.filter(r => r.isOn)) {
      const remove = el('button', { textContent: '×', title: t('Entfernen', 'Remove') })
      remove.setAttribute('aria-label', `${t('Entfernen', 'Remove')}: ${rule.spoken}`)
      remove.onclick = () => update({ replacements: p.replacements.filter(r => r.id !== rule.id) })
      chips.append(el('span', { className: 'chip' }, `${rule.spoken} → `, el('code', { textContent: shown(rule.written) }), remove))
    }
    const spoken = el('input', { type: 'text', id: 'new-spoken', placeholder: t('gesprochen', 'spoken') })
    const written = el('input', { type: 'text', id: 'new-written', placeholder: t('wird zu', 'becomes'), size: 6 })
    const add = el('button', { textContent: '+', title: t('Hinzufügen', 'Add') })
    add.setAttribute('aria-label', t('Ersetzung hinzufügen', 'Add replacement'))
    add.onclick = () => {
      if (!spoken.value.trim() || !written.value) return
      focusNext = 'new-spoken'
      // The same phrase again changes the rule there is: a second one stayed
      // in the list while the first still won.
      const said = spoken.value.trim()
      const same = p.replacements.find(r => r.spoken.toLowerCase() === said.toLowerCase())
      // "\n" typed as two characters means a line break, as on the Mac.
      const symbol = written.value.replace(/\\n/g, '\n')
      update({ replacements: same
        ? p.replacements.map(r => (r === same ? { ...r, written: symbol, isOn: true } : r))
        : [...p.replacements, { id: `u${Date.now()}`, spoken: said, written: symbol, isOn: true }] })
    }
    written.onkeydown = e => { if (e.key === 'Enter') add.click() }
    chips.append(spoken, written, add)
    replacementBox.append(chips)
  }

  // General
  const startBox = el('input', { type: 'checkbox', id: 'start-at-login', checked: info.startAtLogin })
  startBox.onchange = async () => { await satz.invoke('settings:start-at-login', startBox.checked); await load() }
  const mediaBox = el('input', { type: 'checkbox', id: 'pauses-media', checked: p.pausesMedia })
  mediaBox.onchange = () => update({ pausesMedia: mediaBox.checked })
  // Off: whatever was copied before comes back after pasting.
  const keepBox = el('input', { type: 'checkbox', id: 'keeps-clipboard', checked: p.keepsOnClipboard })
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
  const keep = select(String(p.historyLimit ?? 50), HISTORY_LIMITS.map((limit): [string, string] => [String(limit), limit === 0 ? t('Aus', 'Off') : limit === KEEP_ALL ? t('Alle', 'All') : String(limit)]),
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
      select(p.language, [['de', 'Deutsch'], ['en', 'English']], v => update({ language: v }), t('Sprache', 'Language'), 'language')),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Beim Anmelden starten', 'Start at login'), startBox)),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Musik beim Diktieren pausieren', 'Pause music while dictating'), mediaBox)),
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Text in der Zwischenablage behalten', 'Keep text on the clipboard'), keepBox)),
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Verlauf behalten', 'Keep history') }), keep, show, clear))

  // The page is drawn anew after every change; the cursor stays in the field
  // it was in, so several words can be typed one after the other.
  const focused = (document.activeElement as HTMLElement | null)?.id || null
  app.replaceChildren(
    section(t('Kurzbefehl', 'Shortcut'), shortcut, shortcutNote),
    section(t('Anbieter', 'Provider'), providerBox, ...localCaption, ...(isLocal ? localCards() : []), ...(keyProblem ? [el('div', { className: 'error', textContent: keyProblem })] : [])),
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

/** Small line icons for the cards, after Lucide's (ISC). */
const icons = {
  globe: '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>',
  download: '<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>',
  disk: '<path d="M22 12H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><path d="M6 16h.01"/><path d="M10 16h.01"/>',
  trash: '<path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/><path d="M10 11v6"/><path d="M14 11v6"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
}
const icon = (name: keyof typeof icons) => el('span', { className: 'icon', ariaHidden: 'true',
  innerHTML: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${icons[name]}</svg>` })

type LocalEntry = Info['local']['models'][number]

/**
 * Handy's model page: "Your models" (on this computer, the one in use
 * first) and "Available models" (everything else), one card each. A click
 * on an available card downloads it, a click on one of yours uses it:
 * explicit choices both. A download never switches the model by itself
 * (speedTests.ts says when it does) and never the provider; using a model
 * while Local is only being looked at switches to Local (core/browse.ts).
 */
function localCards(): HTMLElement[] {
  const { inUse, models } = info.local
  const ready = models.filter(model => model.state.kind === 'ready')
  const mine = [...ready.filter(model => model.id === inUse), ...ready.filter(model => model.id !== inUse)]
  const available = models.filter(model => model.state.kind !== 'ready')
  const title = (text: string) => el('h3', { className: 'models-title', textContent: text })
  const list = (entries: LocalEntry[], yours: boolean) => el('div', { className: 'model-cards' }, ...entries.map(entry => modelCard(entry, yours)))
  const out: HTMLElement[] = [title(t('Deine Modelle', 'Your models'))]
  out.push(mine.length ? list(mine, true) : el('div', { className: 'hint models-empty', textContent: t('Noch keins. Ein Klick auf ein Modell unten lädt es.', 'None yet. Click a model below to download it.') }))
  // Canary is told the language instead of hearing it: its choice sits with
  // it, among the four it writes, and apart from the app's own German or
  // English, which Whisper and the replacements go by.
  const told = toldLanguage(inUse, info.prefs.toldLanguage, info.spokenLanguage)
  const model = localModel(inUse)
  if (model && told) {
    const options = model.languages.map((code): [string, string] => [code, languageName(code, info.prefs.language)])
    out.push(el('div', { className: 'box spoken-box' }, el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Gesprochen auf', 'Spoken in') }),
      select(told, options, v => update({ toldLanguage: v }), t('Gesprochen auf', 'Spoken in'), 'local-spoken-language'))),
    el('div', { className: 'hint', textContent: t(`${model.name} hört nur auf diese Sprache.`, `${model.name} listens for this language only.`) }))
  }
  if (available.length) out.push(title(t('Verfügbare Modelle', 'Available models')), list(available, false))
  return out
}

/**
 * One model: name, badges and one plain sentence; accuracy and speed as
 * bars, the numbers behind them as their help; languages, size and Delete
 * at the bottom; progress with Cancel, getting ready and the speed test
 * inside it while they run.
 */
function modelCard({ id, state, measuring, speed }: LocalEntry, yours: boolean): HTMLElement {
  const { inUse, models, germanErrors, machine, version } = info.local
  const language = info.prefs.language
  const localInUse = info.prefs.provider === 'local'
  const catalog = localModel(id)
  const key = id.replace(/[^\w-]/g, '-')
  // One download at a time.
  const busy = models.some(model => model.state.kind === 'downloading' || model.state.kind === 'preparing')
  const active = yours && localRowAction(id, inUse, localInUse) === 'in-use'
  // The model in use is not clickable: choosing it again would do nothing.
  const clickable = yours ? !active : state.kind === 'missing' || state.kind === 'failed'
  const disabled = clickable && !yours && busy
  const card = el('div', { id: `card-${key}`, className: ['model-card', active ? 'in-use' : '', clickable ? 'clickable' : '', disabled ? 'disabled' : ''].filter(Boolean).join(' ') })
  if (clickable) {
    card.setAttribute('role', 'button')
    card.tabIndex = disabled ? -1 : 0
    card.setAttribute('aria-disabled', String(disabled))
    card.title = disabled ? t('Wenn das andere Modell geladen ist', 'Once the other model has downloaded')
      : yours ? t('Klicken benutzt dieses Modell', 'Click to use this model') : t('Klicken lädt dieses Modell', 'Click to download this model')
    const act = () => {
      if (disabled) return
      if (yours) update(useLocalModel(id, info.prefs.models, localInUse))
      else satz.invoke('local:download', id).then(load)
    }
    card.onclick = act
    card.onkeydown = event => { if ((event.key === 'Enter' || event.key === ' ') && event.target === card) { event.preventDefault(); act() } }
  }
  // A button inside the card does its own thing, not the card's.
  const button = (name: string, label: (Node | string)[], onClick: () => unknown, className = '') => {
    const b = el('button', { id: `${name}-${key}`, className }, ...label)
    b.onclick = event => { event.stopPropagation(); onClick() }
    return b
  }

  const name = el('div', { className: 'card-title' }, el('span', { className: 'card-name', textContent: catalog?.name ?? id }))
  if (active) name.append(el('span', { className: 'badge' }, icon('check'), t('Aktiv', 'Active')))
  // As Handy does: the recommendation is for choosing what to download.
  if (!yours && id === defaults.local) name.append(el('span', { className: 'badge' }, t('Empfohlen', 'Recommended')))
  const about = el('div', { className: 'card-about' }, name, ...(catalog ? [el('p', { className: 'card-text', textContent: catalog.description[language] })] : []))

  const here = speed ? measuredHere(speed, machine, version) : false
  const bars = modelBars(id, language, { speed, here, errors: germanErrors, downloaded: state.kind === 'ready' })
  const measure = () => satz.invoke('local:measure', id).then(load)
  const canMeasure = state.kind === 'ready' && !measuring
  const barRow = (label: string, bar: { value: number; help: string }, again = false) => {
    const fill = el('span')
    fill.style.width = `${Math.round(bar.value * 100)}%`
    const parts = [el('span', { className: 'bar-label', textContent: label }), el('span', { className: 'bar', role: 'img', ariaLabel: `${label}: ${Math.round(bar.value * 10)}/10` }, fill)]
    // The speed changes with the word list, and a run can go wrong: neither must stick.
    if (!again) return el('div', { className: 'bar-row', title: bar.help }, ...parts)
    return button('measure-again', parts, measure, 'bar-row again')
  }
  const barBox = el('div', { className: 'bars' })
  if (bars.accuracy) barBox.append(barRow(t('Genauigkeit', 'Accuracy'), bars.accuracy))
  if (bars.speed) {
    const row = barRow(t('Tempo', 'Speed'), bars.speed, canMeasure)
    row.title = canMeasure ? `${bars.speed.help}. ${t('Klicken misst neu.', 'Click to measure again.')}` : bars.speed.help
    barBox.append(row)
  }
  const top = el('div', { className: 'card-top' }, about, ...(barBox.childNodes.length ? [barBox] : []))

  const bottom = el('div', { className: 'card-bottom' })
  if (catalog) {
    const languages = languageLine(catalog, language)
    bottom.append(el('span', { className: 'card-fact', title: languages.help }, icon('globe'), languages.text))
  }
  // Never measured here: the one thing that fills its speed bar with a real number.
  if (canMeasure && !here) bottom.append(button('measure', [t('Tempo messen', 'Measure speed')], measure, 'quiet'))
  if (catalog) bottom.append(el('span', { className: 'card-fact size', title: state.kind === 'ready' ? t('Auf diesem Computer', 'On this computer') : t('Download', 'Download') },
    icon(state.kind === 'ready' ? 'disk' : 'download'), formatSize(catalog.bytes, language)))
  if (state.kind === 'ready') {
    const remove = button('remove', [icon('trash'), t('Löschen', 'Delete')], () => satz.invoke('local:remove', id).then(load), 'delete')
    remove.title = t('Legt das Modell in den Papierkorb', 'Moves the model to the trash')
    bottom.append(remove)
  }
  card.append(top, el('hr'), bottom)

  const status = (text: string) => el('div', { className: 'card-status' }, el('span', { className: 'spinner', ariaHidden: 'true' }), text)
  if (state.kind === 'downloading') {
    const percent = Math.floor(state.fraction * 100)
    const fill = el('div', { className: 'fill' })
    fill.style.width = `${percent}%`
    const track = el('div', { className: 'track', role: 'progressbar' }, fill)
    track.setAttribute('aria-valuenow', String(percent))
    track.setAttribute('aria-valuemin', '0')
    track.setAttribute('aria-valuemax', '100')
    track.setAttribute('aria-label', t('Fortschritt', 'Progress'))
    card.append(el('div', { className: 'card-progress' }, track, el('div', { className: 'progress-line' },
      el('span', { textContent: t(`Lädt ${percent} %`, `Downloading ${percent} %`) }),
      button('cancel', [t('Abbrechen', 'Cancel')], () => satz.invoke('local:cancel', id).then(load), 'cancel'))))
  } else if (state.kind === 'preparing') card.append(status(t('Wird vorbereitet', 'Getting ready')))
  else if (measuring) card.append(status(t('Tempo wird gemessen', 'Measuring speed')))
  else if (state.kind === 'failed') {
    card.append(el('div', { className: 'card-status failed', title: state.message, textContent: t('Laden fehlgeschlagen. Klicken versucht es nochmal.', 'Download failed. Click to try again.') }))
  }
  return card
}

async function load() {
  info = await satz.invoke('settings:get', shownProvider)
  shownProvider = info.shown
  document.documentElement.lang = info.prefs.language
  document.dispatchEvent(new CustomEvent('satz-language', { detail: info.prefs.language }))
  render()
}

// A new model list draws the page again, but not under someone typing: that
// emptied a half-typed word. It waits until the field is left, once.
const afterBlur = new LoadAfterBlur()
function loadWhenFree() {
  const field = document.activeElement
  if (field instanceof HTMLInputElement && field.type !== 'checkbox' && field.closest('#settings-page')) afterBlur.later(field, load)
  else load()
}
satz.on('models:changed', loadWhenFree)
satz.on('local:changed', loadWhenFree)
// Opened again (from the tray, the history or its tab): the provider in use, not the one looked at last.
document.addEventListener('satz-page-opened', event => {
  if ((event as CustomEvent).detail !== 'settings' || shownProvider === null || shownProvider === info?.prefs.provider) return
  shownProvider = null
  editingKey = false
  typingModel = false
  keyProblem = ''
  load()
})
load()

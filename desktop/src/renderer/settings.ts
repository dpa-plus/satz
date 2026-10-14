import { satz } from './bridge'
import { formatSize, languageLine, languageName, localModel, measuredHere, modelBars, toldLanguage, type Speed } from '../core/localModels'
import { choiceFor, type ModelChoice } from '../core/models'
import { addressRefusal, customAddress, keyRefusal, localRowAction, providerLabel, providerNeeds, providerOrder, shortcutHint, switchRow, useLocalModel } from '../core/browse'
import { hasCleanMode, keyPages, microsoftHost, microsoftRegions, providers, type Provider } from '../core/transcriber'
import { HISTORY_LIMITS, KEEP_ALL } from '../core/historyLimits'
import { cleanupLevels, levelChange, levelTexts, systemPrompt, trySample, type CleanupLevel } from '../core/cleanup'
import {
  chosenModel, cleanupMissing, cleanupNeeds, cleanupProviderLabel, cleanupProviderOrder, cleanupProviders, cleanupSwitchRow, usableAddress, type CleanupProviderId,
} from '../core/cleanupProviders'
import { averageChars, estimate, factsLine, menuTitle, tryLine, type Price, type Sample } from '../core/cleanupEstimate'
import { LoadAfterBlur } from './deferredLoad'

/**
 * Settings: the provider and its key, the vocabulary, the Ersetzungen with
 * their spoken language, the shortcut mode, language and start at login.
 * Rebuilt from scratch on every change: it is a short page.
 */
type LocalState = { kind: 'missing' | 'preparing' | 'ready' } | { kind: 'downloading'; fraction: number } | { kind: 'failed'; message: string }
/** What Ollama or LM Studio has installed, and whether it answered. */
type Installed = { state: 'loading' | 'ok' | 'down'; models: string[] }
type TryResult = { outcome: string; answer?: string; rejected: boolean; seconds?: number; dollars?: number; cancelled?: boolean }
interface Replacement { id: string; spoken: string; written: string; isOn: boolean }
interface Info {
  prefs: {
    provider: Provider; models: Record<string, string>; customBaseURL: string; microsoftRegion: string; microsoftEndpoint: string; words: string[]; triggerMode: 'tap' | 'hold'
    language: 'de' | 'en'; spokenLanguage: 'de' | 'en' | null; toldLanguage?: string | null; replacements: Replacement[]; usesReplacements: boolean; removesFillers: boolean
    keepsOnClipboard: boolean; historyLimit: number; pausesMedia: boolean
    cleansText: boolean; cleanupLevel: CleanupLevel; cleanupPrompt: string; cleanupProvider: CleanupProviderId | null
    cleanupModels: Partial<Record<CleanupProviderId, string>>; cleanupAddresses: Partial<Record<CleanupProviderId, string>>
  }
  /** Newest first; how long the user's dictations are, for the cleanup estimate. */
  history: { text: string; original?: string }[]
  /** The cleanup provider shown and the one in use, and what the page shows about the shown one. */
  cleanup: {
    inUse: CleanupProviderId; shown: CleanupProviderId; hasKey: boolean; inUseHasKey: boolean
    prices: Record<string, Price>; samples: Record<string, Sample[]>
    installed: Installed | null; inUseInstalled?: Installed | null
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

// Cleanup, the page's own like the provider above: looking at a provider is not using it.
let shownCleanup: CleanupProviderId | null = null
let editingCleanupKey = false
let cleanupKeyProblem = ''
let typingCleanupModel = false
/** "Prompt ansehen" is open. */
let showsPrompt = false
/** The own prompt as typed, saved when the field is left and at most every second while typing. */
let promptDraft: string | null = null
let promptTimer: ReturnType<typeof setTimeout> | null = null
/** "Ausprobieren": the text (the sample until changed), whether it runs, and what came back. */
let tryText: string | null = null
let trying = false
let tryToken = 0
let tryResult: TryResult | null = null

const t = (de: string, en: string) => (info.prefs.language === 'de' ? de : en)
const defaults = Object.fromEntries(Object.entries(providers).map(([provider, { defaultModel }]) => [provider, defaultModel])) as Record<Provider, string>
/** The empty key field's hint. */
const keyHint = (provider: Provider) => provider === 'openrouter' ? 'sk-or-…' : provider === 'groq' ? 'gsk_…' : provider === 'google' ? 'AIza…'
  : provider === 'microsoft' ? t('Schlüssel 1 oder 2', 'Key 1 or 2') : 'sk-…'
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
    const input = el('input', { type: 'password', id: 'key', className: 'grow', placeholder: keyHint(provider) })
    const save = el('button', { className: 'accent', textContent: t('Sichern', 'Save') })
    const commit = async () => {
      if (!input.value.trim()) return
      // Said here, with the reason, before the app is asked: its answer is only yes or no.
      const refusal = keyRefusal(input.value, p.language)
      if (refusal) { keyProblem = refusal; wantsKeyFocus = true; render(); return }
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
  // Where to get the key, while it is being typed, for the two providers whose key is not obvious to find.
  const keyPage = keyPages[provider]
  const keyHelp: HTMLElement[] = []
  if (keyPage && (editingKey || !info.hasKey)) {
    const open = el('button', { className: 'quiet', id: 'key-page', textContent: provider === 'microsoft' ? t('Speech-Ressource im Azure-Portal anlegen', 'Create a Speech resource in the Azure portal') : t('Schlüssel in Google AI Studio holen', 'Get a key in Google AI Studio') })
    open.onclick = () => satz.invoke('settings:open-key-page', provider)
    keyHelp.push(el('div', { className: 'hint' }, open, ...(provider === 'microsoft'
      ? ['. ', t('Der Schlüssel gilt nur in der Region seiner Ressource (Standard S0).', 'The key only works in the region of its resource (Standard tier, S0).')] : [])))
  }
  // Microsoft: the region of the resource, and an own address that wins over it.
  const microsoftRows: HTMLElement[] = []
  if (provider === 'microsoft') {
    microsoftRows.push(el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Region', 'Region') }),
      select(p.microsoftRegion, [...microsoftRegions.map((region): [string, string] => [region.id, region.name]),
        // A region typed into the preferences by hand stays visible, not swapped for the first.
        ...(microsoftRegions.some(region => region.id === p.microsoftRegion) ? [] : [[p.microsoftRegion, p.microsoftRegion] as [string, string]])],
        v => update({ microsoftRegion: v }), t('Region', 'Region'), 'microsoft-region')))
    const own = el('input', { type: 'text', id: 'microsoft-endpoint', className: 'grow', value: p.microsoftEndpoint, placeholder: 'https://….cognitiveservices.azure.com' })
    own.onchange = () => update({ microsoftEndpoint: own.value.trim() })
    microsoftRows.push(el('div', { className: 'row' }, el('span', { textContent: t('Eigene Adresse', 'Own address') }), own))
    const ownRefused = p.microsoftEndpoint.trim() !== '' && !microsoftHost(p.microsoftRegion, p.microsoftEndpoint)
    microsoftRows.push(el('div', { className: ownRefused ? 'error' : 'hint',
      textContent: ownRefused ? addressRefusal(p.language) : t('Optional. Wenn gesetzt, gilt sie statt der Region.', 'Optional. If set, it is used instead of the region.') }))
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
  ].join(', ') + (chosen.note ? `. ${chosen.note[p.language]}` : '') })
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
  // The button only once the provider has what it needs (a key, for Microsoft a region, for Local a model on this computer).
  const needs = providerNeeds(provider, {
    hasKey: isLocal ? info.local.models.some(model => model.id === info.local.inUse && model.state.kind === 'ready') : info.hasKey,
    customBaseURL: p.customBaseURL, model: p.models[provider] ?? '', microsoftRegion: p.microsoftRegion, microsoftEndpoint: p.microsoftEndpoint,
  })
  const switching = switchRow(provider, p.provider, p.language, needs)
  const switchRows: HTMLElement[] = []
  if (switching) {
    const parts: HTMLElement[] = [el('span', { className: 'grow', textContent: switching.text })]
    if (switching.button) {
      const use = el('button', { id: 'use-provider', className: 'accent', textContent: switching.button })
      use.onclick = () => { editingKey = false; update({ provider }) }
      parts.push(use)
    }
    switchRows.push(el('div', { className: 'row switch-provider' }, ...parts))
  }
  const providerBox = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Anbieter', 'Provider') }), providerMenu),
    ...switchRows,
    ...(isLocal ? [] : [
      keyRow,
      ...keyHelp,
      ...microsoftRows,
      ...(provider === 'custom' ? [] : [el('div', { className: 'row' }, el('span', { textContent: t('Modell', 'Model') }), modelMenu), facts]),
      ...(showsModelField ? [el('div', { className: 'row' }, el('span', { textContent: provider === 'custom' ? t('Modell', 'Model') : t('Modell-ID', 'Model ID') }), modelField)] : []),
    ]))
  const localCaption = isLocal ? [el('div', { className: 'hint', textContent: t('Läuft auf diesem Computer, ohne Internet und kostenlos.', 'Runs on this computer, offline and free.') })] : []
  if (provider === 'custom') {
    const url = el('input', { type: 'text', id: 'custom-url', className: 'grow', value: p.customBaseURL, placeholder: 'https://…/v1' })
    url.onchange = () => update({ customBaseURL: url.value.trim() })
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Adresse', 'Address') }), url))
    // Typed and refused: said why, wherever the page stands (the row under the menu only shows while another provider is looked at).
    if (p.customBaseURL.trim() !== '' && customAddress(p.customBaseURL) === null) providerBox.append(el('div', { className: 'error', textContent: addressRefusal(p.language) }))
  }
  // Only MAI-Transcribe 2 (1.5 refused the whole request with it) and Gemini have a clean mode; elsewhere the switch would do nothing.
  if (hasCleanMode(provider, currentModel)) {
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
  const active = document.activeElement as HTMLInputElement | null
  let caret: [number, number] | null = null
  try { if (active && typeof active.selectionStart === 'number') caret = [active.selectionStart, active.selectionEnd ?? active.selectionStart] } catch { /* no selection here */ }
  app.replaceChildren(
    section(t('Kurzbefehl', 'Shortcut'), shortcut, shortcutNote),
    section(t('Anbieter', 'Provider'), providerBox, ...localCaption, ...(isLocal ? localCards() : []), ...(keyProblem ? [el('div', { className: 'error', textContent: keyProblem })] : [])),
    section(t('Wortschatz', 'Vocabulary'), el('div', { className: 'box' }, words)),
    section(t('Ersetzungen', 'Replacements'), replacementBox),
    cleanupSection(),
    section(t('Allgemein', 'General'), general),
  )
  const target = focusNext ?? focused
  focusNext = null
  const field = target ? document.getElementById(target) as HTMLInputElement | null : null
  field?.focus()
  // Back where the cursor was: the own prompt is drawn again while it is typed in.
  if (field && target === focused && caret) { try { field.setSelectionRange(caret[0], caret[1]) } catch { /* not a text field */ } }
  if (selectModelId && target === 'model') field?.select()
  selectModelId = false
}

/**
 * Cleanup ("Aufräumen"), between the replacements and General: the order
 * the text goes through. Everything shows whether it is on or off, so it
 * can be looked at and tried before it is switched on.
 */
function cleanupSection(): HTMLElement {
  const p = info.prefs
  const c = info.cleanup
  const language = p.language
  const provider = c.shown
  const entry = cleanupProviders[provider]
  // While Ollama is still being asked, its model is not missing yet.
  const known = (installed: Installed | null | undefined) => (installed?.state === 'loading' ? undefined : installed?.models)
  const needsOf = (id: CleanupProviderId, hasKey: boolean, installed: Installed | null | undefined) => cleanupNeeds(id, {
    hasKey, address: p.cleanupAddresses?.[id], model: p.cleanupModels?.[id], installed: known(installed),
  }).filter(need => need !== 'model' || installed?.state !== 'loading')

  // The switch, and what keeps the provider in use from working while it is on.
  const onBox = el('input', { type: 'checkbox', id: 'cleans-text', checked: p.cleansText })
  onBox.onchange = () => update({ cleansText: onBox.checked })
  const toggleBox = el('div', { className: 'box' },
    el('div', { className: 'row' }, el('label', { className: 'switch' }, t('Text aufräumen', 'Clean up the text'), onBox)),
    el('div', { className: 'hint', textContent: t('Ein Sprachmodell überarbeitet den Text, bevor satz ihn einfügt. Das Original bleibt im Verlauf.',
      'A language model edits the text before satz pastes it. The original stays in the history.') }))
  const missing = p.cleansText
    ? cleanupMissing(needsOf(c.inUse, c.inUseHasKey, c.inUse === provider ? c.installed : c.inUseInstalled), p.cleanupLevel === 'custom' && !(promptDraft ?? p.cleanupPrompt).trim(), language)
    : null
  if (missing) toggleBox.append(el('div', { className: 'error', id: 'cleanup-missing', textContent: missing }))

  // How much: four presets and the user's own prompt.
  const levelBox = el('div', { className: 'box' })
  for (const level of cleanupLevels) {
    const radio = el('input', { type: 'radio', name: 'cleanup-level', id: `cleanup-level-${level}`, value: level, checked: p.cleanupLevel === level })
    radio.onchange = () => {
      // The own prompt starts as the instructions of the level chosen before (the test mode's cleanup-level does the same).
      const change = levelChange({ cleanupLevel: p.cleanupLevel, cleanupPrompt: promptDraft ?? p.cleanupPrompt }, level)
      if ('cleanupPrompt' in change) promptDraft = null
      update(change)
    }
    const words = levelTexts[level][language]
    levelBox.append(el('label', { className: 'row choice' }, radio,
      el('span', { className: 'choice-text' }, el('span', { className: 'choice-title', textContent: words.title }), el('span', { className: 'choice-line', textContent: words.line }))))
  }
  if (p.cleanupLevel === 'custom') {
    const editor = el('textarea', { id: 'cleanup-prompt', className: 'prompt-editor', value: promptDraft ?? p.cleanupPrompt, spellcheck: false })
    editor.setAttribute('aria-label', t('Eigener Prompt', 'Own prompt'))
    editor.oninput = () => { promptDraft = editor.value; savePromptSoon() }
    editor.onblur = () => { void savePrompt() }
    levelBox.append(el('div', { className: 'row prompt-row' }, editor),
      el('div', { className: 'hint', textContent: t('Der diktierte Text wird angehängt, dein Wortschatz auch.', 'The dictated text is added after it, and so is your vocabulary.') }))
  } else {
    // Nothing hidden: the exact prompt satz sends for this level.
    const details = el('details', { id: 'cleanup-prompt-details', open: showsPrompt },
      el('summary', { textContent: t('Prompt ansehen', 'Show prompt') }),
      el('pre', { className: 'prompt', textContent: systemPrompt(p.cleanupLevel, p.words) }))
    details.ontoggle = () => { showsPrompt = details.open }
    levelBox.append(el('div', { className: 'disclosure' }, details))
  }

  // The provider, its key, address and model, and what a dictation costs there.
  const providerMenu = select(provider, cleanupProviderOrder.map((id): [CleanupProviderId, string] => [id, cleanupProviderLabel(id, c.inUse, language)]),
    v => { editingCleanupKey = false; typingCleanupModel = false; cleanupKeyProblem = ''; shownCleanup = v; load() }, t('Anbieter fürs Aufräumen', 'Cleanup provider'), 'cleanup-provider')
  // The dot and "In Benutzung" beside the menu while it shows the provider in use, as on the Mac.
  const inUseMark = provider === c.inUse
    ? [el('span', { className: 'provider-in-use', id: 'cleanup-in-use' }, el('span', { className: 'dot', ariaHidden: 'true' }), t('In Benutzung', 'In use'))] : []
  const providerBox = el('div', { className: 'box' }, el('div', { className: 'row' }, el('span', { className: 'grow', textContent: t('Anbieter', 'Provider') }), ...inUseMark, providerMenu))
  const switching = cleanupSwitchRow(provider, c.inUse, language, needsOf(provider, c.hasKey, c.installed))
  if (switching) {
    const parts: HTMLElement[] = [el('span', { className: 'grow', textContent: switching.text })]
    if (switching.button) {
      const use = el('button', { id: 'use-cleanup-provider', className: 'accent', textContent: switching.button })
      use.onclick = () => { editingCleanupKey = false; update({ cleanupProvider: provider }) }
      parts.push(use)
    }
    providerBox.append(el('div', { className: 'row switch-provider' }, ...parts))
  }
  if (entry.account) {
    const keyRow = el('div', { className: 'row' })
    if (editingCleanupKey || !c.hasKey) {
      const input = el('input', { type: 'password', id: 'cleanup-key', className: 'grow', placeholder: entry.keyPlaceholder[language] })
      const save = el('button', { className: 'accent', textContent: t('Sichern', 'Save') })
      const commit = async () => {
        if (!input.value.trim()) return
        const ok = await satz.invoke('cleanup:store-key', input.value, provider)
        cleanupKeyProblem = ok ? '' : t('Konnte nicht gesichert werden.', 'Could not be saved.')
        editingCleanupKey = false
        await load()
      }
      save.onclick = commit
      input.onkeydown = e => { if (e.key === 'Enter') commit(); if (e.key === 'Escape' && c.hasKey) { editingCleanupKey = false; render() } }
      keyRow.append(el('span', { textContent: t('Schlüssel', 'Key') }), input, save)
      if (c.hasKey) { const cancel = el('button', { textContent: '×', title: t('Abbrechen', 'Cancel') }); cancel.onclick = () => { editingCleanupKey = false; render() }; keyRow.append(cancel) }
    } else {
      const change = el('button', { textContent: t('Ändern', 'Change') })
      change.onclick = () => { editingCleanupKey = true; focusNext = 'cleanup-key'; render() }
      keyRow.append(el('span', { className: 'grow', textContent: t('Schlüssel gesichert', 'Key saved') }), change)
    }
    providerBox.append(keyRow)
    // One key file for both: the transcription provider's own.
    if (Object.hasOwn(providers, entry.account)) providerBox.append(el('div', { className: 'hint', textContent: t('Derselbe Schlüssel wie für die Spracherkennung.', 'The same key as for speech recognition.') }))
    if (entry.keyNote) providerBox.append(el('div', { className: 'hint', textContent: entry.keyNote[language] }))
    if (entry.keyPage && (editingCleanupKey || !c.hasKey)) {
      const open = el('button', { className: 'quiet', id: 'cleanup-key-page', textContent: t('Schlüssel holen', 'Get a key') })
      open.onclick = () => satz.invoke('cleanup:open-key-page', provider)
      providerBox.append(el('div', { className: 'hint' }, open))
    }
    if (cleanupKeyProblem) providerBox.append(el('div', { className: 'error', textContent: cleanupKeyProblem }))
  }
  if (entry.addressKind !== 'fixed') {
    const typed = p.cleanupAddresses?.[provider] ?? ''
    // Ollama's and LM Studio's default stands in the field, so changing the host or port is one edit; emptied, it comes back (cleanupBase).
    const address = el('input', { type: 'text', id: 'cleanup-address', className: 'grow', value: typed.trim() || (entry.addressKind === 'default' ? entry.address! : typed),
      placeholder: entry.address ?? (provider === 'azure' ? 'https://….openai.azure.com' : 'https://…/v1') })
    address.onchange = () => update({ cleanupAddresses: { ...p.cleanupAddresses, [provider]: address.value.trim() } })
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Adresse', 'Address') }), address))
    if (typed.trim() && !usableAddress(typed)) providerBox.append(el('div', { className: 'error', textContent: t('Das ist keine gültige Adresse (https://…).', 'That is not a valid address (https://…).') }))
    else if (provider === 'azure') providerBox.append(el('div', { className: 'hint', textContent: t('Die Adresse der Azure-OpenAI- oder Foundry-Ressource.', 'The address of the Azure OpenAI or Foundry resource.') }))
  }

  // The model: a menu of the catalog (or what Ollama and LM Studio have), each with its time and price, and "Other" typed by hand.
  const avgChars = averageChars(info.history ?? [])
  const prompt = promptDraft ?? p.cleanupPrompt
  const estimateFor = (model: string) => estimate({ provider, model, level: p.cleanupLevel, vocabulary: p.words, customPrompt: prompt, avgChars, livePrice: c.prices[model], samples: c.samples[model] })
  const listed = entry.lists ? (c.installed?.models ?? []) : entry.models.map(model => model.id)
  const current = chosenModel(provider, p.cleanupModels?.[provider], c.installed?.models)
  const saveModel = (id: string, redraw: boolean) => {
    typingCleanupModel = false
    const change = { cleanupModels: { ...p.cleanupModels, [provider]: id } }
    if (redraw) update(change)
    else satz.invoke('settings:update', change).then(next => { info.prefs = next })
  }
  const modelField = el('input', { type: 'text', id: 'cleanup-model-id', className: 'grow', value: p.cleanupModels?.[provider] ?? '',
    placeholder: provider === 'azure' ? t('Name der Bereitstellung', 'Deployment name') : entry.defaultModel || t('Modell', 'Model') })
  modelField.onchange = () => saveModel(modelField.value.trim(), false)
  modelField.onkeydown = event => {
    if (event.key === 'Enter') saveModel(modelField.value.trim(), true)
    if (event.key === 'Escape') { modelField.value = p.cleanupModels?.[provider] ?? ''; typingCleanupModel = false; render() }
  }
  const typedOnly = provider === 'azure' || provider === 'custom'
  const inList = listed.includes(current)
  if (!typedOnly) {
    const menu = el('select', { id: 'cleanup-model', className: 'grow' })
    menu.setAttribute('aria-label', t('Modell fürs Aufräumen', 'Cleanup model'))
    for (const id of listed) menu.append(el('option', { value: id, textContent: menuTitle(estimateFor(id), language) }))
    menu.append(el('option', { value: '', textContent: t('Anderes Modell …', 'Other model …') }))
    menu.value = inList && !typingCleanupModel ? current : ''
    menu.onchange = () => {
      if (!menu.value) { typingCleanupModel = true; focusNext = 'cleanup-model-id'; render(); return }
      saveModel(menu.value, true)
    }
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: t('Modell', 'Model') }), menu))
  }
  if (typedOnly || typingCleanupModel || (current !== '' && !inList)) {
    providerBox.append(el('div', { className: 'row' }, el('span', { textContent: typedOnly ? t('Modell', 'Model') : t('Modell-ID', 'Model ID') }), modelField))
  }
  const down = entry.lists && c.installed?.state === 'down'
  const facts = down ? (provider === 'ollama' ? t('Ollama läuft nicht. ollama.com', 'Ollama is not running. ollama.com') : t('LM Studio läuft nicht.', 'LM Studio is not running.'))
    : current ? factsLine(estimateFor(current), language) : ''
  if (facts) providerBox.append(el('div', { className: 'hint', id: 'cleanup-facts', textContent: facts }))

  const title = (text: string) => el('h3', { className: 'subhead', textContent: text })
  return section(t('Aufräumen', 'Cleanup'), toggleBox, title(t('Stärke', 'How much')), levelBox, title(t('Anbieter', 'Provider')), providerBox, title(t('Ausprobieren', 'Try it')), tryBox())
}

/**
 * "Ausprobieren": the shown provider, model, level and prompt on a sample,
 * before anything is switched. Drawn on its own too, when its answer comes:
 * the rest of the page waits while someone types elsewhere.
 */
function tryBox(): HTMLElement {
  const provider = info.cleanup.shown
  const sample = el('textarea', { id: 'cleanup-try', className: 'try-text', rows: 3, value: tryText ?? trySample(info.spokenLanguage), readOnly: trying })
  sample.setAttribute('aria-label', t('Text zum Ausprobieren', 'Text to try'))
  sample.oninput = () => { tryText = sample.value }
  const go = el('button', { id: 'cleanup-try-button', className: trying ? 'trying' : '' },
    ...(trying ? [el('span', { className: 'spinner', ariaHidden: 'true' }), t('Abbrechen', 'Cancel')] : [t('Ausprobieren', 'Try')]))
  go.onclick = () => (trying ? cancelTry() : runTry(sample.value, provider))
  const box = el('div', { className: 'box', id: 'cleanup-try-box' }, el('div', { className: 'row prompt-row' }, sample), el('div', { className: 'row' }, el('span', { className: 'grow' }), go))
  if (tryResult) {
    const result = el('div', { className: 'try-result', id: 'cleanup-try-result' })
    if (tryResult.answer !== undefined) result.append(el('div', { className: 'try-answer', textContent: tryResult.answer }))
    if (tryResult.seconds !== undefined) result.append(el('div', { className: 'hint-line', textContent: tryLine(tryResult.seconds, tryResult.dollars, info.prefs.language) }))
    if (tryResult.rejected) {
      result.append(el('div', { className: 'error-line', textContent: t('Verworfen: sah nicht nach deinem Text aus. satz würde das Original einfügen.', 'Rejected: did not look like your text. satz would paste the original.') }))
    } else if (tryResult.outcome !== 'ok') result.append(el('div', { className: 'error-line', textContent: tryResult.outcome }))
    box.append(result)
  }
  return box
}

/** The try box alone, keeping the focus where it is. */
function redrawTry() {
  const focused = document.activeElement
  const fresh = tryBox()
  document.getElementById('cleanup-try-box')?.replaceWith(fresh)
  if (focused?.id === 'cleanup-try-button') document.getElementById('cleanup-try-button')?.focus()
}

/** The own prompt, saved without drawing the page again: that would take the cursor out of it. */
function savePrompt(): Promise<void> {
  if (promptTimer) { clearTimeout(promptTimer); promptTimer = null }
  if (promptDraft === null || promptDraft === info.prefs.cleanupPrompt) return Promise.resolve()
  return satz.invoke('settings:update', { cleanupPrompt: promptDraft }).then(next => { info.prefs = next })
}

/** At most once a second while typing: nothing typed is lost if satz quits. */
function savePromptSoon() {
  if (!promptTimer) promptTimer = setTimeout(() => { promptTimer = null; void savePrompt() }, 1000)
}

async function runTry(text: string, provider: CleanupProviderId) {
  const mine = ++tryToken
  await savePrompt()
  trying = true
  tryResult = null
  redrawTry()
  const result = await satz.invoke('cleanup:try', text, provider) as TryResult | null
  // Cancelled, or another try started meanwhile: this one's answer is not shown.
  if (mine !== tryToken) return
  trying = false
  tryResult = result && !result.cancelled ? result : null
  redrawTry()
  // Its time is a measurement now: the facts line may change.
  loadWhenFree()
}

function cancelTry() {
  tryToken++
  trying = false
  void satz.invoke('cleanup:cancel-try')
  redrawTry()
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
  info = await satz.invoke('settings:get', shownProvider, shownCleanup)
  shownProvider = info.shown
  shownCleanup = info.cleanup.shown
  document.documentElement.lang = info.prefs.language
  document.dispatchEvent(new CustomEvent('satz-language', { detail: info.prefs.language }))
  render()
}

// A new model list draws the page again, but not under someone typing: that
// emptied a half-typed word. It waits until the field is left, once.
const afterBlur = new LoadAfterBlur()
function loadWhenFree() {
  const field = document.activeElement
  const typing = (field instanceof HTMLInputElement && field.type !== 'checkbox' && field.type !== 'radio') || field instanceof HTMLTextAreaElement
  if (typing && field.closest('#settings-page')) afterBlur.later(field, load)
  else load()
}
satz.on('models:changed', loadWhenFree)
satz.on('local:changed', loadWhenFree)
// Opened again (from the tray, the history or its tab): the provider in use, not the one looked at last.
document.addEventListener('satz-page-opened', event => {
  if ((event as CustomEvent).detail !== 'settings' || shownProvider === null) return
  if (shownProvider === info?.prefs.provider && shownCleanup === info?.cleanup.inUse) return
  shownProvider = null
  shownCleanup = null
  editingKey = false
  typingModel = false
  keyProblem = ''
  editingCleanupKey = false
  typingCleanupModel = false
  cleanupKeyProblem = ''
  load()
})
load()

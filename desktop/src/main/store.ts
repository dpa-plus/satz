import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { setLanguage, systemLanguage, type Language } from '../core/language'
import { standardReplacements, swapPredefined, type Replacement } from '../core/replacements'
import type { Provider, TranscriberSettings } from '../core/transcriber'

/**
 * What the user can adjust, the API keys, and the last few transcripts. Plain
 * files in the app's data folder, like the Mac app: keys in a file only the
 * user can read, not the system keychain, which asks for passwords at the
 * worst moment.
 */
export interface Preferences {
  provider: Provider
  models: Partial<Record<Provider, string>>
  customBaseURL: string
  words: string[]
  triggerMode: 'tap' | 'hold'
  language: Language
  /** null: the same as `language` until chosen. */
  spokenLanguage: Language | null
  /** What Canary listens for, which cannot tell by itself: one of the languages it writes; null: `spokenLanguage` (core/localModels.ts, toldLanguage). */
  toldLanguage?: string | null
  replacements: Replacement[]
  usesReplacements: boolean
  removesFillers: boolean
  /** The transcript stays on the clipboard after pasting, instead of what was copied before. */
  keepsOnClipboard: boolean
  /** Music and videos pause while dictating, and play on afterwards. */
  pausesMedia: boolean
  /** How many dictations the history keeps: 0 none, KEEP_ALL every one. */
  historyLimit: number
  showsText: boolean
  /** Where the user dragged the card, from its starting spot. */
  cardSpot: { x: number; y: number } | null
  startAtLoginDefaulted: boolean
  /** The user's choice, so the entry follows satz when it moves (Windows keys it on the exe's path). */
  startsAtLogin?: boolean
}

export interface HistoryEntry { id: string; text: string; date: string; pasted: boolean }

export const STANDARD_HISTORY = 50
/** "All": no limit anyone would reach. */
export const KEEP_ALL = 100_000
/** The choices in the settings, 0 being "keep none". */
export const HISTORY_LIMITS = [0, 10, 50, 200, KEEP_ALL]
const newId = () => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`

const dir = () => app.getPath('userData')
const file = (name: string) => path.join(dir(), name)

function readJSON<T>(name: string): T | null {
  try { return JSON.parse(fs.readFileSync(file(name), 'utf8')) as T } catch { return null }
}

/**
 * Written beside the file (private from the start where it holds text) and
 * moved over it in one step: written in place, an interrupted write reset the
 * settings, emptied the history or lost the key.
 */
export function writeAtomically(target: string, content: string, mode?: number) {
  const temporary = `${target}.new`
  fs.rmSync(temporary, { force: true })
  fs.writeFileSync(temporary, content, mode !== undefined ? { mode } : undefined)
  fs.renameSync(temporary, target)
}

function writeJSON(name: string, value: unknown, mode?: number) {
  fs.mkdirSync(dir(), { recursive: true })
  writeAtomically(file(name), JSON.stringify(value, null, 2), mode)
}

export class Store {
  prefs: Preferences
  history: HistoryEntry[]

  constructor() {
    const language = systemLanguage(app.getLocale())
    const stored = readJSON<Partial<Preferences>>('preferences.json') ?? {}
    this.prefs = {
      provider: 'openrouter',
      models: {},
      customBaseURL: '',
      words: [],
      triggerMode: 'tap',
      language,
      spokenLanguage: null,
      replacements: standardReplacements(stored.spokenLanguage ?? stored.language ?? language),
      usesReplacements: true,
      removesFillers: true,
      keepsOnClipboard: false,
      pausesMedia: true,
      historyLimit: STANDARD_HISTORY,
      showsText: true,
      cardSpot: null,
      startAtLoginDefaulted: false,
      ...stored,
    }
    setLanguage(this.prefs.language)
    // Entries from before 0.1.2 have no id yet.
    this.history = (readJSON<HistoryEntry[]>('history.json') ?? [])
      .map(entry => ({ ...entry, id: entry.id ?? newId() }))
      .slice(0, this.prefs.historyLimit)
  }

  save() { writeJSON('preferences.json', this.prefs) }

  update(change: Partial<Preferences>) {
    const before = this.prefs
    this.prefs = { ...before, ...change }
    // The predefined Ersetzungen follow the spoken language; the user's own stay.
    const oldSpoken = before.spokenLanguage ?? before.language
    const newSpoken = this.prefs.spokenLanguage ?? this.prefs.language
    if (oldSpoken !== newSpoken && change.replacements === undefined) {
      this.prefs.replacements = swapPredefined(this.prefs.replacements, oldSpoken, newSpoken)
    }
    setLanguage(this.prefs.language)
    this.save()
  }

  get spokenLanguage(): Language { return this.prefs.spokenLanguage ?? this.prefs.language }

  transcriberSettings(): TranscriberSettings {
    const rules = this.prefs.usesReplacements ? this.prefs.replacements : []
    return {
      provider: this.prefs.provider,
      model: this.prefs.models[this.prefs.provider] ?? '',
      customBaseURL: this.prefs.customBaseURL,
      // Trigger words go in too: a made-up one only survives transcription
      // if the model was told to expect it.
      vocabulary: [...this.prefs.words, ...rules.filter(r => r.isOn).map(r => r.spoken)],
      removesFillers: this.prefs.removesFillers,
    }
  }

  get activeReplacements(): Replacement[] { return this.prefs.usesReplacements ? this.prefs.replacements : [] }

  get endpointMissing() {
    if (this.prefs.provider !== 'custom') return false
    try { return !new URL(this.prefs.customBaseURL.trim()).host } catch { return true }
  }

  // MARK: - Keys

  private keyFile(provider: Provider) { return path.join(dir(), 'keys', provider) }

  readKey(provider = this.prefs.provider): string | null {
    try { return fs.readFileSync(this.keyFile(provider), 'utf8').trim() || null } catch { return null }
  }

  hasKey(provider = this.prefs.provider) { return this.readKey(provider) !== null }

  storeKey(key: string, provider = this.prefs.provider) {
    fs.mkdirSync(path.join(dir(), 'keys'), { recursive: true, mode: 0o700 })
    const target = this.keyFile(provider)
    writeAtomically(target, key.trim(), 0o600)
  }

  // MARK: - History

  addHistory(text: string, pasted: boolean) {
    // Off means nothing is written, not written and then forgotten.
    if (!text || this.prefs.historyLimit === 0) return
    this.history = [{ id: newId(), text, date: new Date().toISOString(), pasted }, ...this.history].slice(0, this.prefs.historyLimit)
    writeJSON('history.json', this.history, 0o600)
  }

  /** Lowering it drops the oldest at once, from disk too. */
  setHistoryLimit(limit: number) {
    this.update({ historyLimit: limit })
    if (limit === 0) return this.clearHistory()
    this.history = this.history.slice(0, limit)
    writeJSON('history.json', this.history, 0o600)
  }

  removeHistory(id: string) {
    this.history = this.history.filter(entry => entry.id !== id)
    writeJSON('history.json', this.history, 0o600)
  }

  clearHistory() {
    this.history = []
    try { fs.rmSync(file('history.json')) } catch { /* already gone */ }
  }
}

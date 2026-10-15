import { app } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { customAddress, keyRefusal } from '../core/browse'
import { historyFields, type CleanupLevel } from '../core/cleanup'
import { cleanupAccounts, type CleanupProviderId } from '../core/cleanupProviders'
import { readHistory, type HistoryEntry, type HistoryPersistenceIssue, type HistoryPersistenceResult } from '../core/history'
import { setLanguage, systemLanguage, type Language } from '../core/language'
import { standardReplacements, swapPredefined, type Replacement } from '../core/replacements'
import type { CleanupOutcome } from '../core/session'
import { defaultMicrosoftRegion, microsoftHost, type Provider, type TranscriberSettings } from '../core/transcriber'

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
  /** Microsoft: the region of the Speech resource, and optionally its own address, which wins (core/transcriber.ts, microsoftHost). */
  microsoftRegion: string
  microsoftEndpoint: string
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
  /** How many dictations the history keeps: 0 none, KEEP_ALL every one (core/historyLimits.ts). */
  historyLimit: number
  showsText: boolean
  /** Where the user dragged the card, from its starting spot. */
  cardSpot: { x: number; y: number } | null
  startAtLoginDefaulted: boolean
  /** The user's choice, so the entry follows satz when it moves (Windows keys it on the exe's path). */
  startsAtLogin?: boolean
  /** Cleanup: a language model edits the text before it is pasted. Off until the user turns it on. */
  cleansText: boolean
  cleanupLevel: CleanupLevel
  /** The user's own instruction, for the level "custom". */
  cleanupPrompt: string
  /** Where cleanup goes; null: worked out from the transcription provider until the user picks one (core/cleanupProviders.ts). */
  cleanupProvider: CleanupProviderId | null
  /** Each cleanup provider's model and address, kept per provider like `models`. */
  cleanupModels: Partial<Record<CleanupProviderId, string>>
  cleanupAddresses: Partial<Record<CleanupProviderId, string>>
}

export type { HistoryEntry }

export const STANDARD_HISTORY = 50
const newId = () => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`

const dir = () => app.getPath('userData')
const file = (name: string) => path.join(dir(), name)

function readJSON<T>(name: string): T | null {
  try { return JSON.parse(fs.readFileSync(file(name), 'utf8')) as T } catch { return null }
}

const isEntry = (entry: unknown): entry is HistoryEntry =>
  typeof entry === 'object' && entry !== null && typeof (entry as HistoryEntry).text === 'string'

/**
 * The history on disk, and whether the file must be left alone this run.
 * One that is not a list of entries (cut off, or written by something else)
 * or that exists but cannot be read (permissions, a lock, a folder in its
 * place) is moved aside, kept for the user, and satz starts with an empty
 * one: read as it was, `{}` stopped satz's start halfway, and a file that
 * could not be read was taken for none and written over by the next
 * dictation. If it cannot be moved either, it stays where it is and nothing
 * is written to it (`kept`).
 */
function readHistoryFile(log: (message: string) => void): { entries: HistoryEntry[]; kept: boolean } {
  const target = file('history.json')
  const setAside = (why: 'broken' | 'unreadable') => {
    // Colons are not allowed in a Windows file name.
    const aside = `${target}.${why}-${new Date().toISOString().replace(/[:.]/g, '-')}`
    try {
      fs.renameSync(target, aside)
      log(`history: history.json could not be read, moved to ${path.basename(aside)}; starting with an empty history`)
      return { entries: [], kept: false }
    } catch (error) {
      log(`history: history.json could neither be read nor moved aside (${(error as Error).message}); it is left as it is and no history is written this time`)
      return { entries: [], kept: true }
    }
  }
  let text: string
  try {
    text = fs.readFileSync(target, 'utf8')
  } catch (error) {
    // No history yet is the ordinary case; anything else is a file that is there and cannot be read.
    return (error as NodeJS.ErrnoException).code === 'ENOENT' ? { entries: [], kept: false } : setAside('unreadable')
  }
  try {
    const entries: unknown = JSON.parse(text)
    if (Array.isArray(entries) && entries.every(isEntry)) return { entries, kept: false }
  } catch { /* moved aside below */ }
  return setAside('broken')
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
  persistenceIssue: HistoryPersistenceIssue | null = null
  /** history.json is there but can be neither read nor moved aside: it stays as it is, and the history lives in memory until satz quits (readHistory logged it, once). */
  private historyKept: boolean

  constructor(log: (message: string) => void = () => {}) {
    const language = systemLanguage(app.getLocale())
    const stored = readJSON<Partial<Preferences>>('preferences.json') ?? {}
    this.prefs = {
      provider: 'openrouter',
      models: {},
      customBaseURL: '',
      microsoftRegion: defaultMicrosoftRegion,
      microsoftEndpoint: '',
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
      cleansText: false,
      cleanupLevel: 'light',
      cleanupPrompt: '',
      cleanupProvider: null,
      cleanupModels: {},
      cleanupAddresses: {},
      ...stored,
    }
    setLanguage(this.prefs.language)
    const read = readHistoryFile(log)
    this.historyKept = read.kept
    this.persistenceIssue = read.kept ? 'protected' : null
    this.history = readHistory(read.entries, this.prefs.historyLimit, newId)
    if (this.prefs.historyLimit === 0) this.clearHistory()
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
      // The address as it was checked (endpointMissing), not a second reading of it.
      customBaseURL: customAddress(this.prefs.customBaseURL) ?? '',
      microsoftRegion: this.prefs.microsoftRegion,
      microsoftEndpoint: this.prefs.microsoftEndpoint,
      // Trigger words go in too: a made-up one only survives transcription
      // if the model was told to expect it.
      vocabulary: [...this.prefs.words, ...rules.filter(r => r.isOn).map(r => r.spoken)],
      removesFillers: this.prefs.removesFillers,
    }
  }

  get activeReplacements(): Replacement[] { return this.prefs.usesReplacements ? this.prefs.replacements : [] }

  /** Custom without an address, or Microsoft with an own address that is none (or no region to fall back on). */
  get endpointMissing() {
    if (this.prefs.provider === 'microsoft') return microsoftHost(this.prefs.microsoftRegion, this.prefs.microsoftEndpoint) === null
    if (this.prefs.provider !== 'custom') return false
    return customAddress(this.prefs.customBaseURL) === null
  }

  // MARK: - Keys

  private keyFile(provider: Provider) { return path.join(dir(), 'keys', provider) }

  readKey(provider = this.prefs.provider): string | null {
    try { return fs.readFileSync(this.keyFile(provider), 'utf8').trim() || null } catch { return null }
  }

  hasKey(provider = this.prefs.provider) { return this.readKey(provider) !== null }

  /** Throws, saying why, for a key with a character no request can carry (core/browse.ts, keyRefusal). */
  storeKey(key: string, provider = this.prefs.provider) {
    const refusal = keyRefusal(key, this.prefs.language)
    if (refusal) throw new Error(refusal)
    fs.mkdirSync(path.join(dir(), 'keys'), { recursive: true, mode: 0o700 })
    const target = this.keyFile(provider)
    writeAtomically(target, key.trim(), 0o600)
  }

  /**
   * Cleanup's keys, by the file they live in: a provider that also
   * transcribes shares its file, so one key serves both. Only the accounts
   * of core/cleanupProviders.ts, never a name from elsewhere.
   */
  readAccount(account: string): string | null {
    if (!cleanupAccounts.includes(account)) return null
    try { return fs.readFileSync(path.join(dir(), 'keys', account), 'utf8').trim() || null } catch { return null }
  }

  storeAccount(account: string, key: string) {
    if (!cleanupAccounts.includes(account)) return
    const refusal = keyRefusal(key, this.prefs.language)
    if (refusal) throw new Error(refusal)
    fs.mkdirSync(path.join(dir(), 'keys'), { recursive: true, mode: 0o700 })
    writeAtomically(path.join(dir(), 'keys', account), key.trim(), 0o600)
  }

  // MARK: - History

  addHistory(text: string, pasted: boolean, cleanup?: CleanupOutcome): HistoryPersistenceResult {
    // Off means nothing is written, not written and then forgotten.
    if (!text || this.prefs.historyLimit === 0) return { status: 'off' }
    this.history = [{ id: newId(), text, date: new Date().toISOString(), pasted, ...historyFields(text, cleanup) }, ...this.history].slice(0, this.prefs.historyLimit)
    return this.writeHistory()
  }

  /** Every write of history.json goes through here: none while the file is one satz could not read and must not replace. */
  private writeHistory(): HistoryPersistenceResult {
    if (this.historyKept) return this.historyFailure('protected')
    let ownedTemporary: string | null = null
    try {
      fs.mkdirSync(dir(), { recursive: true })
      const temporary = file(`.history-${randomUUID()}.new`)
      // Exclusive creation proves ownership: a failed save must not remove a
      // preexisting file or leave its transcript in an abandoned temporary.
      const handle = fs.openSync(temporary, 'wx', 0o600)
      ownedTemporary = temporary
      try { fs.writeFileSync(handle, JSON.stringify(this.history, null, 2)) } finally { fs.closeSync(handle) }
      fs.renameSync(temporary, file('history.json'))
      ownedTemporary = null
      this.persistenceIssue = null
      return { status: 'saved' }
    } catch { return this.historyFailure('saveFailed') }
    finally { if (ownedTemporary) { try { fs.rmSync(ownedTemporary) } catch { /* the failure remains visible */ } } }
  }

  private historyFailure(issue: HistoryPersistenceIssue): HistoryPersistenceResult {
    this.persistenceIssue = issue
    return { status: 'failed', issue }
  }

  /** Lowering it drops the oldest at once, from disk too. */
  setHistoryLimit(limit: number): HistoryPersistenceResult {
    const previous = this.prefs
    try { this.update({ historyLimit: limit }) }
    catch {
      this.prefs = previous
      // The setting notice must not hide that existing text is only in
      // memory, or that the previous file could not be cleared or read.
      this.persistenceIssue ??= 'limitFailed'
      return { status: 'failed', issue: 'limitFailed' }
    }
    if (limit === 0) return this.clearHistory()
    this.history = this.history.slice(0, limit)
    return this.writeHistory()
  }

  removeHistory(id: string) {
    this.history = this.history.filter(entry => entry.id !== id)
    return this.writeHistory()
  }

  clearHistory(): HistoryPersistenceResult {
    this.history = []
    // The file that was not readable holds what the user cannot see here: not deleted either.
    if (this.historyKept) return this.historyFailure('protected')
    try {
      fs.rmSync(file('history.json'))
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') return this.historyFailure('clearFailed')
    }
    this.persistenceIssue = null
    return { status: 'saved' }
  }
}

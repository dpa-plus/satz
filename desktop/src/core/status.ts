import type { Language } from './language'

/**
 * Whether satz can take a dictation, said where the user looks without
 * dictating: the tray's tooltip and first menu line, and Settings' "Status".
 * Before, "No key" showed only on the card, after the shortcut, and meant
 * three things (none saved, an empty file, a file that could not be read).
 */

/** How this satz was started; the log notes it, so a start at login can be told from one by hand. */
export type StartedBy = 'login' | 'toggle' | 'settings' | 'hand'

export function startedBy(args: readonly string[]): StartedBy {
  if (args.includes('--login')) return 'login'
  if (args.includes('--toggle')) return 'toggle'
  if (args.includes('--settings')) return 'settings'
  return 'hand'
}

/** Why there is no key: none saved, an empty file, or one there that could not be read (the system's code). */
export type KeyState = { kind: 'saved' } | { kind: 'missing' } | { kind: 'empty' } | { kind: 'unreadable'; code: string }

const say = (language: Language, de: string, en: string) => (language === 'de' ? de : en)

/** Two or three words, for the card and the tray. A file that could not be read is not "No key": typing the key again does not help. */
export function keyShort(state: KeyState, language: Language): string | null {
  if (state.kind === 'saved') return null
  if (state.kind === 'unreadable') return say(language, 'Schlüssel nicht lesbar', 'Key unreadable')
  return say(language, 'Kein Schlüssel', 'No key')
}

/** The line under the key field in Settings, where a sentence fits; null where the field says enough. */
export function keySentence(state: KeyState, language: Language): string | null {
  if (state.kind === 'unreadable') return say(language,
    `Der Schlüssel ist gespeichert, konnte aber nicht gelesen werden (${state.code}). satz versucht es bei jedem Diktat neu; hilft das nicht, satz beenden und neu öffnen.`,
    `The key is saved but could not be read (${state.code}). satz tries again with every dictation; if that does not help, quit satz and open it again.`)
  if (state.kind === 'empty') return say(language, 'Die Schlüsseldatei ist leer. Bitte den Schlüssel neu eingeben.', 'The key file is empty. Please enter the key again.')
  return null
}

/**
 * The tray's tooltip: the version, and ready or what is missing. Windows
 * cuts a tooltip at 127 characters; this stays well under.
 */
export function trayTooltip(version: string, problem: string | null, shortcut: string | null, language: Language): string {
  if (problem) return `satz ${version}: ${problem}`
  return `satz ${version}: ${say(language, 'bereit', 'ready')}${shortcut ? ` (${shortcut})` : ''}`
}

/** The shortcut in a few words, for the tooltip; null where right Ctrl does not start a dictation. */
export function shortcutWords(works: boolean, language: Language): string | null {
  return works ? say(language, 'rechte Strg zweimal', 'right Ctrl twice') : null
}

/** Settings' "Status" rows: what the log, the settings file and start at login are doing, only where something is wrong. */
export interface Diagnostics {
  version: string
  platform: string
  folder: string
  startedBy: StartedBy
  /** The code of the last line satz's folder refused, and where the log went instead. */
  log: { file: string; problem: string | null; fallback: string }
  /** preferences.json could not be read at the start (its code): the standard settings are in use and changes are not saved. */
  preferencesProblem: string | null
  /** Windows: start at login is on in satz, but switched off in Windows' own list of startup apps. */
  startBlocked: boolean
}

export function diagnosticsLines(d: Diagnostics, language: Language): { text: string; problem: boolean }[] {
  const system = d.platform === 'win32' ? 'Windows' : d.platform === 'linux' ? 'Linux' : d.platform
  const started = { login: say(language, 'beim Anmelden', 'at login'), toggle: 'satz --toggle', settings: 'satz --settings', hand: say(language, 'von Hand', 'by hand') }[d.startedBy]
  const lines = [{ text: `satz ${d.version} · ${system} · ${say(language, 'gestartet', 'started')} ${started}`, problem: false }]
  if (d.log.problem) lines.push({ problem: true, text: say(language,
    `Das Protokoll konnte nicht in den satz-Ordner schreiben (${d.log.problem}); es steht jetzt in ${d.log.fallback}.`,
    `The log could not be written to satz's folder (${d.log.problem}); it is now in ${d.log.fallback}.`) })
  if (d.preferencesProblem) lines.push({ problem: true, text: say(language,
    `Die Einstellungen konnten beim Start nicht gelesen werden (${d.preferencesProblem}). satz nutzt bis dahin die Standardwerte und speichert keine Änderungen; es versucht es weiter.`,
    `Settings could not be read at start (${d.preferencesProblem}). Until they can, satz uses the standard ones and saves no changes; it keeps trying.`) })
  if (d.startBlocked) lines.push({ problem: true, text: say(language,
    'Windows startet satz beim Anmelden nicht: in den Windows-Einstellungen unter Apps › Autostart ist satz ausgeschaltet. Dort einschalten, oder hier „Beim Anmelden starten“ aus- und wieder einschalten.',
    'Windows does not start satz at login: it is switched off in Windows Settings under Apps › Startup. Switch it on there, or switch “Start at login” off and on again here.') })
  return lines
}

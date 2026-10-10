import type { Language } from './language'
import type { Provider } from './transcriber'

/**
 * Looking is not switching. The provider menu in Settings shows a provider's
 * key, models and fields; dictations keep going to the one in use until
 * "Use …" is pressed. Picking "Local" just to see what it offers had switched
 * every dictation to it, and Eli found out after closing the window.
 */

/** The menu's order. */
export const providerOrder: Provider[] = ['openrouter', 'openai', 'groq', 'custom', 'local']

const names: Record<Provider, Record<Language, string>> = {
  openrouter: { de: 'OpenRouter', en: 'OpenRouter' },
  openai: { de: 'OpenAI', en: 'OpenAI' },
  groq: { de: 'Groq', en: 'Groq' },
  custom: { de: 'Eigener', en: 'Custom' },
  local: { de: 'Lokal', en: 'Local' },
}

/** An option of the menu; the provider in use says so, wherever the menu stands. */
export function providerLabel(provider: Provider, inUse: Provider, language: Language): string {
  const name = names[provider][language]
  return provider === inUse ? `${name} ${language === 'de' ? '(in Benutzung)' : '(in use)'}` : name
}

/**
 * The row under the menu while it shows a provider dictations do not go to:
 * where they go, and the one button that switches. None while it shows the
 * provider in use.
 */
export function switchRow(shown: Provider, inUse: Provider, language: Language): { text: string; button: string } | null {
  if (shown === inUse) return null
  // "Eigener" and "Lokal" are the menu's words, not names: quoted, they read as such in a sentence.
  const generic = inUse === 'custom' || inUse === 'local'
  const where = generic ? (language === 'de' ? `„${names[inUse].de}“` : `"${names[inUse].en}"`) : names[inUse][language]
  return language === 'de'
    ? { text: `Diktate gehen an ${where}.`, button: `${shown === 'custom' ? 'Eigenen' : names[shown].de} benutzen` }
    : { text: `Dictation goes to ${where}.`, button: `Use ${names[shown].en}` }
}

/**
 * What a downloaded local model's row offers: "In use" only for the model
 * dictations go to, so only while Local is the provider in use. Otherwise the
 * chosen model reads "Use" like the others: it is not in use.
 */
export const localRowAction = (id: string, chosen: string, localInUse: boolean): 'in-use' | 'use' =>
  localInUse && id === chosen ? 'in-use' : 'use'

/**
 * "Use" on a local model: it becomes Local's model, and while another
 * provider is in use, Local becomes the provider too. Pressing it is the
 * explicit choice that picking Local in the menu is not.
 */
export function useLocalModel<Models extends object>(id: string, models: Models, localInUse: boolean): { models: Models & { local: string }; provider?: 'local' } {
  const change = { models: { ...models, local: id } }
  return localInUse ? change : { ...change, provider: 'local' }
}

/**
 * The line under the shortcut when right Ctrl cannot start a dictation:
 * Wayland without access to the keyboard devices, or no keyboard hook (the
 * prebuilt one is x86-64 only, so ARM Linux under X11 has none). Empty while
 * the shortcut works. "satz --toggle" is the way out in both.
 */
export function shortcutHint(shortcutWorks: boolean, wayland: boolean, language: Language): string {
  if (shortcutWorks) return ''
  if (wayland) {
    return language === 'de'
      ? 'Wayland lässt Apps die Tastatur nicht mitlesen. Entweder in den System-Einstellungen eine Tastenkombination anlegen, die „satz --toggle“ ausführt, oder einmal „sudo usermod -aG input $USER“ ausführen und neu anmelden.'
      : 'Wayland does not let apps watch the keyboard. Either add a keyboard shortcut in the system settings that runs "satz --toggle", or run "sudo usermod -aG input $USER" once and sign in again.'
  }
  return language === 'de'
    ? 'Die rechte Strg-Taste startet hier kein Diktat, der Tastatur-Hook ließ sich nicht laden. Stattdessen eine Tastenkombination anlegen, die „satz --toggle“ ausführt: unter Linux in den System-Einstellungen, unter Windows als Verknüpfung mit Tastenkürzel.'
    : 'Right Ctrl does not start a dictation here, the keyboard hook could not be loaded. Add a keyboard shortcut that runs "satz --toggle" instead: in the system settings on Linux, as a shortcut with a shortcut key on Windows.'
}

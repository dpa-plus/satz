import { allowsAddress } from './address'
import type { Language } from './language'
import { keyIsUsable, microsoftHost, needsKey, type Provider } from './transcriber'

// The rule for where a key may be sent lives in address.ts (transcriber.ts needs it too, and this file imports that one).
export { allowsAddress, isOnOwnNetwork } from './address'

/**
 * Looking is not switching. The provider menu in Settings shows a provider's
 * key, models and fields; dictations keep going to the one in use until
 * "Use …" is pressed. Picking "Local" just to see what it offers had switched
 * every dictation to it, and Eli found out after closing the window.
 */

/** The menu's order. */
export const providerOrder: Provider[] = ['openrouter', 'openai', 'groq', 'microsoft', 'google', 'custom', 'local']

const names: Record<Provider, Record<Language, string>> = {
  openrouter: { de: 'OpenRouter', en: 'OpenRouter' },
  openai: { de: 'OpenAI', en: 'OpenAI' },
  groq: { de: 'Groq', en: 'Groq' },
  microsoft: { de: 'Microsoft', en: 'Microsoft' },
  google: { de: 'Google', en: 'Google' },
  custom: { de: 'Eigener', en: 'Custom' },
  local: { de: 'Lokal', en: 'Local' },
}

/** An option of the menu; the provider in use says so, wherever the menu stands. */
export function providerLabel(provider: Provider, inUse: Provider, language: Language): string {
  const name = names[provider][language]
  return provider === inUse ? `${name} ${language === 'de' ? '(in Benutzung)' : '(in use)'}` : name
}

/**
 * Custom's address, as it is checked and as the audio goes to it: https, or
 * http on the user's own network (address.ts), with a host. The key travels
 * with the audio. "ftp://…" has a host too: it made Custom "in use", and
 * every dictation then failed. The Mac's rule (ProviderAddress), and
 * Microsoft's own address follows it too (microsoftHost).
 */
export function customAddress(typed: string): string | null {
  // A preferences file edited by hand may hold anything here.
  const address = typeof typed === 'string' ? typed.trim() : ''
  let url: URL
  try { url = new URL(address) } catch { return null }
  return allowsAddress(url) ? address : null
}

/** Why a typed address was refused: the rule in one line, the same on every platform. */
export const addressRefusal = (language: Language) => language === 'de'
  ? 'Diese Adresse geht nicht: https, oder http nur im eigenen Netz.'
  : 'This address won\'t work: https, or http only on your own network.'

/**
 * Why a key cannot be saved, null when it can: a line break or another
 * character a request header cannot carry, pasted along with it. Saved, it
 * failed every dictation, and the error quoted the whole key into the log.
 */
export function keyRefusal(key: string, language: Language): string | null {
  if (keyIsUsable(key.trim())) return null
  return language === 'de'
    ? 'Im Schlüssel steckt ein Zeichen, das nicht dazugehört, etwa ein Zeilenumbruch. Bitte nur den Schlüssel einfügen.'
    : 'The key contains a character that does not belong in it, such as a line break. Please paste just the key.'
}

/**
 * What a provider still lacks before it can take a dictation. `address` is
 * none typed yet; `addressRefused` one that is typed and cannot be used, told
 * apart so the message says why instead of asking for what is already there.
 */
export type Need = 'key' | 'address' | 'addressRefused' | 'model' | 'region' | 'localModel'

/** Whether anything is typed in a field: an address that is typed and refused is told apart from one not yet typed. */
const typed = (text: string | undefined) => typeof text === 'string' && text.trim() !== ''

/**
 * What a provider needs, ported from the Mac's ProviderReadiness: a key for
 * every one but Local; Custom also an address and a model; Microsoft a region
 * (or its own address, which wins, and which must be one if it is typed);
 * Local the chosen model on this computer. `hasKey` is the shown provider's
 * key, or for Local that its model is downloaded. In the order they are filled in.
 */
export function providerNeeds(provider: Provider, facts: { hasKey: boolean; customBaseURL: string; model: string; microsoftRegion?: string; microsoftEndpoint?: string }): Need[] {
  const needs: Need[] = []
  if (provider === 'local') return facts.hasKey ? [] : ['localModel']
  if (needsKey(provider) && !facts.hasKey) needs.push('key')
  if (provider === 'custom') {
    if (customAddress(facts.customBaseURL) === null) needs.push(typed(facts.customBaseURL) ? 'addressRefused' : 'address')
    if (!facts.model.trim()) needs.push('model')
  }
  if (provider === 'microsoft' && microsoftHost(facts.microsoftRegion, facts.microsoftEndpoint) === null) {
    needs.push(typed(facts.microsoftEndpoint) ? 'addressRefused' : 'region')
  }
  return needs
}

/**
 * "Erst den Schlüssel eintragen", naming everything missing at once; null when
 * nothing is. An address that is typed but refused is not "missing": it is
 * told why, after what else is still to fill in.
 */
export function needsMessage(needs: Need[], language: Language): string | null {
  if (needs.length === 1 && needs[0] === 'localModel') return language === 'de' ? 'Erst ein Modell laden.' : 'Download a model first.'
  const words = {
    key: { de: 'Schlüssel', en: 'key', deWhole: 'den Schlüssel', enWhole: 'the key' },
    address: { de: 'Adresse', en: 'address', deWhole: 'die Adresse', enWhole: 'the address' },
    model: { de: 'Modell', en: 'model', deWhole: 'das Modell', enWhole: 'the model' },
    region: { de: 'Region', en: 'region', deWhole: 'die Region', enWhole: 'the region' },
  }
  const named = needs.filter((need): need is keyof typeof words => need in words)
  const why = needs.includes('addressRefused') ? addressRefusal(language) : null
  if (named.length === 0) return why
  // A region is picked from a menu, the rest is typed.
  const picked = named.every(need => need === 'region')
  const list = (items: string[], and: string) => (items.length > 1 ? `${items.slice(0, -1).join(', ')} ${and} ${items[items.length - 1]}` : items[0])
  const ask = language === 'de'
    ? (named.length === 1 ? `Erst ${words[named[0]].deWhole} ${picked ? 'wählen' : 'eintragen'}.` : `Erst ${list(named.map(need => words[need].de), 'und')} eintragen.`)
    : (named.length === 1 ? `${picked ? 'Choose' : 'Enter'} ${words[named[0]].enWhole} first.` : `Enter the ${list(named.map(need => words[need].en), 'and')} first.`)
  return why ? `${ask} ${why}` : ask
}

/**
 * The row under the menu while it shows a provider dictations do not go to:
 * where they go, and the one button that switches, which is offered only once
 * the provider has what it needs (`needs`, from providerNeeds): then the row
 * says what is missing instead. None while it shows the provider in use.
 */
export function switchRow(shown: Provider, inUse: Provider, language: Language, needs: Need[] = []): { text: string; button: string | null } | null {
  if (shown === inUse) return null
  // "Eigener" and "Lokal" are the menu's words, not names: quoted, they read as such in a sentence.
  const generic = inUse === 'custom' || inUse === 'local'
  const where = generic ? (language === 'de' ? `„${names[inUse].de}“` : `"${names[inUse].en}"`) : names[inUse][language]
  const goesTo = language === 'de' ? `Diktate gehen an ${where}.` : `Dictation goes to ${where}.`
  const missing = needsMessage(needs, language)
  if (missing) return { text: `${goesTo} ${missing}`, button: null }
  return { text: goesTo, button: language === 'de' ? `${shown === 'custom' ? 'Eigenen' : names[shown].de} benutzen` : `Use ${names[shown].en}` }
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

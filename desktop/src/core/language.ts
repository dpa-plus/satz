/** German or English, for the app's own words. */
export type Language = 'de' | 'en'

let current: Language = 'en'

export function setLanguage(language: Language) {
  current = language
}

export function currentLanguage(): Language {
  return current
}

/** The system's language, German if it is German, English otherwise. */
export function systemLanguage(locale: string): Language {
  return locale.toLowerCase().startsWith('de') ? 'de' : 'en'
}

/** The same text in both languages; the current one is returned. */
export function de(german: string, english: string): string {
  return current === 'de' ? german : english
}

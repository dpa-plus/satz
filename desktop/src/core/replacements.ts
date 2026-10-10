import type { Language } from './language'

/**
 * A word you say that becomes something else on the page: "Klammer auf"
 * becomes "(", "neue Zeile" a line break.
 *
 * Transcription models write spoken punctuation out as words, so this is plain
 * find and replace on the transcript. No second model, nothing guessed.
 * Ported from the Mac app (SatzKit/Text/Replacements.swift).
 */
export interface Replacement {
  id: string
  /** What you say, written the way the model spells it. */
  spoken: string
  /** What lands in the text. */
  written: string
  isOn: boolean
}

let counter = 0
const newID = () => `r${Date.now().toString(36)}${(counter++).toString(36)}`

export function replacement(spoken: string, written: string, isOn = true): Replacement {
  return { id: newID(), spoken, written, isOn }
}

/**
 * The predefined rules for one spoken language. Mostly two-word phrases, so
 * normal speech does not trigger them; single words that are also everyday
 * words ("Punkt", "comma") start switched off.
 */
export function standardReplacements(language: Language): Replacement[] {
  if (language === 'de') {
    return [
      replacement('Klammer auf', '('),
      replacement('Klammer zu', ')'),
      replacement('Zitat Anfang', '"'),
      replacement('Zitat Ende', '"'),
      replacement('neue Zeile', '\n'),
      replacement('neuer Absatz', '\n\n'),
      replacement('Doppelpunkt', ':'),
      replacement('Fragezeichen', '?'),
      replacement('Ausrufezeichen', '!'),
      replacement('Punkt', '.', false),
      replacement('Komma', ',', false),
    ]
  }
  return [
    replacement('open bracket', '('),
    replacement('close bracket', ')'),
    replacement('open quote', '"'),
    replacement('close quote', '"'),
    replacement('new line', '\n'),
    replacement('new paragraph', '\n\n'),
    replacement('colon', ':'),
    replacement('question mark', '?'),
    replacement('exclamation mark', '!'),
    replacement('full stop', '.', false),
    replacement('comma', ',', false),
  ]
}

/** The predefined rules of one language make way for the other's; the user's own stay. */
export function swapPredefined(rules: Replacement[], from: Language, to: Language): Replacement[] {
  if (from === to) return rules
  // Shipped only while unchanged: a rule the user turned on or gave another
  // symbol ("Klammer auf" to "[") was dropped by its phrase.
  const shipped = standardReplacements(from)
  const own = rules.filter(rule => !shipped.some(s => s.spoken.toLowerCase() === rule.spoken.toLowerCase() && s.written === rule.written && s.isOn === rule.isOn))
  const ownPhrases = new Set(own.map(r => r.spoken.toLowerCase()))
  return [...standardReplacements(to).filter(r => !ownPhrases.has(r.spoken.toLowerCase())), ...own]
}

/** The spoken side of every rule that is on, for the model's word list. */
export function phrases(rules: Replacement[]): string[] {
  return rules.filter(r => r.isOn).map(r => r.spoken).filter(s => s.trim() !== '')
}

type Kind = 'opener' | 'closer' | 'punctuation' | 'lineBreak' | 'plain'

function kind(written: string, quote: { open: boolean }): Kind {
  switch (written) {
    case '(': case '[': case '{': return 'opener'
    // German quotes open low and close high: the next “ closes.
    case '„': case '‚': quote.open = true; return 'opener'
    case ')': case ']': case '}': return 'closer'
    case '"': case "'": case '“': case '”': case '‘': case '’': case '«': case '»': case '‹': case '›': {
      const result: Kind = quote.open ? 'closer' : 'opener'
      quote.open = !quote.open
      return result
    }
    case '.': case ',': case ':': case ';': case '!': case '?': return 'punctuation'
    default:
      return written !== '' && [...written].every(c => c === '\n' || c === '\r') ? 'lineBreak' : 'plain'
  }
}

// Not '-': with the u flag an escaped hyphen outside [] is a syntax error,
// and one rule like "E-Mail" broke every dictation.
function escape(s: string) {
  return s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')
}

/**
 * Case-insensitive, whole words only. Words may be joined by the commas, full
 * stops or hyphens a model likes to add ("Klammer, auf"), and a letter code
 * like "XX" also matches "xx", "x x" and "X. X.".
 */
function pattern(spoken: string): RegExp | null {
  const words = spoken.split(/\s+/).filter(Boolean)
  if (words.length === 0) return null
  const word = words[0]
  let body: string
  if (words.length === 1 && word.length >= 2 && word.length <= 4 && /^\p{L}+$/u.test(word) && word === word.toUpperCase()) {
    body = [...word].map(c => escape(c) + '\\.?').join('[\\s\\-]*')
  } else {
    body = words.map(escape).join('[\\s,.\\-]+')
  }
  // A rule that still cannot become a pattern is skipped, never the dictation.
  try {
    return new RegExp(`(?<![\\p{L}\\p{N}])${body}(?![\\p{L}\\p{N}])`, 'giu')
  } catch {
    return null
  }
}

interface Match { start: number; end: number; rule: Replacement }

/** Every place a rule matches, left to right, longest phrase first where two overlap. */
function matches(rules: Replacement[], text: string): Match[] {
  const ordered = rules.filter(r => r.isOn).sort((a, b) => b.spoken.length - a.spoken.length)
  const found: Match[] = []
  for (const rule of ordered) {
    const regex = pattern(rule.spoken)
    if (!regex) continue
    for (const m of text.matchAll(regex)) {
      const start = m.index ?? 0, end = start + m[0].length
      if (!found.some(f => f.start < end && start < f.end)) found.push({ start, end, rule })
    }
  }
  return found.sort((a, b) => a.start - b.start)
}

const skip = (s: string, chars: string, from: number) => {
  let i = from
  while (i < s.length && chars.includes(s[i])) i++
  return i
}
const trimTrailing = (s: string, chars: string) => {
  let end = s.length
  while (end > 0 && chars.includes(s[end - 1])) end--
  return s.slice(0, end)
}

/**
 * `text` with every rule that is on applied, and the commas and spaces the
 * model put around the trigger word tidied up: "Funktion, Klammer auf Name,
 * Klammer zu." becomes "Funktion (Name)."
 */
export function applyReplacements(rules: Replacement[], text: string): string {
  let output = ''
  let cursor = 0
  const quote = { open: false }
  // After a line break or a spoken "?" a new sentence starts, but the model
  // wrote what follows in lower case, as the middle of one.
  let capitalizeNext = false
  const addText = (piece: string) => {
    if (capitalizeNext) {
      const index = [...piece].findIndex(c => !/\s/.test(c) && !'"„“”‚‘’»«'.includes(c))
      if (index >= 0) {
        const chars = [...piece]
        chars[index] = chars[index].toUpperCase()
        capitalizeNext = false
        output += chars.join('')
        return
      }
    }
    output += piece
  }

  for (const match of matches(rules, text)) {
    if (match.start < cursor) continue
    addText(text.slice(cursor, match.start))
    let after = match.end
    const written = match.rule.written
    switch (kind(written, quote)) {
      case 'opener':
        output = trimTrailing(output, ' ,')
        if (output !== '' && !output.endsWith('\n')) output += ' '
        output += written
        after = skip(text, ' ,', after)
        break
      case 'closer':
        output = trimTrailing(output, ' ,')
        output += written
        break
      case 'punctuation':
        // The model writes a sentence mark of its own beside the spoken one
        // ("Zeit. Fragezeichen." and "dir Fragezeichen?"): what was said wins,
        // one mark, not ".?" or "? ?".
        output = trimTrailing(output, ' ,.;:!?')
        output += written
        after = skip(text, '.!?'.includes(written) ? ' ,.;:!?' : ' ,.;:', after)
        if (after < text.length && text[after] !== '\n') output += ' '
        capitalizeNext = '.!?'.includes(written)
        break
      case 'lineBreak':
        output = trimTrailing(output, ' ,')
        output += written
        after = skip(text, ' ,.;:', after)
        capitalizeNext = true
        break
      case 'plain':
        output += written
        capitalizeNext = false
    }
    cursor = after
  }
  addText(text.slice(cursor))
  return output
}

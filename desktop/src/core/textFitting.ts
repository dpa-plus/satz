/**
 * Makes a transcript sit naturally where it is inserted.
 *
 * The model treats every recording as a complete utterance: capital letter at
 * the start, full stop at the end. Inserted mid-sentence that reads "eine
 * Funktion Nur die PDF-Dateien., die". So: spaces where the text around needs
 * them, no full stop before a comma or a lowercase word, and a small first
 * letter where it is safe to know. German capitalises nouns, so there only a
 * short list of function words is lowered. Ported from TextFitting.swift.
 *
 * Offsets are UTF-16 code units, like the DOM's.
 */
const isLetter = (c: string) => /\p{L}/u.test(c)
const isLowerLetter = (c: string) => isLetter(c) && c === c.toLowerCase() && c !== c.toUpperCase()

/** The whole character (code point) starting at a UTF-16 index. */
function charAt(text: string, index: number): string {
  const code = text.codePointAt(index)
  return code === undefined ? '' : String.fromCodePoint(code)
}

/** The last character before `location` that is not a space (a line break counts). */
function previousVisible(text: string, location: number): string | null {
  const chars = [...text.slice(0, location)]
  for (let i = chars.length - 1; i >= 0; i--) {
    if (chars[i] === '\n' || !/\s/.test(chars[i])) return chars[i]
  }
  return null
}

/** The first character from `location` on that is not a space. */
function nextVisible(text: string, location: number): string | null {
  for (const c of text.slice(location)) {
    if (c === '\n' || !/\s/.test(c)) return c
  }
  return null
}

/**
 * @param skip characters right after `range` that are not part of the text
 *   (satz's placeholder), to look past.
 */
export function fit(transcript: string, text: string, range: { location: number; length: number }, skip = 0): string {
  // Spaces only: a line break at either end was said ("neue Zeile").
  let result = transcript.replace(/^[ \t]+|[ \t]+$/g, '')
  if (result === '') return ''
  const startsLine = result.startsWith('\n')
  const endsLine = result.endsWith('\n')

  const before = previousVisible(text, range.location)
  const afterIndex = range.location + range.length + skip
  const after = afterIndex < text.length ? charAt(text, afterIndex) : null

  const midSentence = !startsLine && before !== null && !'.!?…:\n'.includes(before)
  if (midSentence) result = lowerFirstWordIfSafe(result, text)

  const next = nextVisible(text, afterIndex)
  // Mid-sentence any letter after the spot means the sentence goes on: "die
  // alte. Rechnung" kept its full stop before every German noun.
  const continues = next !== null && (isLowerLetter(next) || ',;:)'.includes(next) || (midSentence && isLetter(next)))
  if (continues && result.endsWith('.') && !result.endsWith('..')) result = result.slice(0, -1)

  if (range.location > 0 && !startsLine) {
    const previous = [...text.slice(0, range.location)].pop() ?? ''
    // Not before a mark said on its own ("Fragezeichen"): "dir ?".
    const closes = '.,;:!?)]}”«…'.includes([...result][0] ?? '')
    if (!/\s/.test(previous) && !'([{„"“'.includes(previous) && !closes) result = ' ' + result
  }
  if (after !== null && (isLetter(after) || /\p{N}/u.test(after)) && !endsLine) result += ' '
  return result
}

const englishWords = new Set(['the', 'and', 'is', 'are', 'to', 'of', 'a', 'in', 'that', 'it', 'for', 'with', 'this', 'you', 'we', 'on', 'be', 'was', 'have', 'not', 'please', 'all', 'from', 'my', 'me', 'should', 'only', 'write'])
const germanWords = new Set(['der', 'die', 'das', 'und', 'ist', 'sind', 'zu', 'von', 'ein', 'eine', 'in', 'dass', 'es', 'für', 'mit', 'dies', 'du', 'wir', 'auf', 'sein', 'war', 'haben', 'nicht', 'bitte', 'alle', 'aus', 'mir', 'soll', 'nur', 'schreib', 'den', 'dem', 'ich', 'sie'])

/** A rough guess from common words; enough to know whether lowering is safe. */
export function looksEnglish(text: string): boolean {
  let english = 0, german = 0
  for (const word of text.toLowerCase().match(/\p{L}+/gu) ?? []) {
    if (englishWords.has(word)) english++
    if (germanWords.has(word)) german++
  }
  return english > german
}

/** Words that are never capitalised mid-sentence in English. */
export const englishFunctionWords = new Set([
  'the', 'a', 'an', 'and', 'but', 'or', 'nor', 'so', 'yet', 'to', 'of', 'in', 'on', 'at', 'for', 'with', 'from', 'by', 'as', 'about', 'into', 'onto', 'over', 'under', 'after', 'before', 'since', 'until', 'than', 'then', 'that', 'this', 'these', 'those', 'there', 'here', 'it', 'its', 'we', 'you', 'he', 'she', 'they', 'me', 'us', 'him', 'them', 'my', 'your', 'our', 'their', 'his', 'her', 'is', 'are', 'was', 'were', 'be', 'been', 'being', 'am', 'do', 'does', 'did', 'have', 'has', 'had', 'will', 'would', 'can', 'could', 'should', 'shall', 'may', 'might', 'must', 'not', 'no', 'if', 'when', 'while', 'because', 'although', 'though', 'which', 'who', 'whom', 'whose', 'what', 'where', 'why', 'how', 'all', 'some', 'any', 'each', 'every', 'more', 'most', 'very', 'really', 'just', 'also', 'only', 'even', 'still', 'please', 'maybe', 'perhaps', 'too',
])

/**
 * Words that are never capitalised mid-sentence in German. Left out on
 * purpose: "sie" and "ihr", which the formal address writes with a capital
 * ("Vielen Dank für Ihr Anliegen"). A capital left on the "sie" that means
 * "she" is the smaller slip.
 */
export const germanFunctionWords = new Set([
  'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', 'einer', 'eines',
  'und', 'oder', 'aber', 'denn', 'sondern', 'doch', 'nur', 'auch', 'noch', 'schon', 'sehr',
  'mit', 'von', 'zu', 'zum', 'zur', 'für', 'auf', 'in', 'im', 'an', 'am', 'bei', 'beim', 'nach',
  'vor', 'über', 'unter', 'ohne', 'um', 'durch', 'gegen', 'aus', 'seit', 'bis', 'wie', 'als',
  'wenn', 'dass', 'weil', 'ob', 'damit', 'also', 'dann', 'nicht', 'kein', 'keine', 'so',
  'ich', 'du', 'er', 'es', 'wir', 'man', 'mir', 'mich', 'dir', 'dich', 'uns',
  'bitte', 'vielleicht', 'etwa', 'ganz', 'mal', 'hier', 'dort', 'da', 'jetzt', 'immer',
])

/** @param context the text around it: a few words alone are too little to tell German from English. */
export function lowerFirstWordIfSafe(text: string, context = ''): string {
  const first = text.split(' ', 1)[0]
  const initial = [...first][0]
  if (!initial || initial === initial.toLowerCase()) return text
  // Acronyms and "I" stay as they are.
  const letters = [...first].filter(isLetter).join('')
  if (letters.length > 1 && letters === letters.toUpperCase()) return text
  if (first.replace(/^\p{P}+|\p{P}+$/gu, '') === 'I' || first.startsWith("I'") || first.startsWith('I’')) return text
  const lowered = first.toLowerCase()
  const bare = lowered.replace(/^\p{P}+|\p{P}+$/gu, '')
  // Only words that are never capitalised mid-sentence, in English too:
  // lowering every first word made "alice Johnson" and "microsoft".
  if (!(looksEnglish(context + ' ' + text) ? englishFunctionWords : germanFunctionWords).has(bare)) return text
  return initial.toLowerCase() + text.slice(initial.length)
}

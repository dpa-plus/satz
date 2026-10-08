/**
 * Two checks around local Whisper, ported from SatzKit's WordCheck.swift.
 */

/**
 * Whether a recording has any speech in it at all: at least a fifth of a
 * second of 30 ms frames louder than -45 dBFS. Whisper makes something up for
 * silence ("you", "Thank you.", "."), so silence is never sent to it.
 */
export function hasSpeech(samples: Float32Array, rate = 16_000): boolean {
  const frame = Math.max(1, Math.floor(rate * 0.03))
  const needed = Math.max(1, Math.floor(0.2 / 0.03))
  const threshold = 0.0056
  let loud = 0
  for (let start = 0; start + frame <= samples.length; start += frame) {
    let sum = 0
    for (let k = start; k < start + frame; k++) sum += samples[k] * samples[k]
    if (Math.sqrt(sum / frame) > threshold && ++loud >= needed) return true
  }
  return false
}

const words = (text: string) => text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean)

/** The longest run of words in `a` that a longest common subsequence with `b` leaves out. */
export function longestGap(a: string[], b: string[]): number {
  if (a.length === 0) return 0
  if (b.length === 0) return a.length
  const table = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0))
  for (let i = a.length - 1; i >= 0; i--)
    for (let j = b.length - 1; j >= 0; j--)
      table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1])
  let i = 0, j = 0, run = 0, longest = 0
  while (i < a.length) {
    if (j < b.length && a[i] === b[j]) { run = 0; i++; j++ }
    else if (j < b.length && table[i][j + 1] >= table[i + 1][j]) j++
    else { run++; longest = Math.max(longest, run); i++ }
  }
  return longest
}

/**
 * With a prompt, Whisper sometimes leaves out what does not fit it: an English
 * sentence in a German recording was dropped every time. The prompted text is
 * kept only if it lost no words: lined up word by word, three plain words in a
 * row missing from it mean it dropped something (a spelling the list fixed
 * changes one word). A count alone let a dropped sentence through in long
 * dictations. An empty plain text stays empty: a prompt alone can make
 * Whisper repeat the word list.
 */
export function keepEveryWord(prompted: string, plain: string): { text: string; chosen: 'prompted' | 'plain' } {
  const a = words(plain), b = words(prompted)
  if (a.length === 0) return { text: plain, chosen: 'plain' }
  const promptedLost = b.length < 0.85 * a.length || longestGap(a, b) >= 3
  // Both can lose words (the plain text dropped a first sentence once): then
  // the one that kept more.
  if (promptedLost && longestGap(b, a) >= 3 && b.length > a.length) return { text: prompted, chosen: 'prompted' }
  return promptedLost ? { text: plain, chosen: 'plain' } : { text: prompted, chosen: 'prompted' }
}

/**
 * Where Whisper's long-form decoding goes on after one 30 s window, from the
 * timestamp tokens in its answer (openai/whisper's rule): up to the end of
 * the last complete segment, so a sentence that runs past the window is
 * decoded again, whole, in the next one. `null` means the whole window was
 * used. Returns the tokens to keep (with their timestamps) and how far to go.
 */
export function cutAtLastSegment(tokens: number[], timestampBegin: number): { keep: number[]; seconds: number | null } {
  const isTime = tokens.map(t => t >= timestampBegin)
  const singleEnding = tokens.length >= 2 ? !isTime[tokens.length - 2] && isTime[tokens.length - 1] : isTime[tokens.length - 1] === true
  const consecutive: number[] = []
  for (let k = 1; k < tokens.length; k++) if (isTime[k] && isTime[k - 1]) consecutive.push(k)
  if (consecutive.length === 0) return { keep: tokens, seconds: null }
  if (singleEnding) return { keep: tokens, seconds: null }
  const last = consecutive[consecutive.length - 1]
  return { keep: tokens.slice(0, last), seconds: (tokens[last - 1] - timestampBegin) * 0.02 }
}

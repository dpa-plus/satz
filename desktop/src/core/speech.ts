/**
 * Two checks around local Whisper, ported from SatzKit's WordCheck.swift.
 */

/**
 * Whether a recording has any speech in it at all. Whisper makes something up
 * for silence ("you", "Thank you.", "."), so silence is never sent to it.
 * Speech is a fifth of a second of 30 ms frames above -45 dBFS, or, from a
 * quiet microphone, above -60 dBFS and three times the recording's own quiet
 * level: a fixed -45 dB alone dropped clear speech from a low-gain
 * microphone, and steady quiet noise is not speech.
 */
export function hasSpeech(samples: Float32Array, rate = 16_000): boolean {
  const frame = Math.max(1, Math.floor(rate * 0.03))
  const needed = Math.max(1, Math.floor(0.2 / 0.03))
  const levels: number[] = []
  for (let start = 0; start + frame <= samples.length; start += frame) {
    let sum = 0
    for (let k = start; k < start + frame; k++) sum += samples[k] * samples[k]
    levels.push(Math.sqrt(sum / frame))
  }
  if (levels.length < needed) return false
  const quiet = [...levels].sort((a, b) => a - b)[Math.floor(levels.length * 0.1)]
  const threshold = Math.min(0.0056, Math.max(0.001, 3 * quiet))
  return levels.filter(level => level > threshold).length >= needed
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
  // Extra words in the prompted text prove nothing: a longer made-up phrase
  // ("Vielen Dank fürs Zuschauen") must not beat a sentence it dropped. And
  // five or more words in a row the plain text does not have are something
  // the prompt brought in: it repeated a whole earlier passage once.
  if (b.length < 0.85 * a.length || longestGap(a, b) >= 3 || longestGap(b, a) >= 5) return { text: plain, chosen: 'plain' }
  return { text: prompted, chosen: 'prompted' }
}

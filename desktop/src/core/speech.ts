/**
 * Two checks around local Whisper, ported from SatzKit's WordCheck.swift.
 */

/** Frames of 30 ms and the least that makes speech: a fifth of a second of them. */
const frameSeconds = 0.03
const neededFrames = Math.max(1, Math.floor(0.2 / frameSeconds))

/** The level (root mean square) of each 30 ms frame. */
function frameLevels(samples: Float32Array, rate: number): number[] {
  const frame = Math.max(1, Math.floor(rate * frameSeconds))
  const levels: number[] = []
  for (let start = 0; start + frame <= samples.length; start += frame) {
    let sum = 0
    for (let k = start; k < start + frame; k++) sum += samples[k] * samples[k]
    levels.push(Math.sqrt(sum / frame))
  }
  return levels
}

/**
 * The level a frame has to pass to count as speech: -45 dBFS, or, from a
 * quiet microphone, three times the recording's own quiet level (its
 * tenth percentile) but at least -60 dBFS. A fixed -45 dB alone dropped
 * clear speech from a low-gain microphone, and steady quiet noise is not
 * speech.
 */
function levelOfSpeech(levels: number[]): number {
  const quiet = [...levels].sort((a, b) => a - b)[Math.floor(levels.length * 0.1)] ?? 0
  return Math.min(0.0056, Math.max(0.001, 3 * quiet))
}

/** `levelOfSpeech` of a recording: the number to hand `hasSpeech` and `speechEnd` for each piece cut from it. */
export function speechThreshold(samples: Float32Array, rate = 16_000): number {
  return levelOfSpeech(frameLevels(samples, rate))
}

/**
 * The threshold for a piece cut from a longer recording: the lower of its
 * own and the whole recording's. The quiet level of the piece alone moves
 * with what else is in it: 20 s of low-gain speech over hum, alone, is all
 * "quiet" and counts as no speech, but with 10 s of silence beside it in
 * the recording the same 20 s are clearly above the floor, and the piece was
 * dropped the moment more was said after the silence. The lower of the two
 * keeps whatever either would keep.
 */
export const pieceThreshold = (piece: Float32Array, whole: number, rate = 16_000) => Math.min(speechThreshold(piece, rate), whole)

/**
 * Whether a recording has any speech in it at all. Whisper makes something up
 * for silence ("you", "Thank you.", "."), so silence is never sent to it.
 * Speech is a fifth of a second of 30 ms frames above `threshold`, which is
 * the recording's own (`speechThreshold`) unless a piece of a longer
 * recording is asked about (`pieceThreshold`).
 */
export function hasSpeech(samples: Float32Array, rate = 16_000, threshold?: number): boolean {
  const levels = frameLevels(samples, rate)
  if (levels.length < neededFrames) return false
  const limit = threshold ?? levelOfSpeech(levels)
  return levels.filter(level => level > limit).length >= neededFrames
}

/**
 * The frame levels the steady check reads, after a gentle high-pass at
 * 100 Hz: rumble and slow wandering below it lifted a fan's frames enough to
 * pass for a syllable, and Cohere wrote sentences for it. Speech keeps its
 * level, so it stands out more over a hum, not less.
 */
function levelsAbove100Hz(samples: Float32Array, rate: number): number[] {
  const rc = 1 / (2 * Math.PI * 100), a = rc / (rc + 1 / rate)
  const filtered = new Float32Array(samples.length)
  let output = 0, input = 0
  for (let i = 0; i < samples.length; i++) {
    output = a * (output + samples[i] - input)
    input = samples[i]
    filtered[i] = output
  }
  return frameLevels(filtered, rate)
}

/** Seven 30 ms frames, about a syllable and a half: a key tap or a click is one or two, a cough barely reaches it. */
const burstFrames = 7

/** The quietest frame of the loudest `burstFrames` frames in a row: a burst counts only if all of it is loud. */
function sustainedBurst(levels: number[]): number {
  let loudest = 0
  for (let start = 0; start + burstFrames <= levels.length; start++) {
    let quietest = Infinity
    for (let k = start; k < start + burstFrames; k++) quietest = Math.min(quietest, levels[k])
    loudest = Math.max(loudest, quietest)
  }
  return loudest
}

/**
 * Whether a piece is one steady level, like a fan, hiss or hum, rather than
 * speech. Cohere Transcribe and Qwen3-ASR write sentences for such noise, so
 * it is not sent to them; `hasSpeech` cannot tell, it takes anything louder
 * than -45 dBFS for speech, which a low-gain microphone needs.
 *
 * Steady takes two things, both measured above 100 Hz. The louder tenth of
 * the frames stays under twice the quieter tenth, as before. And no 210 ms
 * (`burstFrames`) are all at least 1.45 times the piece's median frame: the
 * first test alone took "Ja, genau." before a long pause for a fan, because
 * it was under a tenth of the piece and its words were never heard (Codex
 * F01, 14.10.2026). Measured on 14.10.: speech scores 1.9 to 200 over hiss,
 * fans, pink and brown noise and hum, down to the phrase at a third of its
 * level under a fan at -30 dBFS (1.54); fans, hiss, rumble, key taps, clicks
 * and a cough score 1.0 to 1.25; only a strongly gusting fan (1.38, kept by
 * the first test anyway) comes close. A phrase quieter than the noise around
 * it can still be skipped. Under a second there is too little to judge, and
 * a piece with a silent stretch is not steady. The same numbers as
 * WordCheck.swift (shared cases in Tests/Fixtures/CodexFixSteadyNoise).
 */
export function isSteady(samples: Float32Array, rate = 16_000): boolean {
  const levels = levelsAbove100Hz(samples, rate)
  if (levels.length < 30) return false
  const sorted = [...levels].sort((a, b) => a - b)
  const quiet = sorted[Math.floor(levels.length * 0.1)]
  if (quiet <= 0 || sorted[Math.floor(levels.length * 0.9)] >= 2 * quiet) return false
  return sustainedBurst(levels) < 1.45 * sorted[Math.floor(levels.length / 2)]
}

/**
 * Where the last 30 ms above the speech level end; null when nothing is
 * that loud. Parakeet V3 wrote nothing at all for clear speech cut off
 * mid-word and followed by quiet (a tenth of a second was enough), and the
 * same audio up to here came back whole.
 */
export function speechEnd(samples: Float32Array, rate = 16_000, threshold?: number): number | null {
  const levels = frameLevels(samples, rate)
  if (levels.length === 0) return null
  const limit = threshold ?? levelOfSpeech(levels)
  const last = levels.findLastIndex(level => level > limit)
  return last < 0 ? null : (last + 1) * Math.max(1, Math.floor(rate * frameSeconds))
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

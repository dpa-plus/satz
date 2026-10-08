/**
 * Whisper hears 30 seconds at a time. A longer recording is split at the
 * quietest tenth of a second in the last ten seconds of each window, so no
 * word is cut in half; Whisper's own long-form decoding does the same kind
 * of thing. A dictation under 30 seconds stays one piece.
 */
export function windows(samples: Float32Array, rate = 16_000, longest = 30 * rate): Float32Array[] {
  const frame = rate / 10
  const pieces: Float32Array[] = []
  let start = 0
  while (samples.length - start > longest) {
    let cut = start + longest
    let quietest = Infinity
    for (let at = start + longest - 10 * rate; at + frame <= start + longest; at += frame) {
      let energy = 0
      for (let i = at; i < at + frame; i++) energy += samples[i] * samples[i]
      if (energy < quietest) { quietest = energy; cut = at + frame / 2 }
    }
    pieces.push(samples.subarray(start, cut))
    start = cut
  }
  pieces.push(samples.subarray(start))
  return pieces
}

/** 16-bit PCM mono WAV, what every transcription API takes. */
export function encodeWAV(samples: Float32Array, sampleRate = 16_000): Uint8Array {
  const data = samples.length * 2
  const buffer = new ArrayBuffer(44 + data)
  const view = new DataView(buffer)
  const ascii = (offset: number, s: string) => { for (let i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i)) }
  ascii(0, 'RIFF'); view.setUint32(4, 36 + data, true); ascii(8, 'WAVE')
  ascii(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true)
  view.setUint32(24, sampleRate, true); view.setUint32(28, sampleRate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true)
  ascii(36, 'data'); view.setUint32(40, data, true)
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]))
    view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true)
  }
  return new Uint8Array(buffer)
}

/** The samples of a 16-bit PCM WAV, as floats (test audio). Mono only. */
export function decodeWAV(bytes: Uint8Array): { samples: Float32Array; sampleRate: number } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  let offset = 12, sampleRate = 16_000
  while (offset + 8 <= bytes.length) {
    const id = String.fromCharCode(...bytes.subarray(offset, offset + 4))
    const size = view.getUint32(offset + 4, true)
    if (id === 'fmt ') sampleRate = view.getUint32(offset + 12, true)
    if (id === 'data') {
      const count = Math.floor(Math.min(size, bytes.length - offset - 8) / 2)
      const samples = new Float32Array(count)
      for (let i = 0; i < count; i++) samples[i] = view.getInt16(offset + 8 + i * 2, true) / 0x8000
      return { samples, sampleRate }
    }
    offset += 8 + size + (size % 2)
  }
  return { samples: new Float32Array(0), sampleRate }
}

/** Linear resampling to 16 kHz: plenty for speech recognition. */
export function resample(input: Float32Array, from: number, to = 16_000): Float32Array {
  if (from === to) return input
  const ratio = from / to
  const length = Math.floor(input.length / ratio)
  const out = new Float32Array(length)
  for (let i = 0; i < length; i++) {
    const position = i * ratio
    const index = Math.floor(position)
    const fraction = position - index
    const a = input[index] ?? 0, b = input[index + 1] ?? a
    out[i] = a + (b - a) * fraction
  }
  return out
}

/** Loudness of a block on 0...1, through decibels, like the Mac app's level meter. */
export function level(samples: Float32Array): number {
  if (samples.length === 0) return 0
  let sum = 0
  for (const s of samples) sum += s * s
  const rms = Math.sqrt(sum / samples.length)
  if (rms <= 0) return 0
  return Math.max(0, Math.min(1, (20 * Math.log10(rms) + 55) / 55))
}

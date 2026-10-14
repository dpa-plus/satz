import { Session, type AudioSource, type CleanupOutcome } from '../src/core/session'
import { setLanguage } from '../src/core/language'

setLanguage('en')

/**
 * Speech as numbers, as in session.test.ts: every character of a script
 * becomes K samples carrying its character code, so a transcript can be read
 * straight back out of the audio.
 */
export const K = 10

export class FakeSource implements AudioSource {
  onLevel?: (level: number) => void
  revealed = 0
  cancelled = false
  constructor(readonly script: string) {}
  async start() {}
  get sampleCount() { return this.revealed * K }
  /** The speaker says the next `chars` characters. */
  say(chars = this.script.length - this.revealed) { this.revealed = Math.min(this.script.length, this.revealed + chars) }
  samples(from: number, to: number) {
    const out = new Float32Array(Math.max(0, Math.min(to, this.sampleCount) - from))
    for (let i = 0; i < out.length; i++) out[i] = this.script.charCodeAt(Math.floor((from + i) / K)) / 1000
    return out
  }
  async finishSamples() { return this.cancelled ? null : this.samples(0, this.sampleCount) }
  cancel() { this.cancelled = true }
}

export const decode = (samples: Float32Array) => {
  let out = ''
  for (let i = Math.floor(K / 2); i < samples.length; i += K) out += String.fromCharCode(Math.round(samples[i] * 1000))
  return out.trim()
}

/** The phase's name as a plain string: asserting it narrows the type, and the next assertion is about a later phase. */
export const phase = (session: Session): string => session.phase.kind

export const tick = (ms = 0) => new Promise<void>(resolve => setTimeout(resolve, ms))
export async function settle() { for (let i = 0; i < 8; i++) await tick() }
/** Promises only, for tests that run on fake timers. */
export async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve() }

export function deferred<T = void>() {
  let resolve!: (value: T) => void, reject!: (error: unknown) => void
  const promise = new Promise<T>((a, b) => { resolve = a; reject = b })
  return { promise, resolve, reject }
}

export interface Options {
  mode?: 'tap' | 'hold'
  transcribe?: (samples: Float32Array) => Promise<string>
  deliver?: (text: string, cleanup?: CleanupOutcome) => Promise<{ pasted: boolean; reason?: string }>
  /** The cleanup model's stand-in, and whether cleanup is on (it is, when one is given). */
  cleanup?: (text: string) => Promise<{ text: string; outcome: string }>
  cleansText?: () => boolean
  /** Use core/speech.ts's gate: for sources that make real sound, not letters. */
  realGate?: boolean
  makeSource?: (index: number) => AudioSource
}

const created: Session[] = []
/** Stops the timers of every session a test made. */
export function disposeAll() { for (const session of created.splice(0)) session.dispose() }

export function setup(scripts: string[], options: Options = {}) {
  const sources: AudioSource[] = []
  const delivered: string[] = []
  /** What each delivery said about its cleanup, for the history. */
  const cleanups: (CleanupOutcome | undefined)[] = []
  let mode = options.mode ?? 'tap'
  const session = new Session({
    makeSource: () => { const s = options.makeSource ? options.makeSource(sources.length) : new FakeSource(scripts[sources.length] ?? ''); sources.push(s); return s },
    transcribe: options.transcribe ?? (async samples => decode(samples)),
    replacements: () => [],
    missing: () => null,
    endpointMissing: () => false,
    triggerMode: () => mode,
    deliver: options.deliver ?? (async (text, cleanup) => { delivered.push(text); cleanups.push(cleanup); return { pasted: true } }),
    ...(options.cleanup ? { cleanup: options.cleanup, cleansText: options.cleansText ?? (() => true) } : {}),
    ...(options.realGate ? {} : { hasSpeech: (samples: Float32Array) => samples.length > 0 }),
  })
  created.push(session)
  return { session, sources: sources as FakeSource[], delivered, cleanups, setMode: (m: 'tap' | 'hold') => { mode = m } }
}

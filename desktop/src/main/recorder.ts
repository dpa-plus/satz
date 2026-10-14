import fs from 'node:fs'
import { de } from '../core/language'
import type { AudioSource } from '../core/session'
import { decodeWAV, level, resample } from '../core/wav'

const RATE = 16_000
/** The microphone stays open this long after stopping, so the last word is kept. */
const TAIL_MS = 400

/**
 * One continuous microphone stream, recorded in the card window (the only
 * place with Web Audio) and sent here as 16 kHz chunks. Each recording is a
 * window onto it, so a new recording can start while the last one is still in
 * its tail without opening the microphone twice.
 */
export class MicHub {
  private buffer = new Float32Array(RATE * 60)
  private count = 0
  private users = 0
  private listeners = new Set<(level: number) => void>()
  private lostListeners = new Set<() => void>()
  /** The capture now, opened or opening; null once it went away by itself. */
  private running: Promise<void> | null = null

  constructor(private control: { start(): Promise<void>; stop(): void }) {}

  get total() { return this.count }

  push(chunk: Float32Array) {
    if (this.users === 0) return
    if (this.count + chunk.length > this.buffer.length) {
      const bigger = new Float32Array(Math.max(this.buffer.length * 2, this.count + chunk.length))
      bigger.set(this.buffer.subarray(0, this.count))
      this.buffer = bigger
    }
    this.buffer.set(chunk, this.count)
    this.count += chunk.length
    const value = level(chunk)
    for (const listener of this.listeners) listener(value)
  }

  slice(from: number, to: number) { return this.buffer.slice(Math.max(0, from), Math.min(to, this.count)) }

  /** `onLost`: the capture went away by itself while this user held it. */
  async acquire(onLevel: (level: number) => void, onLost?: () => void) {
    this.listeners.add(onLevel)
    if (onLost) this.lostListeners.add(onLost)
    if (this.users++ === 0) {
      this.count = 0
      this.running = this.control.start()
    } else if (this.running === null) {
      // The capture went away while a recording in its tail still holds it:
      // a new one, onto the same buffer, which that recording still reads.
      // Taken over as it was, the next recording heard nothing.
      this.running = this.control.start()
    }
    const running = this.running
    try {
      await running
    } catch (error) {
      // Asked again later, it starts again rather than failing the same way.
      if (this.running === running) this.running = null
      this.release(onLevel, onLost)
      throw error
    }
  }

  release(onLevel: (level: number) => void, onLost?: () => void) {
    this.listeners.delete(onLevel)
    if (onLost) this.lostListeners.delete(onLost)
    if (--this.users <= 0) {
      this.users = 0
      this.control.stop()
    }
  }

  /**
   * The capture went away by itself (unplugged, the audio system failed).
   * The recordings on it are told and keep what they have; the next one
   * opens a new capture.
   */
  lost() {
    if (this.users === 0) return
    this.running = null
    for (const listener of [...this.lostListeners]) listener()
  }
}

export class MicRecorder implements AudioSource {
  onLevel?: (level: number) => void
  onLost?: () => void
  private start0 = 0
  private stoppedAt: number | null = null
  private active = false
  private cancelled = false
  /** The capture went away: this recording ends where it did, and no tail is waited for. */
  private lost = false
  private readonly levelListener = (value: number) => this.onLevel?.(value)
  private readonly lostListener = () => {
    if (this.lost) return
    this.lost = true
    // What a new capture adds to the hub belongs to the next recording.
    if (this.active) this.stoppedAt = this.stoppedAt ?? this.hub.total - this.start0
    this.onLost?.()
  }

  constructor(private hub: MicHub) {}

  async start() {
    await this.hub.acquire(this.levelListener, this.lostListener)
    if (this.lost) {
      // Went away while it was being opened: a start that failed.
      this.hub.release(this.levelListener, this.lostListener)
      throw new Error(de('Mikrofon getrennt', 'Microphone lost'))
    }
    this.active = true
    this.start0 = this.hub.total
  }

  get sampleCount() {
    if (this.stoppedAt !== null) return this.stoppedAt
    return this.active ? this.hub.total - this.start0 : 0
  }

  samples(from: number, to: number) {
    return this.hub.slice(this.start0 + from, this.start0 + Math.min(to, this.sampleCount))
  }

  async finishSamples() {
    if (!this.active) return null
    // Gone, nothing more can come; else the last word is still on its way.
    if (!this.lost) await new Promise(resolve => setTimeout(resolve, TAIL_MS))
    if (this.cancelled) return null
    this.stoppedAt = this.sampleCount
    const all = this.samples(0, this.stoppedAt)
    this.stop()
    return all
  }

  cancel() {
    this.cancelled = true
    this.stoppedAt = this.stoppedAt ?? this.sampleCount
    this.stop()
  }

  private stop() {
    if (!this.active) return
    this.active = false
    this.hub.release(this.levelListener, this.lostListener)
  }
}

/** Test mode: a WAV played in real time, as if someone were speaking it. */
export class FileSource implements AudioSource {
  onLevel?: (level: number) => void
  private samples0: Float32Array
  private startedAt: number | null = null
  private stoppedAt: number | null = null
  private ticker: ReturnType<typeof setInterval> | null = null

  /** null plays silence. */
  constructor(file: string | null) {
    if (file === null) { this.samples0 = new Float32Array(0); return }
    const { samples, sampleRate } = decodeWAV(new Uint8Array(fs.readFileSync(file)))
    this.samples0 = resample(samples, sampleRate)
  }

  async start() {
    this.startedAt = Date.now()
    this.ticker = setInterval(() => {
      const end = this.sampleCount
      this.onLevel?.(level(this.samples(Math.max(0, end - 960), end)))
    }, 60)
  }

  get sampleCount() {
    if (this.stoppedAt !== null) return this.stoppedAt
    if (this.startedAt === null) return 0
    return Math.min(this.samples0.length, Math.floor((Date.now() - this.startedAt) / 1000 * RATE))
  }

  samples(from: number, to: number) {
    return this.samples0.slice(Math.max(0, from), Math.min(to, this.samples0.length))
  }

  async finishSamples() {
    await new Promise(resolve => setTimeout(resolve, TAIL_MS))
    if (this.ticker) clearInterval(this.ticker)
    this.stoppedAt = this.sampleCount
    return this.samples(0, this.stoppedAt)
  }

  cancel() {
    if (this.ticker) clearInterval(this.ticker)
    this.stoppedAt = 0
  }
}

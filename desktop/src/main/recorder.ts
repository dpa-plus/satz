import fs from 'node:fs'
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

  async acquire(onLevel: (level: number) => void) {
    this.listeners.add(onLevel)
    if (this.users++ === 0) {
      this.count = 0
      this.running = this.control.start()
    }
    try {
      await this.running
    } catch (error) {
      this.release(onLevel)
      throw error
    }
  }

  release(onLevel: (level: number) => void) {
    this.listeners.delete(onLevel)
    if (--this.users <= 0) {
      this.users = 0
      this.control.stop()
    }
  }
}

export class MicRecorder implements AudioSource {
  onLevel?: (level: number) => void
  private start0 = 0
  private stoppedAt: number | null = null
  private active = false
  private cancelled = false
  private readonly levelListener = (value: number) => this.onLevel?.(value)

  constructor(private hub: MicHub) {}

  async start() {
    await this.hub.acquire(this.levelListener)
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
    await new Promise(resolve => setTimeout(resolve, TAIL_MS))
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
    this.hub.release(this.levelListener)
  }
}

/** Test mode: a WAV played in real time, as if someone were speaking it. */
export class FileSource implements AudioSource {
  onLevel?: (level: number) => void
  private samples0: Float32Array
  private startedAt: number | null = null
  private stoppedAt: number | null = null
  private ticker: ReturnType<typeof setInterval> | null = null

  constructor(file: string) {
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

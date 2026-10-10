/**
 * The microphone, opened in the card window (the only place with Web Audio)
 * and closed again on the main process's word. What it opens is behind
 * `MicrophoneParts`, so a test can open it with stand-ins.
 */
export interface Tap {
  /** Sends the stream's audio on, in chunks. */
  connect(stream: MediaStream): void
  close(): void
}

export interface MicrophoneParts {
  getUserMedia(): Promise<MediaStream>
  /** The audio context and its tap, ready to take a stream. */
  openTap(onChunk: (chunk: Float32Array) => void): Promise<Tap>
}

const release = (stream: MediaStream | null, tap: Tap | null) => {
  stream?.getTracks().forEach(track => track.stop())
  tap?.close()
}

export class Microphone {
  private open: { stream: MediaStream; tap: Tap } | null = null
  /**
   * Counts starts and stops. Opening takes a while (a permission, a slow
   * Bluetooth headset), and the main process gives up after 15 s and says
   * stop: a microphone that comes in after that was asked for by nobody, and
   * stayed connected for good, with the system's recording light on.
   */
  private generation = 0

  constructor(private parts: MicrophoneParts, private onChunk: (chunk: Float32Array) => void) {}

  /**
   * True once the microphone is open for this call. False when a stop (or a
   * later start) came first: what was just opened is let go again, and the
   * caller has nobody to answer.
   */
  async start(): Promise<boolean> {
    const mine = ++this.generation
    if (this.open) return true
    let stream: MediaStream | null = null, tap: Tap | null = null
    try {
      stream = await this.parts.getUserMedia()
      if (mine !== this.generation) { release(stream, null); return false }
      tap = await this.parts.openTap(this.onChunk)
      if (mine !== this.generation) { release(stream, tap); return false }
      tap.connect(stream)
      this.open = { stream, tap }
      return true
    } catch (error) {
      release(stream, tap)
      throw error
    }
  }

  stop() {
    this.generation++
    release(this.open?.stream ?? null, this.open?.tap ?? null)
    this.open = null
  }
}

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
  /** The audio context and its tap, ready to take a stream. `onFailed`: the context stopped on its own. */
  openTap(onChunk: (chunk: Float32Array) => void, onFailed: () => void): Promise<Tap>
}

const release = (stream: MediaStream | null, tap: Tap | null) => {
  stream?.getTracks().forEach(track => track.stop())
  tap?.close()
}

/** A microphone that went away while it was being opened: the start fails with it. */
export const lostError = () => Object.assign(new Error('microphone lost'), { name: 'MicrophoneLost' })

interface Open { stream: MediaStream; tap: Tap; unwatch: () => void }

export class Microphone {
  private open: Open | null = null
  /**
   * Counts starts and stops. Opening takes a while (a permission, a slow
   * Bluetooth headset), and the main process gives up after 15 s and says
   * stop: a microphone that comes in after that was asked for by nobody, and
   * stayed connected for good, with the system's recording light on.
   */
  private generation = 0

  /**
   * `onLost`: the open microphone went away by itself (unplugged, a headset
   * out of range, its audio context failed). It is closed already; the next
   * start opens the one there is then. Kept open, it was a recording that
   * heard nothing and said nothing about it.
   */
  constructor(private parts: MicrophoneParts, private onChunk: (chunk: Float32Array) => void, private onLost: () => void = () => {}) {}

  /**
   * True once the microphone is open for this call. False when a stop (or a
   * later start) came first: what was just opened is let go again, and the
   * caller has nobody to answer.
   */
  async start(): Promise<boolean> {
    const mine = ++this.generation
    if (this.open) return true
    let stream: MediaStream | null = null, tap: Tap | null = null
    // Only the capture this call made open counts; anything later is not ours.
    let opened: Open | null = null
    const lost = () => { if (opened && this.open === opened) this.lose(opened) }
    try {
      stream = await this.parts.getUserMedia()
      if (mine !== this.generation) { release(stream, null); return false }
      tap = await this.parts.openTap(this.onChunk, lost)
      if (mine !== this.generation) { release(stream, tap); return false }
      tap.connect(stream)
      const tracks = stream.getTracks()
      for (const track of tracks) track.addEventListener?.('ended', lost)
      const unwatch = () => { for (const track of tracks) track.removeEventListener?.('ended', lost) }
      // Gone before anyone listened: no event comes for that.
      if (tracks.some(track => track.readyState === 'ended')) { unwatch(); throw lostError() }
      opened = { stream, tap, unwatch }
      this.open = opened
      return true
    } catch (error) {
      release(stream, tap)
      throw error
    }
  }

  stop() {
    this.generation++
    this.open?.unwatch()
    release(this.open?.stream ?? null, this.open?.tap ?? null)
    this.open = null
  }

  private lose(open: Open) {
    open.unwatch()
    release(open.stream, open.tap)
    this.open = null
    this.onLost()
  }
}

/** The card's bridge to the main process, as far as recording needs it. */
interface Bridge {
  send(channel: string, ...args: unknown[]): void
  on(channel: string, listener: (value: any) => void): void
}

/**
 * The card's side of recording: the main process says start (numbered) and
 * stop; the card answers each start, sends the audio on, and says when the
 * microphone went away, with the number of the start it last answered. A
 * loss told late, after the main process already asked for a new microphone,
 * is the old one's and must not end the new recording.
 * `message`: why a start failed, in the card's language.
 */
export function recordFor(satz: Bridge, parts: MicrophoneParts, message: (error: unknown) => string) {
  let answered = 0
  const microphone = new Microphone(parts, chunk => satz.send('rec:chunk', chunk), () => satz.send('rec:lost', answered))
  satz.on('rec:start', async (id: number) => {
    try {
      // Not answered when it was stopped meanwhile: the main process stopped waiting.
      if (await microphone.start()) { answered = id; satz.send('rec:started', id) }
    } catch (error) {
      satz.send('rec:started', id, message(error))
    }
  })
  satz.on('rec:stop', () => microphone.stop())
  return microphone
}

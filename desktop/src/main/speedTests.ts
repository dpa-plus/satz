import type { Phase } from '../core/session'

/** What SpeedTests asks of satz: main.ts wires it to the session, the settings and the helper. */
export interface SpeedTestDeps {
  /** Where the dictation stands. */
  phase(): Phase['kind']
  /**
   * Runs the test, in the dictations' queue (LocalModels.measure).
   * 'deferred': a dictation came in while it ran and it gave way.
   */
  measure(id: string): Promise<'done' | 'deferred' | 'failed'>
  /** The model dictations use. */
  inUse(): string
  /** On this computer. */
  isReady(id: string): boolean
  /** Makes `id` Local's model; never the provider: a download is not a choice of provider. */
  use(id: string): void
  /** Local is the provider, so the model in use belongs in memory. */
  localChosen(): boolean
  /** Loads `id` as the model dictations use. */
  warmUp(id: string): void
  log(message: string): void
}

/**
 * How long the card has to stay closed before a test that waited starts.
 * The next dictation, asked for while one was still being written, begins
 * only after the paste, so a test started the moment the card closed was
 * ahead of that dictation's text.
 */
const settleMs = 2000

/**
 * When satz measures a local model's speed, and what a finished download
 * does. The test goes through the dictations' own queue, so it never shares
 * the processor with one. That queue is also why it waits for a dictation
 * to be over: started while the user was still speaking or while the text
 * was being written, it went in ahead of that dictation's text, and the
 * user waited for the whole test (8.8 s with Large v3 on an M5 Pro) after
 * finishing.
 */
export class SpeedTests {
  /** In the order asked. */
  private waiting: string[] = []
  /**
   * One test at a time: a second one, handed to the helper while the first
   * ran, was already in its queue when the user started speaking, and ran
   * then.
   */
  private running: string | null = null
  private timer: ReturnType<typeof setTimeout> | null = null

  constructor(private deps: SpeedTestDeps, private settle = settleMs) {}

  /**
   * Anything but a closed card: recording, paused (the recording so far is
   * sent after its tail), being written, or a message the user may answer
   * with Try again or Undo, which send audio too.
   */
  private get busy() { return this.deps.phase() !== 'idle' }

  /** Asked for and waiting for the dictation to be over; Settings shows it as being measured. */
  isWaiting(id: string) { return this.waiting.includes(id) }

  /** Measures now, or once the dictation under way (or the test running) is over. */
  request(id: string) {
    if (!this.waiting.includes(id) && this.running !== id) this.waiting.push(id)
    this.next()
  }

  /** On every change of the session: what waited starts once the card has been closed a moment. */
  sessionChanged() {
    if (this.waiting.length === 0 || this.timer || this.busy) return
    this.timer = setTimeout(() => {
      this.timer = null
      // A new dictation in the meantime: its own end starts this again.
      this.next()
    }, this.settle)
  }

  private next() {
    if (this.running || this.busy || this.waiting.length === 0) return
    const id = this.waiting.shift()!
    this.running = id
    this.deps.measure(id).then(
      result => { if (result === 'deferred' && !this.waiting.includes(id)) this.waiting.unshift(id) },
      () => {},
    ).finally(() => {
      this.running = null
      // After a dictation it gave way to, the card's end starts it again.
      this.next()
    })
  }

  /**
   * A download that arrived complete. It never changes the model by itself,
   * except when the one in use is not on the computer (the first one, or it
   * was removed): then Local works right away. It never changes the
   * provider: downloading while only looking at Local leaves dictations
   * where they went. The model in use is loaded as such before its test
   * when Local is the provider: tested as "not in use", it was let go
   * afterwards and the first dictation loaded it again.
   */
  arrived(id: string) {
    const inUse = this.deps.inUse()
    if (id !== inUse && !this.deps.isReady(inUse)) {
      this.deps.log(`local: ${id} is now the model in use, ${inUse} is not on this computer`)
      this.deps.use(id)
    }
    if (id === this.deps.inUse() && this.deps.localChosen()) this.deps.warmUp(id)
    this.request(id)
  }

  /** Stops the timer, for tests. */
  dispose() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }
}

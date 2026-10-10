/**
 * The clipboard goes back to what it held once the transcript has been
 * pasted. The bookkeeping lives here, away from Electron, so it can be tested
 * with a clipboard made of a variable.
 *
 * Pastes follow each other (a short dictation right after another, Insert
 * while one finishes). Each used to save "the clipboard" for itself, so the
 * second saved the first transcript and handed that back at the end: the
 * clipboard from before both is the one the user wants. It is kept for the
 * whole burst, unless the user copied something in between: that newer copy
 * is then the one to give back (the Mac does the same, Paster.swift).
 */
export interface ClipboardPort<Saved> {
  /** Everything on the clipboard, in every form, read out now (live items change with the clipboard). */
  save(): Promise<Saved>
  /** Nothing was on it: it is to end up empty again. */
  isEmpty(saved: Saved): boolean
  restore(saved: Saved): Promise<void>
  clear(): void
  writeText(text: string): Promise<void>
  /** Just this text and nothing else: something copied since, also the same words with their formatting, is the user's. */
  holdsOnly(text: string): Promise<boolean>
}

export interface Timers { set(run: () => void, ms: number): unknown; clear(handle: unknown): void }

interface Burst<Saved> { original: Saved; text: string; timer: unknown }

export class ClipboardHandback<Saved> {
  /** What is waiting to be given back: the clipboard from before the burst, and the transcript last put there. */
  private pending: Burst<Saved> | null = null
  /** Pastes and hand-backs run one at a time: two at once wrote over each other's clipboard. */
  private chain: Promise<unknown> = Promise.resolve()

  /** @param delay ms after the last paste before the clipboard comes back. */
  constructor(private port: ClipboardPort<Saved>, private delay: number,
    private timers: Timers = { set: (run, ms) => setTimeout(run, ms), clear: handle => clearTimeout(handle as ReturnType<typeof setTimeout>) }) {}

  /**
   * Puts `text` on the clipboard and runs `paste`, which sends the keystroke.
   * Unless the paste failed or the user keeps the transcript on the clipboard,
   * the clipboard comes back `delay` ms after the last paste of the burst.
   */
  deliver<Outcome extends { pasted: boolean }>(text: string, paste: () => Promise<Outcome>, keepsOnClipboard: boolean): Promise<Outcome> {
    const run = this.chain.then(() => this.put(text, paste, keepsOnClipboard))
    this.chain = run.then(() => {}, () => {})
    return run
  }

  private async put<Outcome extends { pasted: boolean }>(text: string, paste: () => Promise<Outcome>, keepsOnClipboard: boolean): Promise<Outcome> {
    const earlier = this.pending
    const original = await this.takeOriginal()
    let outcome: Outcome
    try {
      await this.port.writeText(text)
      outcome = await paste()
    } catch (error) {
      // The clipboard refused the text: it still holds what the paste before
      // left there, and that one's hand-back is still due.
      if (earlier && await this.port.holdsOnly(earlier.text)) this.arm(earlier.original, earlier.text)
      throw error
    }
    // The transcript stays: the fallback when it could not be pasted, the
    // user's choice otherwise. Nothing is given back, also not for pastes before.
    if (!outcome.pasted || keepsOnClipboard) return outcome
    this.arm(original, text)
    return outcome
  }

  /** A moment after the keystroke, not at once: see PASTE_TAKES in paste.ts. */
  private arm(original: Saved, text: string) {
    const burst: Burst<Saved> = { original, text, timer: null }
    burst.timer = this.timers.set(() => { this.chain = this.chain.then(() => this.giveBack(burst)).then(() => {}, () => {}) }, this.delay)
    this.pending = burst
  }

  /** The clipboard to give back after this paste: the burst's, if the user left it alone. */
  private async takeOriginal(): Promise<Saved> {
    const burst = this.pending
    this.pending = null
    if (burst) {
      this.timers.clear(burst.timer)
      if (await this.port.holdsOnly(burst.text)) return burst.original
    }
    return this.port.save()
  }

  /** Only while the clipboard still holds just the transcript. */
  private async giveBack(burst: Burst<Saved>) {
    // Not the last paste of the burst any more: its own hand-back is due later.
    if (this.pending !== burst) return
    this.pending = null
    if (!(await this.port.holdsOnly(burst.text))) return
    if (this.port.isEmpty(burst.original)) this.port.clear()
    else await this.port.restore(burst.original)
  }
}

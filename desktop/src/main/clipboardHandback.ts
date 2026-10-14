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
  /**
   * Everything on the clipboard, in every form, read out now (live items
   * change with the clipboard). Rejects when the clipboard cannot be read: that
   * is not an empty clipboard, and giving it back as one would wipe it.
   */
  save(): Promise<Saved>
  /** Nothing was on it: it is to end up empty again. */
  isEmpty(saved: Saved): boolean
  restore(saved: Saved): Promise<void>
  clear(): void
  writeText(text: string): Promise<void>
  /** Just this text and nothing else: something copied since, also the same words with their formatting, is the user's. */
  holdsOnly(text: string): Promise<boolean>
}

/**
 * The clipboard could not be read, so nothing was written to it: what is on
 * it could not be given back afterwards. The caller treats the paste as not
 * done and keeps the text.
 */
export class ClipboardBackupError extends Error {
  constructor(cause: unknown) {
    super(`the clipboard could not be read, so it was left alone (${(cause as Error)?.message ?? cause})`, { cause })
    this.name = 'ClipboardBackupError'
  }
}

/**
 * The other names plain text goes by on the X11 and Wayland clipboards: the
 * old text targets, and the protocol's own bookkeeping targets, which every
 * selection lists and which carry no content of their own.
 */
const textAliases = new Set(['text', 'string', 'utf8_string', 'compound_text', 'targets', 'timestamp', 'multiple', 'save_targets'])

/** A native form Electron has no MIME type for is listed as `electron application/osclipboard;format="<native name>"`. */
const nativeForm = /^electron application\/osclipboard;format="(.*)"$/i

const isTextForm = (name: string) => /^text\/plain(;.*)?$/i.test(name) || textAliases.has(name.toLowerCase())
const namesText = (type: string) => isTextForm(type) || isTextForm(nativeForm.exec(type)?.[1] ?? '')

/**
 * Whether an item's forms are all plain text. On Linux Electron lists the text
 * it writes as `text/plain` and also under the selection's names (UTF8_STRING,
 * TARGETS, TIMESTAMP, text/plain;charset=utf-8, wrapped as
 * `electron application/osclipboard;format="…"`), and a check for "text/plain"
 * alone took that for something the user had copied: the picture that was on
 * the clipboard before the dictation never came back (Ubuntu, Codex's third
 * pass). Anything that is not text, HTML, an image or a file list included,
 * still counts as the user's own copy.
 */
export function isPlainTextForms(types: readonly string[]): boolean {
  return types.every(namesText)
}

/** A form that only names the text `text/plain` already carries: a view of it, made again by the system when the text is written. */
export function isTextAlias(type: string): boolean {
  return type !== 'text/plain' && namesText(type)
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
    let original: Saved | null
    try {
      original = await this.takeOriginal(keepsOnClipboard)
    } catch (error) {
      // Nothing was written. The paste before still has its hand-back coming.
      if (earlier) this.arm(earlier.original, earlier.text)
      throw error
    }
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
    if (!outcome.pasted || keepsOnClipboard || original === null) return outcome
    this.arm(original, text)
    return outcome
  }

  /** A moment after the keystroke, not at once: see PASTE_TAKES in paste.ts. */
  private arm(original: Saved, text: string) {
    const burst: Burst<Saved> = { original, text, timer: null }
    burst.timer = this.timers.set(() => { this.chain = this.chain.then(() => this.giveBack(burst)).then(() => {}, () => {}) }, this.delay)
    this.pending = burst
  }

  /**
   * The clipboard to give back after this paste: the burst's, if the user left it alone.
   *
   * A clipboard that cannot be read is not an empty one (it would be cleared
   * afterwards): the paste is refused before anything is written, so what the
   * user copied stays. Where the transcript is meant to stay on the clipboard
   * anyway (`unneeded`) there is nothing to give back and the paste goes ahead.
   */
  private async takeOriginal(unneeded: boolean): Promise<Saved | null> {
    const burst = this.pending
    this.pending = null
    if (burst) {
      this.timers.clear(burst.timer)
      if (await this.port.holdsOnly(burst.text)) return burst.original
    }
    try {
      return await this.port.save()
    } catch (error) {
      if (unneeded) return null
      throw new ClipboardBackupError(error)
    }
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

  /**
   * satz quits: the timer would not outlive it, and the transcript would stay
   * on the clipboard for good. Gives back what is due at once, after a paste
   * that is still running has finished.
   */
  flush(): Promise<void> {
    const run = this.chain.then(() => {
      const burst = this.pending
      if (!burst) return
      this.timers.clear(burst.timer)
      return this.giveBack(burst)
    })
    this.chain = run.then(() => {}, () => {})
    return run
  }
}

let appHandback: { flush(): Promise<void> } | null = null

/** The hand-back the app pastes through (paste.ts), the one `flushHandback` gives back. */
export function registerHandback(handback: { flush(): Promise<void> }) { appHandback = handback }

/** For quitting: puts the clipboard back now instead of when the timer would have. Never rejects, there is nothing left to do about an error. */
export async function flushHandback(): Promise<void> {
  try { await appHandback?.flush() } catch { /* quitting */ }
}

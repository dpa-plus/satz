import { de } from '../core/language'
import type { CleanupOutcome } from '../core/session'
import type { Foreground } from './foreground'

/**
 * A finished text on its way to where the user was typing: back to the
 * window the dictation started in and, where it is known, the text field in
 * it, then the paste. It lives apart from main.ts so a test can run it (unit
 * tests do not reach main.ts).
 */
export interface Outcome { pasted: boolean; reason?: string }

export interface DeliveryDeps {
  /** Test mode: texts are recorded instead of pasted. */
  records: boolean
  windows: Pick<Foreground, 'restore' | 'restoreField' | 'isTerminal'>
  /** paste.ts: the clipboard, the keystroke, the clipboard back. */
  paste(text: string, keyTap: () => void, keepsOnClipboard: boolean, log: (message: string) => void): Promise<Outcome>
  keyTap(terminal: boolean): void
  writeClipboard(text: string): void | Promise<void>
  keepsOnClipboard(): boolean
  /** `cleanup`: what cleanup did, when it was on (the original and "ok" or why it failed). */
  addHistory(text: string, pasted: boolean, cleanup?: CleanupOutcome): void
  /** The text is done with: noted for tests, and the windows that show the history are told. */
  delivered(text: string): void
  log(message: string): void
  /** A moment for the shortcut's own keys to come up before Ctrl+V. */
  sleep?(ms: number): Promise<void>
}

export function makeDelivery(deps: DeliveryDeps) {
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)))
  /**
   * After the paste, whatever the history does: a history that could not be
   * written (a full disk) made a pasted text "Nicht eingefügt", and its
   * restore pasted it a second time.
   */
  const done = (text: string, pasted: boolean, cleanup?: CleanupOutcome) => {
    try { deps.addHistory(text, pasted, cleanup) } catch (error) { deps.log(`history: not saved (${(error as Error)?.message ?? error})`) }
    deps.delivered(text)
  }
  /**
   * @param target where this dictation started, noted when it began. Handed
   *   in with the text, not read from a variable once the 120 ms are over: a
   *   dictation started meanwhile replaced it, and the text went to the
   *   window of the next one.
   * @param cleanup what cleanup did, for the history.
   */
  return async function deliver(text: string, target: Promise<string | null>, cleanup?: CleanupOutcome): Promise<Outcome> {
    if (deps.records) {
      done(text, true, cleanup)
      return { pasted: true }
    }
    await sleep(120)
    // Back to the window the dictation started in, or onto the clipboard:
    // pasted into whatever was in front, the text went to the wrong app.
    const window = await target
    if (window && !(await deps.windows.restore(window))) {
      await deps.writeClipboard(text)
      deps.log('paste: the window the dictation started in is gone or would not come back')
      done(text, false, cleanup)
      return { pasted: false, reason: de('Auf der Zwischenablage, das Fenster ist nicht mehr da.', 'On the clipboard, the window is gone.') }
    }
    // The right window says nothing about the field in it: the user may have
    // clicked into another one while the text was on its way, or the page
    // removed it. Ctrl+V then went into the other field, or to a button and
    // counted as pasted (Codex VM-02). The Mac does the same (Paster.swift).
    if (window && deps.windows.restoreField && !(await deps.windows.restoreField(window))) {
      await deps.writeClipboard(text)
      deps.log('paste: the text field the dictation started in is gone or would not take the keyboard back')
      done(text, false, cleanup)
      return { pasted: false, reason: de('Auf der Zwischenablage, das Textfeld ließ sich nicht mehr auswählen.', 'On the clipboard, the text field could not be selected again.') }
    }
    const terminal = window ? await deps.windows.isTerminal(window) : false
    const outcome = await deps.paste(text, () => deps.keyTap(terminal), deps.keepsOnClipboard(), deps.log)
    deps.log(`paste: ${outcome.pasted ? 'sent Ctrl+V' : 'clipboard only'}, ${text.length} characters`)
    done(text, outcome.pasted, cleanup)
    return outcome
  }
}

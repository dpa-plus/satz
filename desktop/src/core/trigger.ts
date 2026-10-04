/**
 * Two quick taps of one key (right Ctrl on Windows and Linux) start a
 * dictation; holding the second tap is hold-to-talk. Any other key between the
 * taps breaks the sequence, so Ctrl+C with the right Ctrl is never a tap.
 * Ported from the Mac app's TriggerMonitor; the keyboard's own key repeat
 * while a key is held is ignored here, macOS never sent one.
 */
export class DoubleTap {
  static tapLength = 350
  static tapGap = 400

  private isDown = false
  private downAt: number | null = null
  private lastTapUpAt: number | null = null
  private interrupted = false
  private holding = false

  constructor(private onPress: () => void, private onRelease: () => void, private now: () => number = Date.now) {}

  keyDown(isTrigger: boolean) {
    if (!isTrigger) {
      this.interrupted = true
      this.lastTapUpAt = null
      return
    }
    if (this.isDown) return
    this.isDown = true
    const now = this.now()
    if (this.lastTapUpAt !== null && now - this.lastTapUpAt < DoubleTap.tapGap && !this.interrupted) {
      this.lastTapUpAt = null
      this.holding = true
      this.onPress()
    } else {
      this.downAt = now
      this.interrupted = false
    }
  }

  keyUp(isTrigger: boolean) {
    if (!isTrigger) return
    this.isDown = false
    const now = this.now()
    if (this.holding) {
      this.holding = false
      this.onRelease()
    } else if (this.downAt !== null && now - this.downAt < DoubleTap.tapLength && !this.interrupted) {
      this.lastTapUpAt = now
    }
    this.downAt = null
  }
}

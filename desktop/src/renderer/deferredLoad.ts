/**
 * Settings is drawn again when a model list or a download changes, but not
 * under someone typing: that emptied a half-typed word. It waits until the
 * field is left. A download changes once per percent, so the waiting is one
 * listener per field, not one per change: leaving the field after a download
 * had run a hundred settings:get and a hundred redraws back to back.
 */
export class LoadAfterBlur {
  private waiting = new Set<EventTarget>()

  later(field: EventTarget, load: () => void) {
    if (this.waiting.has(field)) return
    this.waiting.add(field)
    field.addEventListener('blur', () => { this.waiting.delete(field); load() }, { once: true })
  }
}

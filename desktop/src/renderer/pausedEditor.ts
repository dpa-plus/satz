export interface TextEdit {
  session: number
  sequence: number
  before: string
  text: string
  caret: number
}

/** Native text editing, without placing the transcription placeholders in the editor. */
export class PausedEditor {
  private readonly field = document.createElement('textarea')
  private enabled = false
  private session = -1
  private sequence = 0
  private pending = 0
  private before = ''
  private caret = -1

  constructor(private readonly host: HTMLElement, private readonly send: (edit: TextEdit) => void) {
    this.field.className = 'editor'
    this.field.rows = 1
    this.field.spellcheck = false
    this.field.addEventListener('input', () => this.commit())
    this.field.addEventListener('mouseup', () => this.selection())
    this.field.addEventListener('keyup', () => this.selection())
  }

  show(value: string, session: number, acknowledged: number, label: string) {
    this.enabled = true
    if (this.field.parentElement !== this.host) this.host.replaceChildren(this.field)
    this.field.ariaLabel = label
    if (session !== this.session) {
      this.session = session
      this.pending = 0
      this.caret = -1
    }
    // Main's earlier repaint must not erase keys typed since that snapshot.
    if (acknowledged < this.pending) return
    if (this.field.value !== value) {
      const start = this.field.selectionStart, end = this.field.selectionEnd
      this.field.value = value
      if (document.activeElement === this.field) this.field.setSelectionRange(Math.min(start, value.length), Math.min(end, value.length))
    }
    this.before = value
    this.resize()
  }

  hide() { this.enabled = false; this.caret = -1 }

  private selection() {
    if (this.field.selectionStart === this.field.selectionEnd) this.commit()
  }

  private commit() {
    if (!this.enabled) return
    const value = this.field.value, caret = this.field.selectionStart
    if (value === this.before && caret === this.caret) return
    const edit = { session: this.session, sequence: ++this.sequence, before: this.before, text: value, caret }
    this.before = value
    this.caret = caret
    this.pending = edit.sequence
    this.resize()
    this.send(edit)
  }

  private resize() {
    this.field.style.height = '0px'
    this.field.style.height = `${this.field.scrollHeight}px`
  }
}

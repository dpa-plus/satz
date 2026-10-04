/**
 * The card's text with two marks per character, as in the Mac app's
 * NSTextStorage: which recording it came from (`seg`) and whether it is one of
 * satz's placeholders (`mark`). 0 means none. Offsets are UTF-16 code units.
 */
export interface Range { location: number; length: number }
export interface Run { text: string; seg: number; mark: number }

export class Doc {
  private chars: string[] = []
  private seg: number[] = []
  private mark: number[] = []

  get length() { return this.chars.length }
  text() { return this.chars.join('') }

  /** The text as it will be pasted: everything but the placeholders. */
  plain() {
    let out = ''
    for (let i = 0; i < this.chars.length; i++) if (!this.mark[i]) out += this.chars[i]
    return out
  }

  insert(at: number, s: string, attrs: { seg?: number; mark?: number } = {}) {
    this.replace({ location: at, length: 0 }, s, attrs)
  }

  replace(range: Range, s: string, attrs: { seg?: number; mark?: number } = {}) {
    const units = s.split('')
    this.chars.splice(range.location, range.length, ...units)
    this.seg.splice(range.location, range.length, ...units.map(() => attrs.seg ?? 0))
    this.mark.splice(range.location, range.length, ...units.map(() => attrs.mark ?? 0))
  }

  delete(range: Range) { this.replace(range, '') }

  /** From the first to the last character carrying `id`, like NSUnionRange of its runs. */
  rangeOf(kind: 'seg' | 'mark', id: number): Range | null {
    const values = kind === 'seg' ? this.seg : this.mark
    const first = values.indexOf(id), last = values.lastIndexOf(id)
    return first < 0 ? null : { location: first, length: last - first + 1 }
  }

  markAt(index: number) { return this.mark[index] ?? 0 }

  clearSeg(range: Range) {
    for (let i = range.location; i < range.location + range.length; i++) this.seg[i] = 0
  }

  containsMark(range: Range) {
    for (let i = range.location; i < range.location + range.length; i++) if (this.mark[i]) return true
    return false
  }

  /** Neighbouring characters with the same marks, for drawing. */
  runs(): Run[] {
    const runs: Run[] = []
    for (let i = 0; i < this.chars.length; i++) {
      const last = runs[runs.length - 1]
      if (last && last.seg === this.seg[i] && last.mark === this.mark[i]) last.text += this.chars[i]
      else runs.push({ text: this.chars[i], seg: this.seg[i], mark: this.mark[i] })
    }
    return runs
  }

  clone() {
    const copy = new Doc()
    copy.chars = [...this.chars]; copy.seg = [...this.seg]; copy.mark = [...this.mark]
    return copy
  }

  setFrom(other: Doc) {
    this.chars = [...other.chars]; this.seg = [...other.seg]; this.mark = [...other.mark]
  }

  clear() { this.chars = []; this.seg = []; this.mark = [] }
}

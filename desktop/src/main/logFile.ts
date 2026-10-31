import fs from 'node:fs'

/**
 * satz.log in satz's own folder, and where it goes when that folder refuses
 * a line. A line that could not be written was lost without a word: a satz
 * that could not read its key left nothing in the log to say why. Now the
 * line goes to the second file (the temp folder), the first refusal is noted
 * there with its reason, and Settings shows both.
 */
export class LogFile {
  /** The system's code for the last line satz's folder refused; null while every line got there. */
  problem: string | null = null
  /** Lines that went to the second file instead. */
  refused = 0
  private wroteFallback = false

  constructor(readonly primary: string, readonly fallback: string, private append: (file: string, text: string) => void = fs.appendFileSync) {}

  write(line: string) {
    try {
      this.append(this.primary, line + '\n')
      return
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code ?? 'UNKNOWN'
      this.refused++
      const first = this.problem === null
      this.problem = code
      try {
        // Said once, at the first refusal, so the second file explains itself.
        const note = first ? `${line.slice(0, 24)} log: ${this.primary} refused a line (${code}); the log goes on here\n` : ''
        this.append(this.fallback, note + line + '\n')
        this.wroteFallback = true
      } catch { /* neither file: the console still has it */ }
    }
  }

  /** The file to open from Settings: satz's own, unless only the second one has lines. */
  get shown(): string {
    if (this.wroteFallback && !fs.existsSync(this.primary)) return this.fallback
    return this.primary
  }
}

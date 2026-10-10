import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'

/**
 * A PowerShell that stays running and takes one command per line, answering
 * with one line each. It takes about a second to start, too long to wait for
 * when a dictation begins, so one copy runs from the start (the window
 * helper, foreground.ts) or from the first dictation (media.ts). The script
 * says "ready" once it is set up.
 *
 * Where PowerShell refuses the script (Constrained Language Mode under
 * AppLocker or WDAC), it dies at once. A new one for every call cost a
 * PowerShell start in front of every dictation and a log line each time, so
 * a failed start is remembered, and the helper is left alone for a while.
 */
export type SpawnScript = (script: string) => ChildProcessWithoutNullStreams

const spawnPowerShell: SpawnScript = script => spawn('powershell.exe',
  // The script goes in as an argument, so stdin is left for the commands.
  ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { windowsHide: true })

/** How long a failed start is left alone. */
export const RETRY_AFTER = 5 * 60_000
/** A first start slower than this is given up on: waiting for ever held every paste back. */
export const START_TIMEOUT = 15_000

/** One process with the callbacks waiting for its next lines, so a dead process never takes a living one's answers. */
interface Run { child: ChildProcessWithoutNullStreams; waiting: ((line: string) => void)[] }

export class PowerShellHelper {
  /** The process starting or running, resolved once it said "ready". */
  private starting: Promise<Run> | null = null
  /** Until when the last start failed counts: asking before then fails at once. */
  private brokenUntil = 0

  /** @param name what the log calls it, e.g. "window helper". */
  constructor(private script: string, private name: string, private log: (message: string) => void,
    private spawnScript: SpawnScript = spawnPowerShell, private now: () => number = Date.now) {}

  /** Started ahead of the first call, where that takes long. */
  prepare() { this.start().catch(() => {}) }

  private start(): Promise<Run> {
    if (this.starting) return this.starting
    if (this.now() < this.brokenUntil) return Promise.reject(new Error(`${this.name} unavailable`))
    const child = this.spawnScript(this.script)
    const run: Run = { child, waiting: [] }
    const starting = new Promise<Run>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('did not start')), START_TIMEOUT)
      run.waiting.push(line => { clearTimeout(timer); if (line === 'ready') resolve(run); else reject(new Error(line)) })
      child.on('error', error => { clearTimeout(timer); reject(error) })
    })
    this.starting = starting
    const forget = () => { if (this.starting === starting) this.starting = null }
    starting.catch(error => {
      forget()
      child.kill()
      this.brokenUntil = this.now() + RETRY_AFTER
      this.log(`${this.name}: ${(error as Error).message}, left alone for ${RETRY_AFTER / 60_000} minutes`)
    })
    createInterface({ input: child.stdout }).on('line', line => run.waiting.shift()?.(line.trim()))
    // A write to a process that just ended is reported here, not as a crash.
    child.stdin.on('error', () => {})
    child.stderr.on('data', chunk => {
      const line = String(chunk).trim().split('\n')[0]
      // PowerShell reports progress as CLIXML on stderr; not an error.
      if (!line.startsWith('#< CLIXML')) this.log(`${this.name}: ${line}`)
    })
    child.on('exit', () => {
      forget()
      run.waiting.splice(0).forEach(answer => answer('error helper stopped'))
    })
    return starting
  }

  /**
   * The helper's one-line answer, or a rejection when it is unavailable or
   * does not answer in time. A late answer is still taken off the queue, so
   * the next call does not get it.
   */
  async ask(command: string, timeoutMs: number): Promise<string> {
    const run = await this.start()
    return new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('no answer')), timeoutMs)
      run.waiting.push(line => { clearTimeout(timer); resolve(line) })
      run.child.stdin.write(command + '\r\n')
    })
  }
}

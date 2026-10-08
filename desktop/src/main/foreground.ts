import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'
import { isWayland } from './paste'

/**
 * The window the user was typing in when a dictation started, and getting it
 * back before Ctrl+V. Without it the text went to whatever window was in
 * front when the answer came: another app the user had switched to, or
 * satz's own settings. The Mac app does the same with the app, window and
 * field (Paster.swift).
 *
 * Windows: user32 through a PowerShell helper that stays running. Linux X11:
 * xprop to read, xdotool or wmctrl to activate. Wayland lets no app do either,
 * so there nothing is checked.
 */
export interface Foreground {
  /** The window in front now, or null where that cannot be known. */
  current(): Promise<string | null>
  /** Brings the window back to the front. False if it is gone or will not come. */
  restore(window: string): Promise<boolean>
  prepare(): void
}

export function foreground(log: (message: string) => void): Foreground {
  if (process.platform === 'win32') return new WindowsForeground(log)
  if (process.platform === 'linux' && !isWayland()) return new X11Foreground()
  return { current: async () => null, restore: async () => true, prepare: () => {} }
}

// MARK: - Windows

const SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SatzWindow {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr window);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr process);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from, uint to, bool attach);
  public static string Focus(long handle) {
    IntPtr window = new IntPtr(handle);
    if (!IsWindow(window)) return "gone";
    if (GetForegroundWindow() == window) return "ok";
    if (IsIconic(window)) ShowWindow(window, 9);
    // Windows lets only the app in front hand the front away: borrowing its
    // input thread for a moment counts as that.
    uint front = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    uint mine = GetCurrentThreadId();
    AttachThreadInput(mine, front, true);
    SetForegroundWindow(window);
    BringWindowToTop(window);
    AttachThreadInput(mine, front, false);
    for (int i = 0; i < 25 && GetForegroundWindow() != window; i++) System.Threading.Thread.Sleep(20);
    return GetForegroundWindow() == window ? "ok" : "refused";
  }
}
"@
[Console]::Out.WriteLine('ready')
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    $words = $line.Split(' ')
    if ($words[0] -eq 'current') { [Console]::Out.WriteLine([SatzWindow]::GetForegroundWindow().ToInt64()) }
    elseif ($words[0] -eq 'focus') { [Console]::Out.WriteLine([SatzWindow]::Focus([long]$words[1])) }
    else { [Console]::Out.WriteLine('error unknown') }
  } catch {
    [Console]::Out.WriteLine('error ' + $_.Exception.Message)
  }
}
`

class WindowsForeground implements Foreground {
  private helper: ChildProcessWithoutNullStreams | null = null
  private waiting: ((line: string) => void)[] = []
  private ready: Promise<void> | null = null

  constructor(private log: (message: string) => void) {}

  private start(): Promise<void> {
    if (this.ready) return this.ready
    const encoded = Buffer.from(SCRIPT, 'utf16le').toString('base64')
    const helper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded], { windowsHide: true })
    this.helper = helper
    this.ready = new Promise((resolve, reject) => {
      this.waiting.push(line => (line === 'ready' ? resolve() : reject(new Error(line))))
      helper.on('error', reject)
    })
    createInterface({ input: helper.stdout }).on('line', line => this.waiting.shift()?.(line.trim()))
    helper.stderr.on('data', chunk => {
      const line = String(chunk).trim().split('\n')[0]
      if (!line.startsWith('#< CLIXML')) this.log(`window helper: ${line}`)
    })
    helper.on('exit', () => { this.helper = null; this.ready = null; this.waiting.splice(0).forEach(answer => answer('error helper stopped')) })
    return this.ready
  }

  private async ask(command: string): Promise<string> {
    await this.start()
    return new Promise<string>(resolve => {
      const timer = setTimeout(() => resolve('error no answer'), 3000)
      this.waiting.push(line => { clearTimeout(timer); resolve(line) })
      this.helper?.stdin.write(command + '\r\n')
    })
  }

  async current() {
    const answer = await this.ask('current').catch(() => 'error')
    return /^\d+$/.test(answer) && answer !== '0' ? answer : null
  }

  async restore(window: string) {
    const answer = await this.ask(`focus ${window}`).catch(() => 'error')
    if (answer !== 'ok') this.log(`window helper: ${answer}`)
    // A helper that cannot answer is no reason to hold the text back.
    return answer === 'ok' || answer.startsWith('error')
  }

  /** PowerShell takes a second or two to start: started with satz. */
  prepare() { this.start().catch(error => this.log(`window helper: ${(error as Error).message}`)) }
}

// MARK: - Linux X11

const run = (command: string, args: string[]) => new Promise<string | null>(resolve =>
  execFile(command, args, { timeout: 2000 }, (error, stdout) => resolve(error ? null : stdout.trim())))

class X11Foreground implements Foreground {
  async current() {
    const output = await run('xprop', ['-root', '_NET_ACTIVE_WINDOW'])
    return /0x[0-9a-f]+/i.exec(output ?? '')?.[0] ?? null
  }

  async restore(window: string) {
    if ((await this.current()) === window) return true
    // xdotool or wmctrl, whichever is there; with neither, the window cannot
    // be brought back, and the text is not pasted into the wrong one.
    if ((await run('xdotool', ['windowactivate', '--sync', String(parseInt(window, 16))])) !== null) return (await this.current()) === window
    if ((await run('wmctrl', ['-i', '-a', window])) !== null) {
      await new Promise(resolve => setTimeout(resolve, 150))
      return (await this.current()) === window
    }
    return false
  }

  prepare() {}
}

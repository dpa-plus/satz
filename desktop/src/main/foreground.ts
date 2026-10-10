import { execFile } from 'node:child_process'
import { isWayland } from './paste'
import { PowerShellHelper } from './powershell'

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
  /** A terminal, which pastes with Ctrl+Shift+V: Ctrl+V did nothing there. */
  isTerminal(window: string): Promise<boolean>
  prepare(): void
}

export function foreground(log: (message: string) => void): Foreground {
  if (process.platform === 'win32') return new WindowsForeground(log)
  if (process.platform === 'linux' && !isWayland()) return new X11Foreground()
  return { current: async () => null, restore: async () => true, isTerminal: async () => false, prepare: () => {} }
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

export class WindowsForeground implements Foreground {
  constructor(private log: (message: string) => void, private helper = new PowerShellHelper(SCRIPT, 'window helper', log)) {}

  private ask(command: string): Promise<string> {
    return this.helper.ask(command, 3000)
  }

  async current() {
    const answer = await this.ask('current').catch(() => null)
    return answer !== null && /^\d+$/.test(answer) && answer !== '0' ? answer : null
  }

  async restore(window: string) {
    // No answer at all: the helper is down, which was logged where it failed.
    // A helper that cannot answer is no reason to hold the text back.
    const answer = await this.ask(`focus ${window}`).catch(() => null)
    if (answer === null) return true
    if (answer !== 'ok') this.log(`window helper: ${answer}`)
    return answer === 'ok' || answer.startsWith('error')
  }

  /** Windows terminals take Ctrl+V. */
  async isTerminal() { return false }

  /** PowerShell takes a second or two to start: started with satz. */
  prepare() { this.helper.prepare() }
}

// MARK: - Linux X11

/** A command's output, or null if it is missing or failed. */
export type Run = (command: string, args: string[]) => Promise<string | null>
const execute: Run = (command, args) => new Promise<string | null>(resolve =>
  execFile(command, args, { timeout: 2000 }, (error, stdout) => resolve(error ? null : stdout.trim())))

export class X11Foreground implements Foreground {
  constructor(private run: Run = execute) {}

  async current() {
    const output = await this.run('xprop', ['-root', '_NET_ACTIVE_WINDOW'])
    const id = /0x[0-9a-f]+/i.exec(output ?? '')?.[0] ?? null
    // 0x0 is "no active window" (focus on the desktop, or between windows),
    // not a window to go back to: as 0 is none on Windows.
    return id !== null && parseInt(id, 16) !== 0 ? id : null
  }

  async restore(window: string) {
    if ((await this.current()) === window) return true
    // xdotool or wmctrl, whichever is there; with neither, the window cannot
    // be brought back, and the text is not pasted into the wrong one.
    if ((await this.run('xdotool', ['windowactivate', '--sync', String(parseInt(window, 16))])) !== null) return (await this.current()) === window
    if ((await this.run('wmctrl', ['-i', '-a', window])) !== null) {
      await new Promise(resolve => setTimeout(resolve, 150))
      return (await this.current()) === window
    }
    return false
  }

  async isTerminal(window: string) {
    const output = (await this.run('xprop', ['-id', window, 'WM_CLASS']))?.toLowerCase() ?? ''
    return TERMINALS.some(name => output.includes(`"${name}"`))
  }

  prepare() {}
}

/** WM_CLASS names of terminals, which paste with Ctrl+Shift+V. */
const TERMINALS = ['gnome-terminal', 'gnome-terminal-server', 'kgx', 'org.gnome.console', 'ptyxis', 'konsole', 'xterm', 'uxterm',
  'alacritty', 'kitty', 'tilix', 'terminator', 'xfce4-terminal', 'lxterminal', 'mate-terminal', 'qterminal', 'org.wezfurlong.wezterm',
  'wezterm', 'urxvt', 'rxvt', 'st-256color', 'foot', 'terminology', 'deepin-terminal', 'blackbox', 'com.raggesilver.blackbox', 'tabby', 'hyper']

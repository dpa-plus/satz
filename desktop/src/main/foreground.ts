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
 * Windows: user32 through a PowerShell helper that stays running, and UI
 * Automation for the text field in the window. Linux X11: xprop to read,
 * xdotool or wmctrl to activate; the window only. Wayland lets no app do
 * either, so there nothing is checked.
 */
export interface Foreground {
  /**
   * Where the keyboard is now: the window in front, on Windows with the text
   * field in it that has the keyboard. Opaque to the rest of satz, which
   * hands it back to `restore` and `restoreField`. Null where that cannot be
   * known.
   */
  current(): Promise<string | null>
  /** Brings the window back to the front. False if it is gone or will not come. */
  restore(target: string): Promise<boolean>
  /**
   * Puts the keyboard back into the text field the dictation started in, once
   * its window is in front. Only where the field is known (Windows): the
   * window alone let the text go into another field of it, or to a button
   * once the field was gone (Codex VM-02). False when the field is gone, will
   * not take the keyboard back, or takes no text now.
   */
  restoreField?(target: string): Promise<boolean>
  /** A terminal, which pastes with Ctrl+Shift+V: Ctrl+V did nothing there. */
  isTerminal(target: string): Promise<boolean>
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
# The text field with the keyboard, through UI Automation. Apart and allowed
# to fail: without it the window alone is checked, as before.
$fields = $false
try {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
  $references = @([System.Windows.Automation.AutomationElement].Assembly.Location, [System.Windows.Automation.ControlType].Assembly.Location, [System.Windows.Rect].Assembly.Location)
  Add-Type -IgnoreWarnings -ReferencedAssemblies $references -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
public static class SatzField {
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  // The fields noted when dictations began, by runtime id: SetFocus needs
  // the element itself, and finding it again by its id means walking the
  // whole window, thousands of elements on a web page.
  static readonly Dictionary<string, AutomationElement> noted = new Dictionary<string, AutomationElement>();
  static readonly List<string> order = new List<string>();
  static readonly object gate = new object();

  // The first UI Automation call of a process sets it up and can take a
  // moment: made at the start, not when the first dictation begins.
  static void Warming() { try { AutomationElement.FocusedElement.GetRuntimeId(); } catch (Exception) { } }
  public static void Warm() { Task.Run(new Action(Warming)); }

  // An app that hangs does not answer UI Automation either: given up on, so
  // the next command is not stuck behind it.
  static string Bounded(Func<string> work, int milliseconds) {
    Task<string> task = Task.Run(work);
    try { return task.Wait(milliseconds) ? task.Result : "busy"; }
    catch (AggregateException) { return "error field"; }
  }

  static string Id(AutomationElement element) {
    int[] parts = element.GetRuntimeId();
    if (parts == null || parts.Length == 0) return null;
    string[] text = new string[parts.Length];
    for (int i = 0; i < parts.Length; i++) text[i] = parts[i].ToString(CultureInfo.InvariantCulture);
    return string.Join(".", text);
  }

  static AutomationElement Focused() {
    try { return AutomationElement.FocusedElement; } catch (Exception) { return null; }
  }

  static bool Is(AutomationElement element, string id) {
    try { return element != null && Id(element) == id; } catch (Exception) { return false; }
  }

  // A field that takes typing: an edit, or a document that says it is not
  // read-only. A web page is a document too, and no place for the text.
  static bool Editable(AutomationElement element) {
    try {
      var info = element.Current;
      if (!info.IsEnabled) return false;
      bool edit = info.ControlType.Id == ControlType.Edit.Id;
      if (!edit && info.ControlType.Id != ControlType.Document.Id) return false;
      object pattern;
      if (element.TryGetCurrentPattern(ValuePattern.Pattern, out pattern)) return !((ValuePattern)pattern).Current.IsReadOnly;
      return edit;
    } catch (Exception) { return false; }
  }

  // The text field with the keyboard in this window, noted for Restore; its
  // runtime id, or "none" when the keyboard is anywhere else (a button, a
  // terminal, an app that does not say): the window alone is checked then.
  public static string Capture(long window) { return Bounded(delegate { return Noting(window); }, 1500); }

  static string Noting(long window) {
    AutomationElement element = Focused();
    if (element == null || !Editable(element)) return "none";
    uint process;
    GetWindowThreadProcessId(new IntPtr(window), out process);
    string id;
    try {
      if (element.Current.ProcessId != (int)process) return "none";
      id = Id(element);
    } catch (Exception) { return "none"; }
    if (id == null) return "none";
    lock (gate) {
      if (!noted.ContainsKey(id)) order.Add(id);
      noted[id] = element;
      // One per dictation not pasted yet is all that is needed.
      while (order.Count > 16) { noted.Remove(order[0]); order.RemoveAt(0); }
    }
    return id;
  }

  // Puts the keyboard back into the field noted as id: "ok" when it is
  // there and takes text, otherwise why not.
  public static string Restore(string id) { return Bounded(delegate { return Restoring(id); }, 2000); }

  static string Restoring(string id) {
    AutomationElement focused = Focused();
    if (Is(focused, id)) return Editable(focused) ? "ok" : "noedit";
    AutomationElement field;
    lock (gate) { noted.TryGetValue(id, out field); }
    // Noted by a helper that has stopped since: nothing to give the keyboard to.
    if (field == null) return "lost";
    try { field.SetFocus(); }
    catch (ElementNotAvailableException) { return "gone"; }
    catch (Exception) { return "refused"; }
    // A web page takes the focus a moment later, in another process.
    for (int i = 0; i < 25; i++) {
      focused = Focused();
      if (Is(focused, id)) return Editable(focused) ? "ok" : "noedit";
      Thread.Sleep(20);
    }
    return "refused";
  }
}
"@
  [SatzField]::Warm()
  $fields = $true
} catch {
  [Console]::Error.WriteLine('no text fields: ' + ($_.Exception.Message -replace '\s+', ' '))
}
[Console]::Out.WriteLine('ready')
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    $words = $line.Split(' ')
    if ($words[0] -eq 'current') { [Console]::Out.WriteLine([SatzWindow]::GetForegroundWindow().ToInt64()) }
    elseif ($words[0] -eq 'focus') { [Console]::Out.WriteLine([SatzWindow]::Focus([long]$words[1])) }
    elseif ($words[0] -eq 'capture') {
      if ($fields) { [Console]::Out.WriteLine([SatzField]::Capture([long]$words[1])) } else { [Console]::Out.WriteLine('none') }
    }
    elseif ($words[0] -eq 'field') {
      if ($fields) { [Console]::Out.WriteLine([SatzField]::Restore($words[1])) } else { [Console]::Out.WriteLine('error no text fields') }
    }
    else { [Console]::Out.WriteLine('error unknown') }
  } catch {
    [Console]::Out.WriteLine('error ' + $_.Exception.Message)
  }
}
`

/** The C# handed to PowerShell, for a test that it holds nothing PowerShell or the old compiler would trip over. */
export const WINDOW_HELPER_SCRIPT = SCRIPT

/**
 * A Windows target: the window handle, and after a "|" the UI Automation
 * runtime id of the text field that had the keyboard ("131074|42.1001.11").
 * One string, so main.ts passes it around as it did the window alone.
 */
const FIELD = '|'
const RUNTIME_ID = /^-?\d+(\.-?\d+)*$/

function parts(target: string): { window: string; field: string | null } {
  const at = target.indexOf(FIELD)
  return at < 0 ? { window: target, field: null } : { window: target.slice(0, at), field: target.slice(at + 1) }
}

/**
 * The helper's answers to "field" that say the field is not back. Anything
 * else it might say ("error …") is the helper failing, not the field.
 */
const NOT_BACK = new Set(['gone', 'refused', 'noedit', 'lost', 'busy'])

export class WindowsForeground implements Foreground {
  constructor(private log: (message: string) => void, private helper = new PowerShellHelper(SCRIPT, 'window helper', log)) {}

  private ask(command: string): Promise<string> {
    return this.helper.ask(command, 3000)
  }

  async current() {
    const answer = await this.ask('current').catch(() => null)
    const window = answer !== null && /^\d+$/.test(answer) && answer !== '0' ? answer : null
    if (window === null) return null
    // The field too: the window alone let the text go into whichever field
    // of it had the keyboard by the time the text came.
    const field = await this.ask(`capture ${window}`).catch(() => null)
    return field !== null && RUNTIME_ID.test(field) ? `${window}${FIELD}${field}` : window
  }

  async restore(target: string) {
    // No answer at all: the helper is down, which was logged where it failed.
    // A helper that cannot answer is no reason to hold the text back.
    const answer = await this.ask(`focus ${parts(target).window}`).catch(() => null)
    if (answer === null) return true
    if (answer !== 'ok') this.log(`window helper: ${answer}`)
    return answer === 'ok' || answer.startsWith('error')
  }

  async restoreField(target: string) {
    const { field } = parts(target)
    if (field === null) return true
    const answer = await this.ask(`field ${field}`).catch(() => null)
    // The helper itself down or failing: as for the window, no reason to
    // hold the text back. But a field that is gone, will not take the
    // keyboard back or takes no text now gets no Ctrl+V: it went to a button
    // or another field instead, and counted as pasted. Nor does an app that
    // does not answer: it took Ctrl+V once it woke, after the clipboard was
    // handed back, and pasted that.
    if (answer === 'ok' || answer === null) return true
    this.log(`window helper: text field ${answer}`)
    return !NOT_BACK.has(answer)
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

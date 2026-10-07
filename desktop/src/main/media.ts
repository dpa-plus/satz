import { execFile, spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createInterface } from 'node:readline'

/**
 * Pauses music and videos while the user dictates and plays them again when
 * the card closes, like the Mac app's MediaPause. Only what was really playing
 * is paused, and only what satz paused plays again; something the user starts
 * in between is left alone. Pause and Play are separate commands, never a
 * toggle, so neither can start something by mistake.
 *
 * Linux: MPRIS over D-Bus, which Spotify, Firefox, Chrome and VLC all speak,
 * through gdbus. Windows: the system media controls (the ones in the volume
 * flyout), through a PowerShell helper that stays running.
 */
export interface Players {
  /** Pauses what is playing and returns who it paused. */
  pause(): Promise<string[]>
  /** Plays these again, if they are still paused. */
  play(ids: string[]): Promise<void>
}

export class MediaPause {
  private pausing: Promise<string[]> | null = null

  constructor(private players: Players | null, private isOn: () => boolean, private log: (message: string) => void) {}

  dictationStarted() {
    if (!this.players || !this.isOn() || this.pausing) return
    this.pausing = this.players.pause().catch(error => { this.log(`media: ${(error as Error).message}`); return [] })
    this.pausing.then(ids => { if (ids.length) this.log(`media paused: ${ids.join(', ')}`) })
  }

  async dictationEnded() {
    const pausing = this.pausing
    this.pausing = null
    if (!pausing || !this.players) return
    const ids = await pausing
    if (ids.length === 0) return
    await this.players.play(ids).catch(error => this.log(`media: ${(error as Error).message}`))
    this.log(`media resumed: ${ids.join(', ')}`)
  }
}

export function systemPlayers(log: (message: string) => void): Players | null {
  if (process.platform === 'linux') return new Mpris()
  if (process.platform === 'win32') return new WindowsMedia(log)
  return null
}

// MARK: - Linux

function gdbus(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => execFile('gdbus', ['call', '--session', ...args], { timeout: 1500 }, (error, out) => (error ? reject(error) : resolve(out))))
}

class Mpris implements Players {
  private async names(): Promise<string[]> {
    const out = await gdbus(['--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.ListNames'])
    return [...out.matchAll(/'(org\.mpris\.MediaPlayer2\.[^']+)'/g)].map(match => match[1])
  }

  private async status(name: string): Promise<string> {
    const out = await gdbus(['--dest', name, '--object-path', '/org/mpris/MediaPlayer2', '--method', 'org.freedesktop.DBus.Properties.Get',
      'org.mpris.MediaPlayer2.Player', 'PlaybackStatus'])
    return /'(\w+)'/.exec(out)?.[1] ?? ''
  }

  private call(name: string, method: 'Pause' | 'Play') {
    return gdbus(['--dest', name, '--object-path', '/org/mpris/MediaPlayer2', '--method', `org.mpris.MediaPlayer2.Player.${method}`])
  }

  async pause() {
    const paused: string[] = []
    for (const name of await this.names()) {
      if ((await this.status(name).catch(() => '')) !== 'Playing') continue
      await this.call(name, 'Pause')
      paused.push(name)
    }
    return paused
  }

  async play(names: string[]) {
    for (const name of names) {
      if ((await this.status(name).catch(() => '')) === 'Paused') await this.call(name, 'Play').catch(() => {})
    }
  }
}

// MARK: - Windows

/**
 * PowerShell takes about a second to start, too long to wait for when a
 * dictation begins, so one copy runs from the first dictation on and takes
 * commands on stdin: "pause" answers with the ids it paused, "play <ids>".
 */
const SCRIPT = String.raw`
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation` + '`' + String.raw`1' } | Select-Object -First 1
function Await($operation, [Type]$type) { $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation)); $task.Wait(-1) | Out-Null; $task.Result }
$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$manager = Await ($managerType::RequestAsync()) $managerType
[Console]::Out.WriteLine('ready')
while ($null -ne ($line = [Console]::In.ReadLine())) {
  try {
    $words = $line.Split(' ')
    $done = @()
    foreach ($session in $manager.GetSessions()) {
      $status = $session.GetPlaybackInfo().PlaybackStatus.ToString()
      $id = $session.SourceAppUserModelId
      if ($words[0] -eq 'pause' -and $status -eq 'Playing') {
        if (Await ($session.TryPauseAsync()) ([bool])) { $done += $id }
      } elseif ($words[0] -eq 'play' -and $status -eq 'Paused' -and $words -contains $id) {
        if (Await ($session.TryPlayAsync()) ([bool])) { $done += $id }
      }
    }
    [Console]::Out.WriteLine('ok ' + ($done -join ' '))
  } catch {
    [Console]::Out.WriteLine('error ' + $_.Exception.Message)
  }
}
`

class WindowsMedia implements Players {
  private helper: ChildProcessWithoutNullStreams | null = null
  private waiting: ((line: string) => void)[] = []
  private ready: Promise<void> | null = null

  constructor(private log: (message: string) => void) {}

  private start(): Promise<void> {
    if (this.ready) return this.ready
    // The script goes in as an argument, so stdin is left for the commands.
    const encoded = Buffer.from(SCRIPT, 'utf16le').toString('base64')
    const helper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded], { windowsHide: true })
    this.helper = helper
    this.ready = new Promise((resolve, reject) => {
      this.waiting.push(line => (line === 'ready' ? resolve() : reject(new Error(line))))
      helper.on('error', reject)
    })
    createInterface({ input: helper.stdout }).on('line', line => this.waiting.shift()?.(line.trim()))
    helper.stderr.on('data', chunk => this.log(`media helper: ${String(chunk).trim().split('\n')[0]}`))
    helper.on('exit', () => { this.helper = null; this.ready = null; this.waiting.splice(0).forEach(answer => answer('error helper stopped')) })
    return this.ready
  }

  private async ask(command: string): Promise<string[]> {
    await this.start()
    const answer = await new Promise<string>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('no answer')), 3000)
      this.waiting.push(line => { clearTimeout(timer); resolve(line) })
      this.helper?.stdin.write(command + '\r\n')
    })
    if (answer.startsWith('error')) throw new Error(answer)
    return answer.slice(3).split(' ').filter(Boolean)
  }

  pause() { return this.ask('pause') }
  async play(ids: string[]) { await this.ask(`play ${ids.join(' ')}`) }
}

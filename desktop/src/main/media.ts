import { execFile } from 'node:child_process'
import { PowerShellHelper } from './powershell'

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
  /** Plays these again where they are still paused, and returns which. */
  play(ids: string[]): Promise<string[]>
  /** Gets ready ahead of the first dictation, where that takes long. */
  prepare?(): void
}

export class MediaPause {
  /** Who satz paused and has not played again yet. */
  private paused: string[] = []
  private pausing: Promise<void> | null = null
  private resuming: ReturnType<typeof setTimeout> | null = null
  /** The Play command that is on its way: it can land after the next dictation began (see dictationStarted). */
  private playing: Promise<void> | null = null
  /** Recordings begun so far: a dictation that ends while a pause is still running only plays the music if no other began meanwhile. */
  private started = 0

  constructor(private players: Players | null, private isOn: () => boolean, private log: (message: string) => void) {
    if (isOn()) this.prepare()
  }

  /** For when the switch is turned on later: the Windows helper takes seconds to start. */
  prepare() { this.players?.prepare?.() }

  dictationStarted() {
    this.started++
    // The next dictation right after the last one: the music stays paused.
    if (this.resuming) { clearTimeout(this.resuming); this.resuming = null }
    if (!this.players || !this.isOn() || this.paused.length > 0 || this.pausing) return
    // The music is being played again from the dictation before, and a Play
    // that is on its way takes effect after the player still reported paused:
    // asked now, nothing would be paused and the music would start inside this
    // recording. Paused once that Play has landed.
    const players = this.players
    this.pausing = (this.playing ? this.playing.then(() => players.pause()) : players.pause())
      .then(ids => { this.paused = ids; if (ids.length) this.log(`media paused: ${ids.join(', ')}`) })
      .catch(error => this.log(`media: ${(error as Error).message}`))
      .finally(() => { this.pausing = null })
  }

  async dictationEnded() {
    const mine = this.started
    await this.pausing
    // Another dictation began while the pause command was still running (the
    // first one was thrown away at once, say): its start found nothing to
    // cancel yet, and playing now would put the music into its microphone.
    // It plays the music when it ends.
    if (mine !== this.started) return
    if (this.resuming) clearTimeout(this.resuming)
    // A moment's grace: two dictations in a row did play-pause between them.
    this.resuming = setTimeout(() => { this.resuming = null; void this.resume() }, 800)
  }

  /** satz quits: what it paused plays again, also in the middle of a dictation. */
  async quitting() {
    if (this.resuming) { clearTimeout(this.resuming); this.resuming = null }
    await this.pausing
    await this.resume()
    // A Play sent a moment ago is still on its way: satz leaving now would not wait for it.
    await this.playing
  }

  private resume(): Promise<void> {
    const ids = this.paused
    this.paused = []
    if (ids.length === 0 || !this.players) return Promise.resolve()
    const run: Promise<void> = this.players.play(ids)
      .catch(error => { this.log(`media: ${(error as Error).message}`); return [] as string[] })
      .then(resumed => { this.log(resumed.length ? `media resumed: ${resumed.join(', ')}` : 'media left as the user set it') })
      .finally(() => { if (this.playing === run) this.playing = null })
    this.playing = run
    return run
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
      // One player failing must not lose the ones already paused.
      if (await this.call(name, 'Pause').then(() => true, () => false)) paused.push(name)
    }
    return paused
  }

  async play(names: string[]) {
    const played: string[] = []
    for (const name of names) {
      if ((await this.status(name).catch(() => '')) !== 'Paused') continue
      await this.call(name, 'Play')
      played.push(name)
    }
    return played
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
$ProgressPreference = 'SilentlyContinue'
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
  private helper: PowerShellHelper

  constructor(log: (message: string) => void) {
    this.helper = new PowerShellHelper(SCRIPT, 'media helper', log)
  }

  private async ask(command: string): Promise<string[]> {
    // Generous: an answer thrown away after pausing would never be resumed.
    const answer = await this.helper.ask(command, 8000)
    if (answer.startsWith('error')) throw new Error(answer)
    return answer.slice(3).split(' ').filter(Boolean)
  }

  /** PowerShell takes seconds to start: started with satz, not with the first dictation. */
  prepare() { this.helper.prepare() }
  pause() { return this.ask('pause') }
  play(ids: string[]) { return this.ask(`play ${ids.join(' ')}`) }
}

import assert from 'node:assert/strict'
import * as childProcess from 'node:child_process'
import Module from 'node:module'
import test from 'node:test'
import type { MediaPause as MediaPauseClass, Players } from '../src/main/media'
import { deferred, settle } from './sessionHarness'

/*
 * Codex's hunt of 14.10.2026, F09: on Linux the music came back inside the
 * next recording. A finishes; its grace period ends and satz sends MPRIS
 * Play, which the player takes a moment to act on. B begins in that moment:
 * the player still reports "Paused", so B found nothing to pause and owned no
 * pause, and then A's Play landed in B's microphone. Based on Codex's
 * linux-media.test.ts (proofs/desktop-review): the real MPRIS adapter and the
 * real coordinator, with only the gdbus process replaced by a fake that
 * answers the way a player does. No D-Bus, no player.
 */

type Media = typeof import('../src/main/media')

/** media.ts with `gdbus` replaced: the commands it was asked, in order, and a player whose Play lands when the test says so. */
function linuxPlayers() {
  let playing = true
  const asked: string[] = []
  const enteredPlay = deferred()
  const finishPlay = deferred()
  const fakeExecFile = (_command: string, args: string[], _options: unknown, callback: (error: unknown, output: string) => void) => {
    const method = args[args.indexOf('--method') + 1]
    asked.push(method.split('.').at(-1)!)
    if (method.endsWith('.ListNames')) callback(null, "(['org.mpris.MediaPlayer2.satzSynthetic'],)")
    else if (method.endsWith('.Get')) callback(null, `(< '${playing ? 'Playing' : 'Paused'}' >,)`)
    else if (method.endsWith('.Pause')) { playing = false; callback(null, '()') }
    else if (method.endsWith('.Play')) {
      // Accepted now, acted on later: what the player does between the command and the sound.
      enteredPlay.resolve()
      void finishPlay.promise.then(() => { playing = true; callback(null, '()') })
    } else throw new Error(`Unexpected command: ${method}`)
  }
  const internals = Module as unknown as { _load: (request: string, ...rest: unknown[]) => unknown }
  const realLoad = internals._load
  internals._load = function (request: string, ...rest: unknown[]) {
    return request === 'node:child_process' ? { ...childProcess, execFile: fakeExecFile } : realLoad.call(this, request, ...rest)
  }
  let media: Media
  try {
    const file = require.resolve('../src/main/media')
    delete require.cache[file]
    media = require(file) as Media
  } finally { internals._load = realLoad }
  const platform = Object.getOwnPropertyDescriptor(process, 'platform')!
  Object.defineProperty(process, 'platform', { ...platform, value: 'linux' })
  let players: Players
  try { players = media.systemPlayers(() => {})! } finally { Object.defineProperty(process, 'platform', platform) }
  return { media, players, asked, enteredPlay, finishPlay, isPlaying: () => playing }
}

test('F09: a Play that is still on its way when the next dictation begins does not put the music into its recording', async () => {
  const { media, players, asked, enteredPlay, finishPlay, isPlaying } = linuxPlayers()
  assert.equal(players.constructor.name, 'Mpris', 'the real Linux adapter')
  const coordinator: MediaPauseClass = new media.MediaPause(players, () => true, () => {})

  coordinator.dictationStarted(); await settle()
  assert.equal(isPlaying(), false, 'A pauses the music')
  await coordinator.dictationEnded()
  // The grace period ends and Play goes out; the player has not acted on it yet.
  await enteredPlay.promise

  coordinator.dictationStarted(); await settle()
  assert.equal(isPlaying(), false, 'B begins while that Play is on its way')

  // The Play lands. B is recording.
  finishPlay.resolve(); await settle()
  assert.equal(isPlaying(), false, 'the music is paused again for B: the old Play must not play into its microphone')
  assert.equal(asked.at(-1), 'Pause', asked.join(','))
  assert.deepEqual(asked.filter(command => command === 'Play'), ['Play'], 'and nothing plays twice')

  // B ends: now it is B that plays the music again, once.
  await coordinator.quitting()
  assert.equal(isPlaying(), true, 'satz leaves the music as it found it')
})

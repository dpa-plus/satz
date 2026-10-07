import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MediaPause, type Players } from '../src/main/media'

/** A player that is playing until paused, and logs every command. */
function fakePlayers() {
  const log: string[] = []
  let playing = true
  const players: Players = {
    async pause() { if (!playing) return []; playing = false; log.push('pause'); return ['player'] },
    async play(ids) { if (playing || ids.length === 0) return []; playing = true; log.push('play'); return ids },
  }
  return { players, log, userPlays: () => { playing = true }, userPauses: () => { playing = false } }
}
const wait = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

test('paused while dictating, played again after, and two dictations in a row pause once', async () => {
  const { players, log } = fakePlayers()
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted(); await wait(10)
  await media.dictationEnded()
  media.dictationStarted(); await wait(10)
  await media.dictationEnded(); await wait(900)
  assert.deepEqual(log, ['pause', 'play'])
})

test('music started by hand during the dictation is left alone', async () => {
  const { players, log, userPlays } = fakePlayers()
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted(); await wait(10)
  userPlays()
  await media.dictationEnded(); await wait(900)
  assert.deepEqual(log, ['pause'])
})

test('quitting in the middle of a dictation plays the music again', async () => {
  const { players, log } = fakePlayers()
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted(); await wait(10)
  await media.quitting()
  assert.deepEqual(log, ['pause', 'play'])
})

test('nothing playing: nothing paused, nothing played', async () => {
  const { players, log, userPauses } = fakePlayers()
  userPauses()
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted(); await wait(10)
  await media.dictationEnded(); await wait(900)
  assert.deepEqual(log, [])
})

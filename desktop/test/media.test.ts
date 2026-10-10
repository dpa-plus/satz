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

test('a pause still running when its dictation ends does not play the music during the next dictation', async () => {
  // Dictation 1 is thrown away at once, while the player is still being asked
  // to pause (a cold helper takes seconds); dictation 2 starts inside that
  // window. The first one's ending used to arm the resume after the pause
  // came back, with dictation 2 still recording.
  let finishPause!: (ids: string[]) => void
  const actions: string[] = []
  const players: Players = {
    pause: () => { actions.push('pause'); return new Promise<string[]>(resolve => { finishPause = resolve }) },
    async play(ids) { actions.push('play'); return ids },
  }
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted()
  const first = media.dictationEnded()
  media.dictationStarted()
  finishPause(['player']); await first
  await wait(900)
  assert.deepEqual(actions, ['pause'], 'silent while dictation 2 is recording')
  await media.dictationEnded(); await wait(900)
  assert.deepEqual(actions, ['pause', 'play'], 'played when dictation 2 ends')
})

test('two dictations whose first pause was slow still pause once and play once', async () => {
  let finishPause!: (ids: string[]) => void
  const actions: string[] = []
  const players: Players = {
    pause: () => { actions.push('pause'); return new Promise<string[]>(resolve => { finishPause = resolve }) },
    async play(ids) { actions.push('play'); return ids },
  }
  const media = new MediaPause(players, () => true, () => {})
  media.dictationStarted()
  media.dictationStarted() // a resume after a pause inside the same dictation
  finishPause(['player'])
  await media.dictationEnded(); await wait(900)
  assert.deepEqual(actions, ['pause', 'play'])
})

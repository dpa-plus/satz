import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { isDownloaded, markerPath, speedPath } from '../src/main/localFiles'
import { B, place, setup, speech } from './lifecycleHarness'

/**
 * Codex's bug hunt of 14 October 2026, F15: a test copy of satz on the
 * user's models (canChangeFiles false) still removed the marker of a model
 * whose files it missed, and wrote the speed test's result beside the models.
 * Each test fails on the code before the fix.
 */

/** A model whose marker is there but not its files: half removed by hand, or still being written by the real satz. */
function markerOnly(dir: string, id: string) {
  fs.rmSync(path.join(dir, id), { recursive: true, force: true })
  fs.writeFileSync(markerPath(dir, id), 'now')
}

test('F15: asking a read-only LocalModels for a model\'s state never removes its marker', () => {
  const { local, dir } = setup({ canChangeFiles: false }, [B])
  try {
    markerOnly(dir, B)
    assert.equal(local.state(B).kind, 'missing', 'still not usable')
    assert.equal(fs.existsSync(markerPath(dir, B)), true, 'the marker is the real satz\'s, and stays')
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('F15: where satz may change the folder, the stale marker still goes, as before', () => {
  const { local, dir } = setup({}, [B])
  try {
    markerOnly(dir, B)
    assert.equal(local.state(B).kind, 'missing')
    assert.equal(fs.existsSync(markerPath(dir, B)), false)
    // The helper itself, as before.
    fs.writeFileSync(markerPath(dir, B), 'now')
    assert.equal(isDownloaded(dir, B), false)
    assert.equal(fs.existsSync(markerPath(dir, B)), false)
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

test('F15: a speed test in read-only mode writes nothing beside the models, and its number is still shown', async () => {
  const { local, dir } = setup({ canChangeFiles: false }, [B])
  try {
    place(dir, B)
    const before = fs.readdirSync(dir).sort()
    assert.equal(await local.measure(B, speech, [], 'de'), 'done')
    assert.deepEqual(fs.readdirSync(dir).sort(), before, 'the folder is as it was')
    assert.equal(fs.existsSync(speedPath(dir, B)), false)
    assert.ok(local.speed(B), 'Settings shows the speed until satz quits')
  } finally {
    await local.unload()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('F15: where satz may change the folder, the speed is kept beside the model, as before', async () => {
  const { local, dir } = setup({}, [B])
  try {
    assert.equal(await local.measure(B, speech, [], 'de'), 'done')
    assert.equal(fs.existsSync(speedPath(dir, B)), true)
  } finally {
    await local.unload()
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

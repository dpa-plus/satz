import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import type { Language } from '../src/core/language'
import { LocalEngine } from '../src/main/localEngine'
import type { LocalState } from '../src/main/localFiles'

const tick = (ms = 0) => new Promise(resolve => setTimeout(resolve, ms))
async function until(done: () => boolean) {
  for (let i = 0; i < 400 && !done(); i++) await tick(2)
  assert.ok(done(), 'timed out')
}
const gate = () => { let open = () => {}; const opened = new Promise<void>(resolve => { open = resolve }); return { opened, open } }

interface FakeModel { id: string; freed: boolean }

/**
 * An engine whose download can be held open, and which, like transformers.js
 * did, keeps reporting progress for a moment after its signal aborts.
 */
class Fake extends LocalEngine<FakeModel> {
  fetching = gate()
  runs: string[] = []
  protected async fetchAndLoad(id: string, progress: (fraction: number) => void, signal: AbortSignal) {
    progress(0.3)
    await this.fetching.opened
    progress(0.6)
    signal.throwIfAborted()
    progress(1)
    return this.load(id)
  }
  protected async load(id: string) { await tick(1); return { id, freed: false } }
  protected async free(model: FakeModel) { model.freed = true }
  protected async run(_samples: Float32Array, model: FakeModel, _vocabulary: string[], _spoken: Language) {
    assert.equal(model.freed, false, 'used after it was let go')
    this.runs.push(model.id)
    return model.id
  }
}

const speech = new Float32Array(16_000).fill(0.1)
async function withFake(body: (engine: Fake, states: LocalState[]) => Promise<void>) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-engine-'))
  const states: LocalState[] = []
  const engine = new Fake(dir, () => {}, (_id, state) => states.push(state))
  try { await body(engine, states) } finally {
    engine.fetching.open()
    fs.rmSync(dir, { recursive: true, force: true })
  }
}

test('after Cancel, nothing a download still reports takes its card back to "downloading"', () => withFake(async (engine, states) => {
  engine.download('a/large')
  await until(() => states.some(state => state.kind === 'downloading' && state.fraction > 0))
  engine.cancel('a/large')
  const before = states.length
  engine.fetching.open()
  await until(() => states.at(-1)?.kind === 'missing')
  await tick(10)
  assert.deepEqual(states.slice(before).map(state => state.kind), ['missing'])
}))

test('letting go of every model does not wait for a download under way: the next dictation runs at once', () => withFake(async (engine, states) => {
  engine.warmUp('a/base')
  assert.equal(await engine.transcribe(speech, 'a/base', [], 'de'), 'a/base')
  engine.download('a/large')
  await until(() => states.some(state => state.kind === 'downloading'))
  const dictation = engine.unload().then(() => engine.transcribe(speech, 'a/base', [], 'de'))
  const first = await Promise.race([dictation, tick(300).then(() => 'still waiting for the download')])
  assert.equal(first, 'a/base')
  // The download goes on and arrives.
  engine.fetching.open()
  await until(() => states.at(-1)?.kind === 'ready')
}))

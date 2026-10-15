import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { Cleaner } from '../src/main/cleanup'

const listed = (models: string[]) => new Response(JSON.stringify({ data: models.map(id => ({ id })) }))
const base = 'http://localhost:11434/v1'
const tick = () => new Promise(resolve => setTimeout(resolve, 0))

for (const latestFails of [false, true]) {
  test(`a late model discovery cannot replace a newer ${latestFails ? 'failure' : 'list'}`, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-discovery-order-'))
    const waiting: { resolve(value: Response): void; reject(error: Error): void }[] = []
    const cleaner = new Cleaner({
      dir,
      settings: () => ({ provider: 'ollama', model: '', address: '', level: 'light', customPrompt: '', vocabulary: [] }),
      readAccount: () => null, log() {}, changed() {},
      fetcher: (async (url: string) => String(url).endsWith('/models')
        ? new Promise<Response>((resolve, reject) => waiting.push({ resolve, reject }))
        : new Response(JSON.stringify({ choices: [{ message: { content: 'Hallo Welt.' } }] }))) as typeof fetch,
    })
    try {
      cleaner.installedAt('ollama', base)
      const run = cleaner.run('hallo welt', { trying: true })
      assert.equal(waiting.length, 2, 'Settings and Try both requested discovery')
      if (latestFails) waiting[1].reject(new Error('synthetic unavailable server'))
      else waiting[1].resolve(listed(['new-model']))
      const result = await run
      assert.equal(result.model, latestFails ? '' : 'new-model')
      assert.equal(cleaner.installedAt('ollama', base).state, latestFails ? 'down' : 'ok')
      waiting[0].resolve(listed(['old-model']))
      await tick()
      const current = cleaner.installedAt('ollama', base)
      assert.equal(current.state, latestFails ? 'down' : 'ok')
      assert.deepEqual(current.models, latestFails ? [] : ['new-model'])
      // An unrelated address has its own discovery and state.
      const other = `${base}/other`
      assert.equal(cleaner.installedAt('ollama', other).state, 'loading')
      waiting[2].resolve(listed(['other-model']))
      await tick()
      assert.deepEqual(cleaner.installedAt('ollama', other).models, ['other-model'])
      assert.deepEqual(cleaner.installedAt('ollama', base).models, latestFails ? [] : ['new-model'])
    } finally { fs.rmSync(dir, { recursive: true, force: true }) }
  })
}

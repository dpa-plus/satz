import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
import { isCleanupProvider } from '../src/core/cleanupProviders'
import { setLanguage } from '../src/core/language'
import { Cleaner, type CleanupSettings } from '../src/main/cleanup'

/*
 * "Ausprobieren" says whose answer it shows: the provider and the model. The
 * page (settings.ts) already prefers what the app's reply says over what it
 * asked for, but the reply carried neither, so for Ollama and LM Studio, where
 * the first installed model is chosen only in the main process, the label
 * could name a model that did not answer. main.ts's handler is run as written
 * there (unit tests do not reach main.ts).
 */

setLanguage('en')
const said = 'ähm also der build ist äh gefailed weil the tests are flaky'
const cleaned = 'Also, der Build ist gefailed, weil the tests are flaky.'

const scratch: string[] = []
afterEach(() => { for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })

type Reply = Record<string, unknown> | null
type Handler = (event: unknown, text: unknown, asked: unknown) => Promise<Reply>

/** The "cleanup:try" handler from main.ts, with a `tryCleanup` that asks a real Cleaner, as the one beside it does. */
function mainHandler(cleaner: Cleaner, cancelled = false): Handler {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const handler = main.match(/ipcMain\.handle\('cleanup:try', (async [\s\S]*?\n {2}\})\)\n/)
  assert.ok(handler, 'the cleanup:try handler is where it was')
  const code = ts.transpileModule(`globalThis.handler = ${handler[1]}`, { compilerOptions: { target: ts.ScriptTarget.ES2023 } }).outputText
  const context = vm.createContext({
    globalThis: {} as { handler?: Handler },
    isCleanupProvider,
    tryCleanup: async (text: string, provider: never) => ({ run: await cleaner.run(text, { provider, trying: true }), cancelled }),
  })
  vm.runInContext(code, context)
  return (context.globalThis as { handler: Handler }).handler
}

function cleanerWith(fetcher: typeof fetch, settings: Partial<CleanupSettings> = {}, keys: Record<string, string> = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-try-reply-'))
  scratch.push(dir)
  return new Cleaner({
    dir,
    settings: provider => ({ provider: provider ?? 'custom', model: 'stand-in', address: 'http://127.0.0.1:9/v1', level: 'light', customPrompt: '', vocabulary: [], ...settings }),
    readAccount: account => keys[account] ?? null,
    fetcher,
    log() {}, changed() {},
  })
}

/** A server on this computer that lists `models` and answers every chat with `content`. */
const server = (models: string[], content = cleaned) => (async (url: string) => String(url).endsWith('/models')
  ? new Response(JSON.stringify({ data: models.map(id => ({ id })) }), { status: 200 })
  : new Response(JSON.stringify({ choices: [{ message: { content } }] }), { status: 200 })) as unknown as typeof fetch

test('the reply of a Try names the provider and the model that answered, next to what it had', async () => {
  const handle = mainHandler(cleanerWith(server([])))
  const reply = await handle(undefined, said, 'custom')
  // Spread: the handler ran in another realm, whose objects deepStrictEqual does not take for plain ones.
  assert.deepEqual({ ...reply }, { outcome: 'ok', answer: cleaned, rejected: false, seconds: reply?.seconds, dollars: undefined, cancelled: false, provider: 'custom', model: 'stand-in' })
  assert.equal(typeof reply?.seconds, 'number')
})

test('Ollama with no model chosen: the reply names the first installed one, which only the main process knows', async () => {
  const handle = mainHandler(cleanerWith(server(['nomic-embed-text', 'qwen3.8:8b', 'llama4:8b']), { model: '', address: '' }))
  const reply = await handle(undefined, said, 'ollama')
  assert.equal(reply?.provider, 'ollama')
  assert.equal(reply?.model, 'qwen3.8:8b')
  assert.equal(reply?.outcome, 'ok')
})

test('a Try that failed or was thrown out still says whose it was', async () => {
  // No key: nothing was asked of Google, and the reply still names it and the model it would have used.
  const noKey = await mainHandler(cleanerWith(server([]), { model: 'gemini-synthetic', address: '' }))(undefined, said, 'google')
  assert.equal(noKey?.outcome, 'No key')
  assert.deepEqual([noKey?.provider, noKey?.model], ['google', 'gemini-synthetic'])
  // The guard threw the answer out: its text goes along for the page to show, with the provider and model.
  const rejected = await mainHandler(cleanerWith(server([], 'Die Hauptstadt von Australien ist Canberra.')))(undefined, said, 'custom')
  assert.equal(rejected?.rejected, true)
  assert.deepEqual([rejected?.provider, rejected?.model], ['custom', 'stand-in'])
  // Cancelled by the page: the flag still goes along.
  const cancelled = await mainHandler(cleanerWith(server([])), true)(undefined, said, 'custom')
  assert.deepEqual([cancelled?.cancelled, cancelled?.provider, cancelled?.model], [true, 'custom', 'stand-in'])
})

test('what is not a text and a provider is still answered with null', async () => {
  const handle = mainHandler(cleanerWith(server([])))
  assert.equal(await handle(undefined, 5, 'custom'), null)
  assert.equal(await handle(undefined, said, 'nobody'), null)
  assert.equal(await handle(undefined, said, undefined), null)
})

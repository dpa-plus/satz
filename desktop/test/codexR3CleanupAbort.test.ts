import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, test } from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
import { Session } from '../src/core/session'
import { Cleaner } from '../src/main/cleanup'
import { deferred, disposeAll, FakeSource, phase, settle, setup } from './sessionHarness'

/**
 * Codex's third audit of 14 October 2026, F07 carried over to cleanup: a
 * dictation thrown away while it was being cleaned up dropped the late
 * answer, but the request ran on (and cost on), and its late answer still
 * went into the measured speeds. The Session now hands cleanup a signal and
 * aborts it when the dictation is thrown away or the Session is reset;
 * main.ts passes it to the Cleaner. Each test fails on the code before the fix.
 */
const scratch: string[] = []
afterEach(() => { disposeAll(); for (const dir of scratch.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })

const said = 'um please send the whole synthetic sentence to the meeting tomorrow'
const tidy = 'Please send the whole synthetic sentence to the meeting tomorrow.'

/** A dictation said and finished, now with the cleanup model. */
async function cleaning(cleanup: (text: string, signal: AbortSignal) => Promise<{ text: string; outcome: string }>) {
  const rig = setup([said], { cleanup: cleanup as never })
  rig.session.press(); await settle(); rig.sources[0].say()
  rig.session.press(); await settle()
  assert.deepEqual(rig.session.phase, { kind: 'finishing', cleaning: true })
  return rig
}

test('F07 cleanup: throwing the dictation away aborts the cleanup it waits for, and the late answer is dropped', async () => {
  const signals: AbortSignal[] = []
  const answer = deferred<{ text: string; outcome: string }>()
  const { session, delivered } = await cleaning((_text, signal) => { signals.push(signal); return answer.promise })
  assert.equal(signals.length, 1)
  assert.equal(signals[0]?.aborted, false)
  session.discard()
  assert.equal(signals[0].aborted, true, 'the request stops')
  answer.resolve({ text: tidy, outcome: 'ok' }); await settle()
  assert.deepEqual(delivered, [])
  assert.equal(phase(session), 'discarded')
  assert.equal(session.discarded?.preview, said, 'the words stay restorable')
})

test('F07 cleanup: a Session reset (quitting) aborts the cleanup too', async () => {
  const signals: AbortSignal[] = []
  const { session } = await cleaning((_text, signal) => { signals.push(signal); return new Promise(() => {}) })
  session.dispose()
  assert.equal(signals[0]?.aborted, true)
})

test('F07 cleanup: a cleanup that answered is not aborted afterwards, and an abort is not logged as a failure', async () => {
  const signals: AbortSignal[] = []
  const { session, sources, delivered } = setup([said], { cleanup: (async (_text: string, signal: AbortSignal) => { signals.push(signal); return { text: tidy, outcome: 'ok' } }) as never })
  session.press(); await settle(); sources[0].say()
  session.press(); await settle()
  assert.deepEqual(delivered, [tidy])
  assert.equal(signals[0]?.aborted, false, 'nothing to call off')

  // An abort that throws: thrown away on purpose, no "cleanup failed" in the log.
  const logs: string[] = []
  const source = new FakeSource(said)
  const thrown = new Session({
    makeSource: () => source, transcribe: async () => said, replacements: () => [], missing: () => null, endpointMissing: () => false,
    triggerMode: () => 'tap', deliver: async () => ({ pasted: true }), hasSpeech: samples => samples.length > 0, log: line => logs.push(line),
    cleansText: () => true,
    cleanup: (_text, signal) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))),
  })
  try {
    thrown.press(); await settle(); source.say(); thrown.press(); await settle()
    thrown.discard(); await settle()
    assert.ok(!logs.some(line => line.startsWith('cleanup failed')), logs.join('\n'))
  } finally { thrown.dispose(); session.dispose() }
})

/** main.ts's cleanup line, run as written there (unit tests do not reach main.ts). */
function mainCleanup(cleaner: unknown) {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const line = main.match(/^ {4}cleanup: (async .*\}),$/m)
  assert.ok(line, 'the cleanup line is where it was')
  const code = ts.transpileModule(`globalThis.cleanup = ${line[1]}`, { compilerOptions: { target: ts.ScriptTarget.ES2023 } }).outputText
  const context = vm.createContext({ cleaner, globalThis: {} as { cleanup?: unknown } })
  vm.runInContext(code, context)
  return (context.globalThis as { cleanup: (text: string, signal: AbortSignal) => Promise<{ text: string; outcome: string }> }).cleanup
}

test('F07 cleanup: main.ts hands the signal to the Cleaner, so a thrown-away request stops and its late answer is no measurement', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-r3-cleanup-'))
  scratch.push(dir)
  const reply = deferred<Response>()
  let sentWith: AbortSignal | undefined
  const cleaner = new Cleaner({
    dir,
    settings: () => ({ provider: 'custom', address: 'http://127.0.0.1:1/v1', model: 'synthetic', level: 'custom', customPrompt: 'Keep the supplied content.', vocabulary: [] }),
    readAccount: () => null,
    // A stand-in server that answers late, whatever the signal says.
    fetcher: (async (_url: string, init: { signal: AbortSignal }) => { sentWith = init.signal; return reply.promise }) as never,
    log() {}, changed() {},
  })
  const { session, delivered } = await cleaning(mainCleanup(cleaner))
  assert.ok(sentWith, 'the request went out')
  assert.equal(sentWith.aborted, false)
  session.discard()
  assert.equal(sentWith.aborted, true, 'the request is called off')
  reply.resolve(new Response(JSON.stringify({ choices: [{ message: { content: tidy } }] }), { status: 200 })); await settle()
  assert.deepEqual(delivered, [])
  assert.equal(fs.existsSync(path.join(dir, 'cleanup-speeds.json')), false, 'no speed measured from a thrown-away run')
})

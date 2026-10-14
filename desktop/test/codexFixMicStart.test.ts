import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import path from 'node:path'
import { afterEach, mock, test } from 'node:test'
import vm from 'node:vm'
import ts from 'typescript'
import { MicHub, MicRecorder } from '../src/main/recorder'
import { Microphone } from '../src/renderer/microphone'
import { flush } from './sessionHarness'

/**
 * Codex's bug hunt of 14 October 2026, F04: a microphone request that timed
 * out before the card's page was ready still started the microphone once the
 * page was. Unit tests do not reach main.ts, so its recording block is run
 * here as it is written there, with the card, IPC and capture as stand-ins
 * around the real MicHub, MicRecorder and Microphone. Fails on the code
 * before the fix.
 */
afterEach(() => mock.timers.reset())

function recordingBlock() {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const from = main.indexOf('  let recordingRequest = 0'), to = main.indexOf('\n  const delivered: string[] = []')
  assert.ok(from > 0 && to > from, 'the recording block is where it was')
  return main.slice(from, to)
}

function harness() {
  let tracks = 0, ready = false
  const commands: string[] = []
  const microphone = new Microphone({
    async getUserMedia() { tracks++; return { getTracks: () => [{ stop() { tracks-- } }] } as unknown as MediaStream },
    async openTap() { return { connect() {}, close() {} } },
  } as never, () => {})
  const ipcMain = new EventEmitter()
  const card = {
    send(channel: string, value: unknown) {
      commands.push(`${channel}:${value}`)
      if (!ready) return
      if (channel === 'rec:stop') microphone.stop()
      if (channel === 'rec:start') void microphone.start().then(started => { if (started) ipcMain.emit('rec:started', {}, value) })
    },
  }
  const context = vm.createContext({ ipcMain, card, MicHub, setTimeout, clearTimeout, de: (_de: string, en: string) => en, globalThis: {} as { hub?: MicHub } })
  const code = ts.transpileModule(`${recordingBlock()}\nglobalThis.hub = hub`, { compilerOptions: { target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.CommonJS } }).outputText
  vm.runInContext(code, context)
  const recorder = new MicRecorder((context.globalThis as { hub: MicHub }).hub)
  return {
    recorder, commands, microphone,
    get tracks() { return tracks },
    cardReady() { ready = true; ipcMain.emit('card:ready') },
  }
}

test('F04: a request that timed out before the card was ready never starts the microphone afterwards', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const h = harness()
  const start = assert.rejects(h.recorder.start(), /microphone does not answer/)
  mock.timers.tick(15_000); await flush(); await start
  h.cardReady(); await flush()
  assert.deepEqual(h.commands, ['rec:stop:null'], 'stopped, and not started again')
  assert.equal(h.tracks, 0, 'no microphone open with nobody recording')
})

test('F04: a request still waiting when the card becomes ready starts as before', async () => {
  mock.timers.enable({ apis: ['setTimeout'] })
  const h = harness()
  const start = h.recorder.start()
  mock.timers.tick(5_000)
  h.cardReady(); await flush()
  await start
  assert.deepEqual(h.commands, ['rec:start:1'])
  assert.equal(h.tracks, 1)
  h.recorder.cancel(); await flush()
  assert.equal(h.tracks, 0)
})

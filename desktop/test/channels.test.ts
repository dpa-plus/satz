import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { invoke, receive, send } from '../src/main/channels'

test('every channel the pages use is allowed by the preload', () => {
  const dir = path.join(__dirname, '..', 'src', 'renderer')
  const missing: string[] = []
  for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.ts'))) {
    const source = fs.readFileSync(path.join(dir, file), 'utf8')
    for (const [, kind, channel] of source.matchAll(/satz\.(invoke|on|send)\(\s*'([^']+)'/g)) {
      const allowed = kind === 'invoke' ? invoke : kind === 'on' ? receive : send
      if (!allowed.has(channel)) missing.push(`${file}: ${kind} ${channel}`)
    }
  }
  assert.deepEqual(missing, [])
})

test('every channel the preload lets through is answered by main.ts, and nothing else is', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'main.ts'), 'utf8')
  const handled = new Set([...main.matchAll(/ipcMain\.handle\(\s*'([^']+)'/g)].map(([, channel]) => channel))
  assert.deepEqual([...invoke].filter(channel => !handled.has(channel)), [])
  assert.deepEqual([...handled].filter(channel => !invoke.has(channel)), [])
})

/**
 * These read the main process's source for channel names. They prove the
 * names agree on both sides, not that a handler runs: unit tests do not reach
 * main.ts, so a change there is also checked by starting the packaged app
 * once (AGENTS.md).
 */
const mainSources = ['main.ts', 'card.ts'].map(file => fs.readFileSync(path.join(__dirname, '..', 'src', 'main', file), 'utf8')).join('\n')

test('every channel the pages may send is listened for by the main process, and nothing else is', () => {
  const listened = new Set([...mainSources.matchAll(/ipcMain\.(?:on|once)\(\s*'([^']+)'/g)].map(([, channel]) => channel))
  assert.deepEqual([...send].filter(channel => !listened.has(channel)), [])
  assert.deepEqual([...listened].filter(channel => !send.has(channel)), [])
})

test('every channel the pages may receive is sent by the main process, and nothing else is', () => {
  const sent = new Set([...mainSources.matchAll(/(?:card\.send|tellWindow|webContents\.send)\(\s*'([^']+)'/g)].map(([, channel]) => channel))
  assert.deepEqual([...receive].filter(channel => !sent.has(channel)), [])
  assert.deepEqual([...sent].filter(channel => !receive.has(channel)), [])
})

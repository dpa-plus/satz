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

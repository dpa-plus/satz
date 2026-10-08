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

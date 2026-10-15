import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { guard, type CleanupLevel, type PresetLevel } from '../src/core/cleanup'
import { Cleaner } from '../src/main/cleanup'

interface Case { note: string; input: string; output: string; acceptLevels: PresetLevel[]; vocabulary: string[] }
const cases = JSON.parse(fs.readFileSync(new URL('../../Tests/Fixtures/cleanup-number-context-cases.json', import.meta.url), 'utf8')) as Case[]
const levels: PresetLevel[] = ['punctuation', 'light', 'smooth', 'polished']
for (const item of cases) test(`number context: ${item.note}`, () => {
  for (const level of levels) assert.equal(guard(item.input, item.output, level, item.vocabulary), item.acceptLevels.includes(level), `${level}: ${item.note}`)
})

function cleaner(dir: string, item: Case, level: CleanupLevel) {
  return new Cleaner({ dir, settings: () => ({ provider: 'custom', model: 'stand-in', address: 'http://127.0.0.1:9/v1', level, customPrompt: 'Rewrite', vocabulary: item.vocabulary }),
    readAccount: () => null, fetcher: (async () => new Response(JSON.stringify({ choices: [{ message: { content: item.output }, finish_reason: 'stop' }] }))) as typeof fetch,
    log: () => {}, changed: () => {} })
}
test('the desktop Cleaner retains the full original when numeric context changes', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-number-context-'))
  try {
    for (const item of cases.filter(item => item.acceptLevels.length === 0)) for (const level of levels) {
      const result = await cleaner(dir, item, level).run(item.input)
      assert.equal(result.text, item.input, `${level}: ${item.note}`)
      assert.equal(result.code, 'rejected', `${level}: ${item.note}`)
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})
test('the desktop Cleaner accepts safe formatting and intentional custom rewriting', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-number-positive-'))
  try {
    for (const item of cases) for (const level of [...item.acceptLevels, 'custom'] as CleanupLevel[]) {
      const result = await cleaner(dir, item, level).run(item.input)
      assert.equal(result.text, item.output, `${level}: ${item.note}`)
      assert.equal(result.code, 'ok', `${level}: ${item.note}`)
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }) }
})

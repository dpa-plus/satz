import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { cleanAnswer } from '../src/core/cleanup'

// The same 50 answers the Mac cleans in CleanupAnswerTests: one table, so the
// two platforms cannot drift apart on what reaches the text field.
const { cases } = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'Tests', 'Fixtures', 'cleanup-answer-cases.json'), 'utf8')) as { cases: { answer: string; original: string; expected: string }[] }

test('every shared answer is cleaned as the Mac cleans it', () => {
  assert.equal(cases.length, 50)
  for (const { answer, original, expected } of cases) assert.equal(cleanAnswer(answer, original), expected, JSON.stringify(answer))
})

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DoubleTap } from '../src/core/trigger'

function make() {
  let now = 0
  const events: string[] = []
  const tap = new DoubleTap(() => events.push('press'), () => events.push('release'), () => now)
  return { tap, events, at: (t: number) => { now = t } }
}

test('two quick taps press, letting go releases', () => {
  const { tap, events, at } = make()
  at(0); tap.keyDown(true); at(80); tap.keyUp(true)
  at(200); tap.keyDown(true)
  assert.deepEqual(events, ['press'])
  at(260); tap.keyUp(true)
  assert.deepEqual(events, ['press', 'release'])
})

test('key repeat while held is not a second tap', () => {
  const { tap, events, at } = make()
  at(0); tap.keyDown(true); at(30); tap.keyDown(true); at(60); tap.keyDown(true); at(90); tap.keyUp(true)
  assert.deepEqual(events, [])
})

test('another key between the taps breaks the sequence', () => {
  const { tap, events, at } = make()
  at(0); tap.keyDown(true); at(50); tap.keyDown(false); at(80); tap.keyUp(true)
  at(150); tap.keyDown(true); at(200); tap.keyUp(true)
  assert.deepEqual(events, [])
})

test('slow taps or a long gap do nothing', () => {
  const { tap, events, at } = make()
  at(0); tap.keyDown(true); at(500); tap.keyUp(true)
  at(600); tap.keyDown(true); at(650); tap.keyUp(true)
  at(1200); tap.keyDown(true); at(1250); tap.keyUp(true)
  assert.deepEqual(events, [])
})

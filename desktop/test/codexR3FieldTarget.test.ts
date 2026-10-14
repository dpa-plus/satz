import assert from 'node:assert/strict'
import type { ChildProcessWithoutNullStreams } from 'node:child_process'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import path from 'node:path'
import { PassThrough } from 'node:stream'
import { afterEach, test } from 'node:test'
import { makeDelivery } from '../src/main/delivery'
import * as foreground from '../src/main/foreground'
import { WindowsForeground } from '../src/main/foreground'
import { PowerShellHelper } from '../src/main/powershell'
import { decode, deferred, disposeAll, phase, settle, setup } from './sessionHarness'

/**
 * Codex's third audit, VM-02: on Windows satz brought back the window a
 * dictation started in, but not the text field. Focus moved from field A to
 * B while the text was on its way, and Ctrl+V went into B; A removed by the
 * page and its Copy button focused, Ctrl+V went to the button, and the history
 * said "pasted". The window helper now notes the field through UI Automation
 * and puts the keyboard back into it, or leaves the text on the clipboard.
 *
 * PowerShell is not there on the Mac: the helper is a simulated Edge window
 * that answers the helper's commands (current, focus, capture, field) the way
 * the C# in foreground.ts does. Each test fails on the code before the fix.
 */
afterEach(() => disposeAll())

interface Element { name: string; id: string; editable: boolean; present: boolean }

/** One Edge window with two fields and a button, and where the keyboard is in it. */
class EdgeWindow {
  hwnd = 1001
  elements: Element[] = [
    { name: 'A', id: '42.1001.11', editable: true, present: true },
    { name: 'B', id: '42.1001.12', editable: true, present: true },
    { name: 'Copy', id: '42.1001.13', editable: false, present: true },
  ]
  focus = 'A'
  /** Fields that refuse SetFocus, as a disabled or hidden one does. */
  refusing = new Set<string>()
  noted = new Map<string, Element>()
  commands: string[] = []
  /** What each element got: a paste event, and text where it takes text. */
  pasteEvents: string[] = []
  input: Record<string, string> = { A: '', B: '' }
  element(name: string) { return this.elements.find(element => element.name === name)! }
  focused() { return this.element(this.focus) }
  answer(line: string): string {
    this.commands.push(line)
    const [command, argument] = line.split(' ')
    if (command === 'current') return String(this.hwnd)
    if (command === 'focus') return Number(argument) === this.hwnd ? 'ok' : 'gone'
    if (command === 'capture') {
      const element = this.focused()
      if (Number(argument) !== this.hwnd || !element.editable) return 'none'
      this.noted.set(element.id, element)
      return element.id
    }
    if (command === 'field') {
      if (this.focused().id === argument) return this.focused().editable ? 'ok' : 'noedit'
      const field = this.noted.get(argument)
      if (!field) return 'lost'
      if (!field.present) return 'gone'
      if (this.refusing.has(field.name)) return 'refused'
      this.focus = field.name
      return field.editable ? 'ok' : 'noedit'
    }
    return 'error unknown'
  }
  ctrlV(clipboard: string) {
    const element = this.focused()
    this.pasteEvents.push(element.name)
    if (element.editable && element.present) this.input[element.name] += clipboard
  }
}

/** A PowerShell child that answers each line with `answer`. */
function helperAnswering(answer: (line: string) => string, log: (message: string) => void = () => {}) {
  return new PowerShellHelper('script', 'window helper', log, () => {
    const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough(), stdin: new PassThrough(), kill() { return true } })
    child.stdout.write('ready\n')
    child.stdin.on('data', chunk => { for (const line of String(chunk).split('\r\n').filter(Boolean)) child.stdout.write(answer(line) + '\n') })
    return child as unknown as ChildProcessWithoutNullStreams
  })
}

/**
 * A dictation into the simulated window, wired as main.ts does it: the target
 * noted when it begins, `whileWriting` done once it is finished and before
 * its text comes, then the delivery with paste.ts's order (clipboard, Ctrl+V).
 */
async function dictate(text: string, whileWriting: (edge: EdgeWindow) => void, startIn = 'A') {
  const edge = new EdgeWindow()
  edge.focus = startIn
  const log: string[] = []
  const windows = new WindowsForeground(message => log.push(message), helperAnswering(line => edge.answer(line), message => log.push(message)))
  let clipboard = 'what the user had copied'
  const history: [string, boolean][] = []
  const deliverInto = makeDelivery({
    records: false,
    windows,
    paste: async (value, keyTap) => { clipboard = value; keyTap(); return { pasted: true } },
    keyTap: () => edge.ctrlV(clipboard),
    writeClipboard: value => { clipboard = value },
    keepsOnClipboard: () => false,
    addHistory: (value, pasted) => { history.push([value, pasted]) },
    delivered: () => {},
    log: message => log.push(message),
    sleep: async () => {},
  })
  const transcription = deferred()
  let target: Promise<string | null> = Promise.resolve(null)
  const outcomes: { pasted: boolean; reason?: string }[] = []
  const { session, sources } = setup([text], {
    transcribe: async samples => { await transcription.promise; return decode(samples) },
    deliver: async value => { const outcome = await deliverInto(value, target); outcomes.push(outcome); return outcome },
  })
  session.onBegin = () => { target = windows.current() }
  session.press(); await settle()
  await target
  sources[0].say()
  session.press(); await settle()
  whileWriting(edge)
  transcription.resolve()
  for (let i = 0; i < 40 && history.length === 0; i++) await settle()
  await settle()
  return { edge, session, history, clipboard, outcome: outcomes[0], log, target: await target }
}

test('VM-02: focus moved from field A to B while the text was on its way: the keyboard goes back to A, and B gets nothing', async () => {
  const { edge, history, outcome } = await dictate('AUDIT WINDOWS FIELD 954.', edge => { edge.focus = 'B' })
  assert.deepEqual(edge.pasteEvents, ['A'], 'Ctrl+V went to A, not to B')
  assert.equal(edge.input.A, 'AUDIT WINDOWS FIELD 954.')
  assert.equal(edge.input.B, '')
  assert.equal(outcome.pasted, true)
  assert.deepEqual(history, [['AUDIT WINDOWS FIELD 954.', true]])
})

test('VM-02: field A removed and the Copy button focused: no Ctrl+V, the text stays on the clipboard, and nothing says it was pasted', async () => {
  const { edge, session, history, clipboard, outcome, log } = await dictate('AUDIT REMOVED FIELD 956.', edge => {
    edge.element('A').present = false
    edge.focus = 'Copy'
  })
  assert.deepEqual(edge.pasteEvents, [], 'the button got no paste')
  assert.equal(clipboard, 'AUDIT REMOVED FIELD 956.', 'the text waits on the clipboard')
  assert.deepEqual(history, [['AUDIT REMOVED FIELD 956.', false]])
  assert.equal(outcome.pasted, false)
  assert.equal(outcome.reason, 'On the clipboard, the text field could not be selected again.')
  assert.equal(phase(session), 'clipboard', 'the card says where the text is')
  assert.ok(log.includes('window helper: text field gone'), log.join('\n'))
  assert.ok(!log.some(line => line.includes('AUDIT')), 'the dictated text is never logged')
})

test('VM-02: a field that will not take the keyboard back, and one that takes no text now, get no Ctrl+V either', async () => {
  const refused = await dictate('refused field', edge => { edge.refusing.add('A'); edge.focus = 'B' })
  assert.deepEqual(refused.edge.pasteEvents, [])
  assert.deepEqual(refused.history, [['refused field', false]])
  const readOnly = await dictate('read-only field', edge => { edge.element('A').editable = false })
  assert.deepEqual(readOnly.edge.pasteEvents, [])
  assert.deepEqual(readOnly.history, [['read-only field', false]])
})

test('VM-02: every answer of the helper that says the field is not back keeps the text on the clipboard; a failing helper holds nothing back', async () => {
  const restoreField = (answer: string) => new WindowsForeground(() => {}, helperAnswering(line => (line.startsWith('field') ? answer : 'ok'))).restoreField('1001|42.1001.11')
  for (const answer of ['gone', 'refused', 'noedit', 'lost', 'busy']) assert.equal(await restoreField(answer), false, answer)
  assert.equal(await restoreField('ok'), true)
  // The UI Automation part did not compile, or the helper broke: as for the
  // window, a helper that cannot tell is no reason to hold the text back.
  assert.equal(await restoreField('error no text fields'), true)
  assert.equal(await restoreField('error helper stopped'), true)
})

test('VM-02: no text field when the dictation began (a button, a terminal, an app that does not say): the window alone is checked, as before', async () => {
  // Nothing says where the text was meant to go, so it goes where the keyboard is, as it did.
  const { edge, history, target } = await dictate('started on a button', edge => { edge.focus = 'B' }, 'Copy')
  assert.equal(target, '1001', 'the window only')
  assert.ok(!edge.commands.some(command => command.startsWith('field')), 'the helper is not asked about a field')
  assert.deepEqual(edge.pasteEvents, ['B'])
  assert.deepEqual(history, [['started on a button', true]])
})

test('VM-02: the target stays one string for main.ts; the window step asks for the window alone', async () => {
  const edge = new EdgeWindow()
  const windows = new WindowsForeground(() => {}, helperAnswering(line => edge.answer(line)))
  const target = await windows.current()
  assert.equal(target, '1001|42.1001.11')
  assert.equal(await windows.restore(target!), true)
  assert.ok(edge.commands.includes('focus 1001'), edge.commands.join(', '))
  // An answer that is not a runtime id is no field (an older helper said "ok" to anything).
  const odd = new WindowsForeground(() => {}, helperAnswering(line => (line === 'current' ? '1001' : 'ok 42 with spaces')))
  assert.equal(await odd.current(), '1001')
})

test('VM-02: the C# goes through a double-quoted here-string and Windows PowerShell\'s C# 5 compiler, and may fail without taking the window helper along', () => {
  const script: string | undefined = (foreground as Record<string, unknown>).WINDOW_HELPER_SCRIPT as string | undefined
  assert.equal(typeof script, 'string', 'the script is exported for this check')
  const source = script!
  const fieldStart = source.indexOf('public static class SatzField')
  assert.ok(fieldStart > 0)
  const fieldCode = source.slice(fieldStart, source.indexOf('\n"@', fieldStart))
  // PowerShell expands $name and $( ) inside @" "@: a $ would change the C#.
  assert.ok(!fieldCode.includes('$'), 'no $ in the C#')
  // Windows PowerShell 5.1 compiles with the .NET Framework's csc: C# 5.
  const code = fieldCode.replace(/\/\/[^\n]*/g, '')
  for (const newer of ['?.', '$"', 'nameof(', 'out var ', ' is not ', '??=', ' => ']) assert.ok(!code.includes(newer), newer)
  // Here-strings end only at the start of a line.
  assert.equal(source.match(/^"@$/gm)?.length, 2, 'both here-strings are closed at the start of a line')
  // The UI Automation part is in a try that lets "ready" come either way.
  const tryAt = source.indexOf('try {\n  Add-Type -AssemblyName UIAutomationClient')
  const readyAt = source.indexOf("[Console]::Out.WriteLine('ready')")
  assert.ok(tryAt > 0 && tryAt < readyAt, 'the field part may fail before ready')
  assert.ok(source.indexOf('} catch {', tryAt) < readyAt)
  // Without it, "capture" says "none" and "field" says the helper cannot tell.
  assert.match(source, /'capture'\) \{\n\s+if \(\$fields\) \{[^\n]+\} else \{ \[Console\]::Out\.WriteLine\('none'\) \}/)
  assert.match(source, /'field'\) \{\n\s+if \(\$fields\) \{[^\n]+\} else \{ \[Console\]::Out\.WriteLine\('error no text fields'\) \}/)
})

test('VM-02: the Mac says the same when the field will not come back', () => {
  const paster = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'SatzMac', 'Input', 'Paster.swift'), 'utf8')
  const delivery = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'delivery.ts'), 'utf8')
  for (const words of ['Auf der Zwischenablage, das Textfeld ließ sich nicht mehr auswählen.', 'On the clipboard, the text field could not be selected again.']) {
    assert.ok(paster.includes(words), `Mac: ${words}`)
    assert.ok(delivery.includes(words), `Windows: ${words}`)
  }
})

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, mock, test } from 'node:test'

/*
 * build/after-pack.cjs, which runs when a package is built: the keyboard hook
 * (uiohook-napi) carries a prebuilt library per system and chip, and its
 * linux-arm64 folder holds the x86-64 one. The Ubuntu ARM package then
 * shipped a library that cannot load. chipOf reads what a library was built
 * for from its file header (ELF on Linux, PE on Windows), dropWrongChip drops
 * the folder of one that does not match and says so while building. Neither
 * was tested (the verifiers' problem 6); the headers here are built by hand.
 */

interface AfterPack {
  chipOf(file: string): { format: 'elf' | 'pe'; machine: number } | null
  dropWrongChip(context: Context, unit: string, label: string, consequence: string): boolean
  keepOnlyThisKeyboardHook(context: Context): void
  keepOnlyThisOnnxRuntime(context: Context): void
}
interface Context { appOutDir: string; electronPlatformName: string; arch: number }
const afterPack = require('../build/after-pack.cjs') as AfterPack
const { Arch } = require('electron-builder') as { Arch: Record<string, number> }

const scratches: string[] = []
afterEach(() => { mock.restoreAll(); for (const dir of scratches.splice(0)) fs.rmSync(dir, { recursive: true, force: true }) })
const scratch = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satz-afterpack-')); scratches.push(dir); return dir }

// MARK: - Headers

const X86_64 = 0x3e, AARCH64 = 0xb7, I386 = 0x03, ARM = 0x28
const PE_X64 = 0x8664, PE_ARM64 = 0xaa64, PE_X86 = 0x014c

/** The first 64 bytes of an ELF file: "\x7fELF", the class, how the numbers are written (byte 5) and e_machine at 18. */
function elf(machine: number, bigEndian = false) {
  const header = Buffer.alloc(64)
  header.write('\x7fELF', 0, 'latin1')
  header[4] = 2
  header[5] = bigEndian ? 2 : 1
  header[6] = 1
  if (bigEndian) header.writeUInt16BE(machine, 18)
  else header.writeUInt16LE(machine, 18)
  return header
}

/** "MZ", the offset of "PE\0\0" at 0x3c, and the Machine field after the signature. */
function pe(machine: number, at = 0x80) {
  const file = Buffer.alloc(at + 24)
  file.write('MZ', 0, 'latin1')
  file.writeUInt32LE(at, 0x3c)
  file.write('PE\0\0', at, 'latin1')
  file.writeUInt16LE(machine, at + 4)
  return file
}

function write(dir: string, name: string, content: Buffer | string) {
  fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true })
  fs.writeFileSync(path.join(dir, name), content)
  return path.join(dir, name)
}

test('chipOf reads the machine of an ELF and of a PE file, whichever way the numbers are written', () => {
  const dir = scratch()
  assert.deepEqual(afterPack.chipOf(write(dir, 'a.so', elf(X86_64))), { format: 'elf', machine: X86_64 })
  assert.deepEqual(afterPack.chipOf(write(dir, 'b.so', elf(AARCH64))), { format: 'elf', machine: AARCH64 })
  assert.deepEqual(afterPack.chipOf(write(dir, 'c.so', elf(ARM))), { format: 'elf', machine: ARM })
  assert.deepEqual(afterPack.chipOf(write(dir, 'd.so', elf(I386))), { format: 'elf', machine: I386 })
  // Big endian: the same machine, the two bytes the other way round.
  assert.deepEqual(afterPack.chipOf(write(dir, 'e.so', elf(AARCH64, true))), { format: 'elf', machine: AARCH64 })
  assert.deepEqual(afterPack.chipOf(write(dir, 'a.dll', pe(PE_X64))), { format: 'pe', machine: PE_X64 })
  assert.deepEqual(afterPack.chipOf(write(dir, 'b.dll', pe(PE_ARM64))), { format: 'pe', machine: PE_ARM64 })
  assert.deepEqual(afterPack.chipOf(write(dir, 'c.dll', pe(PE_X86, 0x40))), { format: 'pe', machine: PE_X86 }, 'the PE header where the offset says')
})

test('chipOf says null for what it cannot read: other formats, cut-off files, a PE header that is not there', () => {
  const dir = scratch()
  assert.equal(afterPack.chipOf(write(dir, 'empty', '')), null)
  assert.equal(afterPack.chipOf(write(dir, 'text', 'just some text, nothing like a library at all')), null)
  assert.equal(afterPack.chipOf(write(dir, 'short.so', elf(X86_64).subarray(0, 10))), null, 'cut off before e_machine')
  assert.equal(afterPack.chipOf(write(dir, 'macho', Buffer.from([0xcf, 0xfa, 0xed, 0xfe, ...new Array(60).fill(0)]))), null, 'Mach-O is not checked')
  const beyond = pe(PE_X64); beyond.writeUInt32LE(0x10_000, 0x3c)
  assert.equal(afterPack.chipOf(write(dir, 'beyond.dll', beyond)), null, 'the offset points past the end')
  const wrong = pe(PE_X64); wrong.write('XX', 0x80, 'latin1')
  assert.equal(afterPack.chipOf(write(dir, 'wrong.dll', wrong)), null, 'no PE signature there')
})

// MARK: - dropWrongChip

const context = (appOutDir: string, electronPlatformName: string, arch: string): Context => ({ appOutDir, electronPlatformName, arch: Arch[arch] })

/** What a build logs: dropWrongChip prints with console.log. */
function logged() { return mock.method(console, 'log', () => {}) }
const lines = (spy: ReturnType<typeof logged>) => spy.mock.calls.map(call => call.arguments.join(' '))

test('a library built for another chip drops its folder and says so; the right one stays', () => {
  const out = scratch()
  const spy = logged()
  // The documented case: uiohook-napi\'s linux-arm64 folder holds the x86-64 library.
  const unit = path.join(out, 'prebuilds', 'linux-arm64')
  write(unit, 'uiohook_napi.node', elf(X86_64))
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'arm64'), unit, 'uiohook-napi', 'satz starts without the keyboard hook'), true)
  assert.equal(fs.existsSync(unit), false, 'the folder is gone')
  const [line] = lines(spy)
  assert.equal(lines(spy).length, 1)
  assert.match(line, /uiohook-napi/)
  assert.match(line, /prebuilds[\\/]linux-arm64[\\/]uiohook_napi\.node/)
  assert.match(line, /built for x86-64 \(ELF\)/)
  assert.match(line, /this package is linux-arm64/)
  assert.match(line, /dropped, satz starts without the keyboard hook/)
  // The right one for the package stays, and nothing is logged.
  const right = path.join(out, 'prebuilds', 'linux-x64')
  write(right, 'uiohook_napi.node', elf(X86_64))
  spy.mock.resetCalls()
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'x64'), right, 'uiohook-napi', 'x'), false)
  assert.equal(fs.existsSync(right), true)
  assert.deepEqual(lines(spy), [])
})

test('Windows packages are judged by the PE machine: x64 stays in x64, arm64 stays in arm64, and the swap is dropped', () => {
  const out = scratch()
  const spy = logged()
  const cases: [string, number, boolean, string][] = [
    ['x64', PE_X64, false, ''], ['arm64', PE_ARM64, false, ''], ['x64', PE_ARM64, true, 'arm64 (PE)'], ['arm64', PE_X64, true, 'x86-64 (PE)'], ['ia32', PE_X86, false, ''],
  ]
  for (const [arch, machine, dropped, wording] of cases) {
    const unit = path.join(out, `win32-${arch}-${machine}`)
    write(unit, 'lib/binding.node', pe(machine))
    spy.mock.resetCalls()
    assert.equal(afterPack.dropWrongChip(context(out, 'win32', arch), unit, 'onnxruntime-node', 'local models cannot run'), dropped, `${arch} ${machine.toString(16)}`)
    assert.equal(fs.existsSync(unit), !dropped)
    if (dropped) assert.match(lines(spy)[0], new RegExp(`built for ${wording.replace(/[()]/g, '\\$&')}.*this package is win32-${arch}`))
  }
})

test('a Linux package does not take a Windows library for right, and an ELF in a Windows package is wrong too', () => {
  const out = scratch()
  logged()
  const linux = path.join(out, 'one'); write(linux, 'a.node', pe(PE_X64))
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'x64'), linux, 'x', 'x'), true)
  const windows = path.join(out, 'two'); write(windows, 'a.node', elf(X86_64))
  assert.equal(afterPack.dropWrongChip(context(out, 'win32', 'x64'), windows, 'x', 'x'), true)
})

test('only .node files are looked at, in every folder below, and one wrong file among right ones drops the folder', () => {
  const out = scratch()
  const spy = logged()
  const unit = path.join(out, 'unit')
  write(unit, 'bin/ok.node', elf(X86_64))
  write(unit, 'readme.txt', 'x')
  write(unit, 'helper.so', elf(AARCH64)) // not a .node file: not looked at
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'x64'), unit, 'x', 'x'), false)
  write(unit, 'deep/er/wrong.node', elf(AARCH64))
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'x64'), unit, 'x', 'x'), true)
  assert.equal(fs.existsSync(unit), false)
  assert.match(lines(spy)[0], /deep[\\/]er[\\/]wrong\.node is built for arm64/)
})

test('what cannot be checked stays: an unreadable header, macOS, a chip it has no table for', () => {
  const out = scratch()
  const spy = logged()
  const odd = path.join(out, 'odd'); write(odd, 'a.node', 'not a library')
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'x64'), odd, 'x', 'x'), false)
  const mac = path.join(out, 'mac'); write(mac, 'a.node', elf(AARCH64))
  assert.equal(afterPack.dropWrongChip(context(out, 'darwin', 'x64'), mac, 'x', 'x'), false, 'no format known for macOS')
  const universal = path.join(out, 'universal'); write(universal, 'a.node', elf(AARCH64))
  assert.equal(afterPack.dropWrongChip(context(out, 'linux', 'universal'), universal, 'x', 'x'), false, 'no chip to compare with')
  assert.equal(fs.existsSync(odd) && fs.existsSync(mac) && fs.existsSync(universal), true)
  assert.deepEqual(lines(spy), [])
})

// MARK: - The two steps that use it

test('the keyboard hook step keeps its own folder only, and drops that too when its library is for another chip (linux-arm64 holds x86-64)', () => {
  const out = scratch()
  const spy = logged()
  const prebuilds = path.join(out, 'resources', 'app.asar.unpacked', 'node_modules', 'uiohook-napi', 'prebuilds')
  write(prebuilds, 'linux-arm64/uiohook_napi.node', elf(X86_64))
  write(prebuilds, 'linux-x64/uiohook_napi.node', elf(X86_64))
  write(prebuilds, 'win32-x64/uiohook_napi.node', pe(PE_X64))
  write(prebuilds, 'win32-arm64/uiohook_napi.node', pe(PE_ARM64))
  afterPack.keepOnlyThisKeyboardHook(context(out, 'linux', 'arm64'))
  assert.deepEqual(fs.readdirSync(prebuilds), [], 'the other systems went, and the arm64 folder with the wrong library after them')
  assert.equal(lines(spy).length, 1)
  assert.match(lines(spy)[0], /uiohook-napi: .*linux-arm64.*built for x86-64 \(ELF\).*satz starts without the keyboard hook/)
  // A package whose library fits keeps it.
  write(prebuilds, 'linux-x64/uiohook_napi.node', elf(X86_64))
  write(prebuilds, 'win32-arm64/uiohook_napi.node', pe(PE_ARM64))
  spy.mock.resetCalls()
  afterPack.keepOnlyThisKeyboardHook(context(out, 'win32', 'arm64'))
  assert.deepEqual(fs.readdirSync(prebuilds), ['win32-arm64'])
  assert.deepEqual(lines(spy), [])
})

test('the ONNX Runtime step keeps its own system and chip, and drops it when the library there is for another chip', () => {
  const out = scratch()
  const spy = logged()
  const bin = path.join(out, 'resources', 'app.asar.unpacked', 'node_modules', 'onnxruntime-node', 'bin', 'napi-v6')
  write(bin, 'linux/x64/onnxruntime_binding.node', elf(X86_64))
  write(bin, 'linux/arm64/onnxruntime_binding.node', elf(AARCH64))
  write(bin, 'win32/x64/onnxruntime_binding.node', pe(PE_X64))
  afterPack.keepOnlyThisOnnxRuntime(context(out, 'linux', 'arm64'))
  assert.deepEqual(fs.readdirSync(path.join(bin, 'linux')), ['arm64'])
  assert.equal(fs.existsSync(path.join(bin, 'win32')) && fs.readdirSync(path.join(bin, 'win32')).length > 0, false)
  assert.deepEqual(lines(spy), [])
  // The arm64 folder holds an x86-64 library: dropped, and the log says what it costs.
  write(bin, 'linux/arm64/onnxruntime_binding.node', elf(X86_64))
  afterPack.keepOnlyThisOnnxRuntime(context(out, 'linux', 'arm64'))
  assert.equal(fs.existsSync(path.join(bin, 'linux', 'arm64')), false)
  assert.match(lines(spy)[0], /onnxruntime-node: .*built for x86-64 \(ELF\).*local Whisper models cannot run in this package/)
})

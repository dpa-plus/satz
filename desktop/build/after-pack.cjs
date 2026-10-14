// Linux: Chromium checks its sandbox before any of satz's code runs. It needs
// a root-owned helper (only a .deb can install that) or user namespaces,
// which Ubuntu 24.04 and later restrict, so a tar.gz or AppImage would not
// start. The real binary becomes satz-bin and `satz` starts it without the
// sandbox; satz only shows its own two local pages.
//
// It also starts it through X11 (XWayland under Wayland): a Wayland window
// cannot keep itself on top or choose where it sits, and the card has to do
// both. Both switches are read before any of satz's code runs, so they have
// to come from outside. SATZ_NATIVE_WAYLAND=1 skips the X11 one.
const crypto = require('node:crypto')
const { execFileSync } = require('node:child_process')
const fs = require('node:fs')
const path = require('node:path')

exports.keepOnlyThisKeyboardHook = keepOnlyThisKeyboardHook
exports.keepOnlyThisOnnxRuntime = keepOnlyThisOnnxRuntime
exports.chipOf = chipOf
exports.dropWrongChip = dropWrongChip

exports.default = async function afterPack(context) {
  keepOnlyThisOnnxRuntime(context)
  keepOnlyThisKeyboardHook(context)
  await addSherpa(context)
  if (context.electronPlatformName !== 'linux') return
  const name = context.packager.executableName
  const binary = path.join(context.appOutDir, name)
  fs.renameSync(binary, `${binary}-bin`)
  fs.writeFileSync(binary, [
    '#!/bin/sh',
    'here="$(dirname "$(readlink -f "$0")")"',
    'if [ -n "$SATZ_NATIVE_WAYLAND" ]; then exec "$here/' + name + '-bin" --no-sandbox "$@"; fi',
    'exec "$here/' + name + '-bin" --no-sandbox --ozone-platform=x11 "$@"',
    '',
  ].join('\n'), { mode: 0o755 })
}

// ONNX Runtime (for Whisper on this computer) ships its native library for
// every system and chip, 300 MB in all; each package keeps its own.
function keepOnlyThisOnnxRuntime(context) {
  const { Arch } = require('electron-builder')
  const bin = path.join(context.appOutDir, 'resources', 'app.asar.unpacked', 'node_modules', 'onnxruntime-node', 'bin', 'napi-v6')
  if (!fs.existsSync(bin)) return
  const arch = Arch[context.arch]
  for (const system of fs.readdirSync(bin)) {
    for (const chip of fs.readdirSync(path.join(bin, system))) {
      if (system !== context.electronPlatformName || chip !== arch) fs.rmSync(path.join(bin, system, chip), { recursive: true, force: true })
    }
  }
  const own = path.join(bin, context.electronPlatformName, arch)
  if (fs.existsSync(own)) dropWrongChip(context, own, 'onnxruntime-node', 'local Whisper models cannot run in this package')
}

// The keyboard hook (uiohook-napi) carries a prebuilt library for every system
// and chip, found by name at run time: <system>-<chip>. Each package keeps its own.
function keepOnlyThisKeyboardHook(context) {
  const { Arch } = require('electron-builder')
  const prebuilds = path.join(context.appOutDir, 'resources', 'app.asar.unpacked', 'node_modules', 'uiohook-napi', 'prebuilds')
  if (!fs.existsSync(prebuilds)) return
  const own = `${context.electronPlatformName}-${Arch[context.arch]}`
  if (!fs.existsSync(path.join(prebuilds, own))) throw new Error(`uiohook-napi has no prebuilt library for ${own}`)
  for (const name of fs.readdirSync(prebuilds)) if (name !== own) fs.rmSync(path.join(prebuilds, name), { recursive: true, force: true })
  // uiohook-napi's linux-arm64 folder holds the x86-64 library. A library that
  // cannot be loaded is no worse than none: keyboard.ts starts satz without
  // the hook either way, but this says so while building.
  dropWrongChip(context, path.join(prebuilds, own), 'uiohook-napi', 'satz starts without the keyboard hook (shortcut: "satz --toggle")')
}

// What chip a native library was built for is in its file header, so a
// package named for one chip that holds another's library shows at build time
// and not as a library that will not load on the user's computer.
const CHIPS = {
  x64: { elf: 0x3e, pe: 0x8664, name: 'x86-64' },
  arm64: { elf: 0xb7, pe: 0xaa64, name: 'arm64' },
  ia32: { elf: 0x03, pe: 0x014c, name: 'x86' },
  armv7l: { elf: 0x28, pe: 0x01c4, name: 'arm' },
}
const FORMAT_OF = { linux: 'elf', win32: 'pe' }

/** Which format and chip a library is for, read from its header: ELF (Linux) or PE (Windows). null for anything else, which cannot be checked. */
function chipOf(file) {
  const fd = fs.openSync(file, 'r')
  try {
    const head = Buffer.alloc(64)
    const read = fs.readSync(fd, head, 0, 64, 0)
    // "\x7fELF"; byte 5 says how the numbers are written, e_machine is at 18.
    if (read >= 20 && head.readUInt32BE(0) === 0x7f454c46) {
      return { format: 'elf', machine: head[5] === 2 ? head.readUInt16BE(18) : head.readUInt16LE(18) }
    }
    // "MZ", then the offset of "PE\0\0" at 0x3c; the Machine field follows the signature.
    if (read >= 64 && head[0] === 0x4d && head[1] === 0x5a) {
      const signature = Buffer.alloc(6)
      if (fs.readSync(fd, signature, 0, 6, head.readUInt32LE(0x3c)) === 6 && signature.toString('latin1', 0, 4) === 'PE\0\0') {
        return { format: 'pe', machine: signature.readUInt16LE(4) }
      }
    }
    return null
  } finally { fs.closeSync(fd) }
}

function nativeFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const full = path.join(dir, entry.name)
    return entry.isDirectory() ? nativeFiles(full) : entry.name.endsWith('.node') ? [full] : []
  })
}

/**
 * Removes `unit` (the folder that belongs to one system and chip) when a
 * .node file in it was built for another. A file this cannot read the header
 * of, and a system it knows no format for (macOS), stays.
 */
function dropWrongChip(context, unit, label, consequence) {
  const { Arch } = require('electron-builder')
  const wanted = CHIPS[Arch[context.arch]]
  const format = FORMAT_OF[context.electronPlatformName]
  if (!wanted || !format) return false
  for (const file of nativeFiles(unit)) {
    const found = chipOf(file)
    if (!found || (found.format === format && found.machine === wanted[format])) continue
    const actual = Object.values(CHIPS).find(chip => chip[found.format] === found.machine)?.name ?? `machine 0x${found.machine.toString(16)}`
    console.log(`  • ${label}: ${path.relative(context.appOutDir, file)} is built for ${actual} (${found.format.toUpperCase()}), this package is ${context.electronPlatformName}-${Arch[context.arch]}: dropped, ${consequence}`)
    fs.rmSync(unit, { recursive: true, force: true })
    return true
  }
  return false
}

// sherpa-onnx (Handy's models) brings its native code as one npm package per
// system, and npm installs only the one for the Mac that builds. Each package
// gets its own system's, at the version and checksum package-lock.json names
// (kept in build/sherpa/), beside app.asar, where sherpaEngine.ts loads it: a
// native library inside the archive could not load the ONNX Runtime next to
// it. There is none for Windows on ARM; satz offers no sherpa models there.
async function addSherpa(context) {
  const { Arch } = require('electron-builder')
  const platform = context.electronPlatformName
  if (platform !== 'linux' && platform !== 'win32') return
  const name = `sherpa-onnx-${platform === 'win32' ? 'win' : platform}-${Arch[context.arch]}`
  const lock = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package-lock.json'), 'utf8'))
  const entry = lock.packages[`node_modules/${name}`]
  if (!entry) {
    console.log(`  • sherpa-onnx: no ${name}, its models are not offered there`)
    return
  }
  const [algorithm, expected] = entry.integrity.split('-')
  const digest = file => crypto.createHash(algorithm).update(fs.readFileSync(file)).digest('base64')
  const archive = path.join(__dirname, 'sherpa', `${name}-${entry.version}.tgz`)
  if (!fs.existsSync(archive) || digest(archive) !== expected) {
    const response = await fetch(entry.resolved)
    if (!response.ok) throw new Error(`${name}: status ${response.status}`)
    fs.mkdirSync(path.dirname(archive), { recursive: true })
    fs.writeFileSync(archive, Buffer.from(await response.arrayBuffer()))
    if (digest(archive) !== expected) throw new Error(`${name} does not match package-lock.json`)
  }
  const target = path.join(context.appOutDir, 'resources', 'app.asar.unpacked', 'node_modules', name)
  fs.rmSync(target, { recursive: true, force: true })
  fs.mkdirSync(target, { recursive: true })
  execFileSync('tar', ['-xzf', archive, '-C', target, '--strip-components=1'])
  if (dropWrongChip(context, target, 'sherpa-onnx', 'its models are not offered there')) return
  console.log(`  • sherpa-onnx: ${name} ${entry.version}`)
}

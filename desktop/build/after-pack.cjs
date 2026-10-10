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
  console.log(`  • sherpa-onnx: ${name} ${entry.version}`)
}

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
const fs = require('node:fs')
const path = require('node:path')

exports.default = async function afterPack(context) {
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

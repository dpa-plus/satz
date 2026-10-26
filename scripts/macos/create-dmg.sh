#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 /path/to/satz.app /path/to/satz-mac.dmg" >&2
    exit 2
fi
app="$1"
output="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$app")" != "satz.app" ] || [ ! -f "$app/Contents/Info.plist" ]; then
    echo "Expected a staged satz.app bundle." >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
work="$(mktemp -d "${TMPDIR:-/tmp}/satz-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root" "$(dirname "$output")"
# The layout is generated metadata; Finder never opens or modifies this copy.
ditto --norsrc --noextattr "$app" "$work/root/satz.app"
ln -s /Applications "$work/root/Applications"
cp "$script_dir/dmg-layout.dsstore" "$work/root/.DS_Store"
codesign --verify --deep --strict "$work/root/satz.app"
hdiutil create -volname satz -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -srcfolder "$work/root" "$work/satz-mac.dmg"
hdiutil verify "$work/satz-mac.dmg"
mv -f "$work/satz-mac.dmg" "$output"
echo "built $output"

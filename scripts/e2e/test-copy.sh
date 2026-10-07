#!/bin/zsh
# Makes "satz test.app" in ~/Applications from dist/satz.app: its own name and
# bundle id (plus.dpa.satz.test), so its settings never touch the real satz's.
# It still shares the key files in ~/Library/Application Support/satz; in test
# mode its history lives next to the state file.
#
#   scripts/e2e/test-copy.sh            copy the current dist/satz.app
#   scripts/e2e/test-copy.sh --build    make app first
#
# Then drive it with scripts/e2e/e2e.sh (launch, cmd, st, stop).
set -e
root=${0:A:h:h:h}
copy="$HOME/Applications/satz test.app"
[ "$1" = "--build" ] && make -C "$root" app | tail -1
pkill -f "satz test.app/Contents/MacOS/satz" 2>/dev/null || true
rm -rf "$copy"
mkdir -p "$HOME/Applications"
ditto "$root/dist/satz.app" "$copy"
plist="$copy/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier plus.dpa.satz.test" -c "Set :CFBundleName satz test" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName satz test" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string satz test" "$plist"
# The cloud-synced project folder stamps attributes that codesign refuses.
xattr -cr "$copy"
codesign --force --sign - --identifier plus.dpa.satz.test "$copy" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify "$copy"
echo "made $copy"

#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=… $0 satz.app satz-mac.dmg satz.zip" >&2
    exit 2
fi
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to an existing Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile name.}"
script_dir="$(cd "$(dirname "$0")" && pwd)"
"$script_dir/sign-app.py" --check-identity --identity "$SIGN_IDENTITY"
app="$1"
dmg_output="$2"
zip_output="$3"
codesign --verify --deep --strict "$app"
# Verify the caller supplied a hardened Developer ID app, not just a configured
# certificate name alongside an ad-hoc bundle. No network work happens first.
signature="$(codesign -dvv "$app" 2>&1)"
if ! [[ "$signature" == *"Authority=$SIGN_IDENTITY"* && "$signature" == *"runtime"* && "$signature" == *"Timestamp="* ]]; then
    echo "The app must already be signed with SIGN_IDENTITY, Hardened Runtime and a secure timestamp." >&2
    exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/satz-notary.XXXXXX")"
trap 'rm -rf "$work"' EXIT
log_root="${NOTARY_LOG_DIR:-$(dirname "$dmg_output")/notary-logs}"
mkdir -p "$log_root"
log_dir="$(mktemp -d "$log_root/submission.XXXXXX")"
echo "Notarization records: $log_dir"
submit() {
    local artifact="$1" kind="$2" request_id
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout 20m --output-format json > "$log_dir/$kind.json"
    # notarytool's process exit code alone does not establish acceptance.
    request_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$log_dir/$kind.json")"
    xcrun notarytool log "$request_id" --keychain-profile "$NOTARY_PROFILE" "$log_dir/$kind.log.json"
    if ! /usr/bin/python3 - "$log_dir/$kind.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    result = json.load(source)
print("Notarization " + str(result.get("id", "unknown")) + ": " + str(result.get("status", "unknown")))
sys.exit(0 if result.get("status") == "Accepted" else 1)
PY
    then
        echo "Notarization was not accepted. See $log_dir; release outputs were not replaced." >&2
        exit 1
    fi
}
ditto --norsrc --noextattr "$app" "$work/satz.app"
ditto -c -k --norsrc --noextattr --keepParent "$work/satz.app" "$work/notary-app.zip"
submit "$work/notary-app.zip" app
xcrun stapler staple "$work/satz.app"
xcrun stapler validate "$work/satz.app"
codesign --verify --deep --strict "$work/satz.app"
spctl --assess --type execute --verbose=2 "$work/satz.app"

# A ZIP cannot carry a ticket of its own, so archive the stapled app.
ditto -c -k --norsrc --noextattr --keepParent "$work/satz.app" "$work/satz.zip"
"$script_dir/create-dmg.sh" "$work/satz.app" "$work/satz-mac.dmg"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$work/satz-mac.dmg"
submit "$work/satz-mac.dmg" dmg
xcrun stapler staple "$work/satz-mac.dmg"
xcrun stapler validate "$work/satz-mac.dmg"
hdiutil verify -quiet "$work/satz-mac.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$work/satz-mac.dmg"

# Keep old release outputs untouched until both artifacts pass verification.
mkdir -p "$(dirname "$dmg_output")" "$(dirname "$zip_output")"
cp "$work/satz-mac.dmg" "$dmg_output"
cp "$work/satz.zip" "$zip_output"
echo "Notarized and stapled: $dmg_output"
echo "Compatibility ZIP containing the stapled app: $zip_output"

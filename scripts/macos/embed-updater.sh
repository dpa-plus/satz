#!/bin/bash
# SwiftPM links Sparkle but a hand-built .app must embed its runtime helpers.
set -euo pipefail
if [[ $# != 2 ]]; then echo "Usage: embed-updater.sh APP BUILD_PRODUCTS" >&2; exit 2; fi
app=$1
products=$2
framework="$products/Sparkle.framework"
search=$products
while [[ ! -d "$framework" && "$search" != / ]]; do
  framework="$search/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  search=$(dirname "$search")
done
[[ -d "$framework" ]] || { echo "Sparkle.framework missing; resolve/build the Swift package first." >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"

#!/bin/zsh
# Test-mode helpers. Usage:
#   source scripts/e2e/e2e.sh
#   launch "a.wav:b.wav" [-triggerMode hold ...]; cmd press; sleep 6; cmd press; st; stop
# A test copy never pastes, and leaves the real satz's shortcut and Escape alone.
E2E_DIR=${E2E_DIR:-"${TMPDIR:-/tmp}/satz-e2e"}
SATZ_ROOT=${0:A:h:h:h}
APP="$SATZ_ROOT/dist/satz.app/Contents/MacOS/satz"
[ -x "$E2E_DIR/satzdev" ] || { mkdir -p "$E2E_DIR"; swiftc -O "$SATZ_ROOT/scripts/e2e/satzdev.swift" -o "$E2E_DIR/satzdev"; }
[ -f "$E2E_DIR/a.wav" ] || "$SATZ_ROOT/scripts/e2e/make-audio.sh" "$E2E_DIR" >/dev/null
launch() {
  local files=""; for f in ${(s.:.)1}; do files="$files${files:+:}$E2E_DIR/$f"; done; shift
  rm -f "$E2E_DIR/state.json"
  "$APP" --test-audio "$files" --dev-control "$E2E_DIR/state.json" "$@" > "$E2E_DIR/satz.log" 2>&1 &
  sleep 2
}
cmd() { "$E2E_DIR/satzdev" "$1"; }
st() { cmd dump; sleep 0.4; python3 -c "import json;d=json.load(open('$E2E_DIR/state.json'));print(d['phase'],'| sending',d['sending'],'| text:',repr(d['text']),'| delivered:',d['delivered'],'| window:',d['window'])"; }
stop() { pkill -f "satz --test-audio"; sleep 0.5; }

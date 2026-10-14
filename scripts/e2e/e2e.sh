#!/bin/zsh
# Test-mode helpers. Usage:
#   scripts/e2e/test-copy.sh --build      once per change: makes "satz test.app"
#   source scripts/e2e/e2e.sh
#   launch "a.wav:b.wav" [-triggerMode hold ...]; cmd press; sleep 6; cmd press; st; stop
# A test copy never pastes, and leaves the real satz's shortcut and Escape alone.
# Local models: launch "a.wav" -provider local --models-dir <scratch folder>.
# Downloads only go there; without it the copy uses the user's models and
# refuses to download or delete any.
# It runs as "satz test" with its own settings; without the copy it falls back
# to dist/satz.app, which shares the real satz's settings.
# E2E_ONLY=1 with E2E_RUN=<a folder of this session's own>: the copy keeps its
# state file and log there, only it hears `cmd`, and `stop` stops only it.
# Without it every test copy listening takes every command, and another
# session's `quit` stopped one halfway through a test.
E2E_SHARED=${${TMPDIR:-/tmp}%/}/satz-e2e
E2E_DIR=${E2E_DIR:-$E2E_SHARED}
E2E_RUN=${${E2E_RUN:-$E2E_DIR}:a}
if [ -n "$E2E_ONLY" ] && [ "$E2E_RUN" = "${E2E_SHARED:a}" ]; then
  echo "E2E_ONLY=1 needs E2E_RUN=<a folder of this session's own>: the shared one reaches other sessions' copies." >&2
  return 1 2>/dev/null || exit 1
fi
mkdir -p "$E2E_RUN"
SATZ_ROOT=${0:A:h:h:h}
APP="$HOME/Applications/satz test.app/Contents/MacOS/satz"
[ -x "$APP" ] || APP="$SATZ_ROOT/dist/satz.app/Contents/MacOS/satz"
[ -x "$E2E_DIR/satzdev" ] || { mkdir -p "$E2E_DIR"; swiftc -O "$SATZ_ROOT/scripts/e2e/satzdev.swift" -o "$E2E_DIR/satzdev"; }
[ -f "$E2E_DIR/a.wav" ] || "$SATZ_ROOT/scripts/e2e/make-audio.sh" "$E2E_DIR" >/dev/null
launch() {
  local files=""; for f in ${(s.:.)1}; do files="$files${files:+:}$E2E_DIR/$f"; done; shift
  rm -f "$E2E_RUN/state.json"
  "$APP" --test-audio "$files" --dev-control "$E2E_RUN/state.json" "$@" > "$E2E_RUN/satz.log" 2>&1 &
  sleep 2
}
cmd() { "$E2E_DIR/satzdev" "${E2E_ONLY:+@$E2E_RUN/state.json|}$1"; }
st() { cmd dump; sleep 0.4; python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['phase'],'| sending',d['sending'],'| text:',repr(d['text']),'| delivered:',d['delivered'],'| window:',d['window'])" "$E2E_RUN/state.json"; }
# pkill takes a regular expression: the folder's dots and pluses are meant literally.
stop() {
  if [ -n "$E2E_ONLY" ]; then
    pkill -f -- "$(printf '%s' "--dev-control $E2E_RUN/state.json" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
  else
    pkill -f "satz --test-audio"
  fi
  sleep 0.5
}

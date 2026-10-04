#!/bin/zsh
# Spoken test clips (16 kHz mono WAV) for test mode, made with macOS's own voices.
set -e
out=${1:-"${TMPDIR:-/tmp}/satz-e2e"}
mkdir -p "$out"
clip() { say -v Anna -o "$out/$1.aiff" "$2"; afconvert -f WAVE -d LEI16@16000 -c 1 "$out/$1.aiff" "$out/$1.wav"; rm "$out/$1.aiff"; }
clip a "Schreib mir eine Funktion, die alle Rechnungen aus dem Ordner Buchhaltung liest."
clip b "Danach soll sie die Beträge pro Kunde summieren, Klammer auf, ohne Gutschriften, Klammer zu."
clip c "Nur die PDF Dateien."
python3 - "$out/silence.wav" <<'PY'
import struct, sys
data = b"\0\0" * 16000 * 4
hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(data))
open(sys.argv[1], "wb").write(hdr + data)
PY
echo "$out"

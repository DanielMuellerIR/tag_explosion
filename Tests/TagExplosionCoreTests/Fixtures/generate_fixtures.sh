#!/bin/sh
# Erzeugt kleine Test-Mediendateien (Sinuston, 2 s) in allen unterstützten
# Audio-Formaten plus ein Testbild. Benötigt ffmpeg. Ausgabe nach $1
# (Standard: ./generated neben diesem Skript). Idempotent.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/generated}"
mkdir -p "$out"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg nicht gefunden — Fixtures können nicht erzeugt werden" >&2
    exit 1
fi

# 2 Sekunden 440-Hz-Sinus als Quelle (einmalig als wav)
src="$out/source.wav"
[ -f "$src" ] || ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=440:duration=2" "$src"

# Formate: <ausgabedatei> <ffmpeg-optionen>
gen() {
    target="$out/$1"; shift
    [ -f "$target" ] && return 0
    ffmpeg -nostdin -v error -y -i "$src" "$@" "$target"
}

gen sample.mp3  -codec:a libmp3lame -b:a 64k
gen sample.m4a  -codec:a aac -b:a 64k
gen sample.flac -codec:a flac
# ffmpeg ohne libvorbis: eingebauter (experimenteller) Vorbis-Encoder reicht für
# Fixtures, kann aber nur Stereo -> -ac 2
gen sample.ogg  -ac 2 -codec:a vorbis -strict experimental
gen sample.opus -codec:a libopus -b:a 64k
gen sample.wav  -codec:a pcm_s16le
gen sample.aiff -codec:a pcm_s16be
gen sample.wv   -codec:a wavpack

# m4b = m4a-Container mit anderer Endung (Hörbuch)
[ -f "$out/sample.m4b" ] || cp "$out/sample.m4a" "$out/sample.m4b"

# Testbilder: 64x64 rot (jpg) und blau (png)
[ -f "$out/cover.jpg" ] || ffmpeg -nostdin -v error -y -f lavfi -i "color=red:size=64x64:duration=0.04" -frames:v 1 "$out/cover.jpg"
[ -f "$out/cover.png" ] || ffmpeg -nostdin -v error -y -f lavfi -i "color=blue:size=64x64:duration=0.04" -frames:v 1 "$out/cover.png"

echo "$out"

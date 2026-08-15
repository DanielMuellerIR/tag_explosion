#!/bin/sh
# Headless-Regression für beide Icon-Generatoren: parallele Läufe dürfen ihre
# Tempdateien nicht teilen, und ein unbrauchbares Ausgabeziel muss nonzero
# enden statt lediglich „FEHLER“ auszugeben.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d /tmp/tag-explosion-icon-tests.XXXXXX)"
trap 'rm -r "$test_root"' EXIT HUP INT TERM

mkdir "$test_root/generated" "$test_root/from-image"

swift "$root/scripts/make-icon.swift" "$test_root/generated" \
    >"$test_root/generated.log" 2>&1 &
generated_pid=$!
swift "$root/scripts/icon-from-image.swift" \
    "$root/App/Resources/AppIcon-Quelle.png" "$test_root/from-image" \
    >"$test_root/from-image.log" 2>&1 &
source_pid=$!

wait "$generated_pid"
wait "$source_pid"
test -s "$test_root/generated/AppIcon.icns"
test -s "$test_root/from-image/AppIcon.icns"

blocked="$test_root/not-a-directory"
: > "$blocked"
if swift "$root/scripts/make-icon.swift" "$blocked" \
    >"$test_root/blocked-make.log" 2>&1; then
    echo "make-icon meldet ein unbrauchbares Ausgabeziel als Erfolg" >&2
    exit 1
fi
if swift "$root/scripts/icon-from-image.swift" \
    "$root/App/Resources/AppIcon-Quelle.png" "$blocked" \
    >"$test_root/blocked-source.log" 2>&1; then
    echo "icon-from-image meldet ein unbrauchbares Ausgabeziel als Erfolg" >&2
    exit 1
fi

echo "OK: Icon-Generatoren sind parallel und melden Fehler per Exit-Code"

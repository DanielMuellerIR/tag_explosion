#!/bin/sh
# Prüft, dass kein ausgeliefertes Mach-O ein neueres macOS verlangt als die App.
set -eu

app="${1:?Aufruf: verify-macos-minimums.sh <App-Bundle>}"
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || { echo "FEHLER: Info.plist fehlt: $plist" >&2; exit 1; }

declared="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"

find "$app/Contents/MacOS" "$app/Contents/Frameworks" -type f -print \
    | while IFS= read -r binary; do
        file "$binary" | grep -q 'Mach-O' || continue
        actual="$(xcrun vtool -show-build "$binary" \
            | awk '$1 == "minos" { print $2; exit }')"
        [ -n "$actual" ] || continue

        newest="$(printf '%s\n%s\n' "$declared" "$actual" | sort -V | tail -1)"
        if [ "$newest" != "$declared" ]; then
            echo "FEHLER: $binary verlangt macOS $actual, App verspricht $declared." >&2
            exit 1
        fi
    done || exit 1

echo "MINIMUM SYSTEM OK: macOS $declared"

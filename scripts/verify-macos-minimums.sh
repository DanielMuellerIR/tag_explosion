#!/bin/sh
# Prüft, dass kein ausgeliefertes Mach-O ein neueres macOS verlangt als die App.
#
# Der Schutz muss geschlossen fehlschlagen: Jede Datei, deren Mindestversion
# nicht ermittelt werden kann, gilt als ungeprüft und lässt das Skript scheitern.
# Ein stilles Überspringen würde am Ende trotzdem "MINIMUM SYSTEM OK" melden.
set -eu

app="${1:?Aufruf: verify-macos-minimums.sh <App-Bundle>}"
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || { echo "FEHLER: Info.plist fehlt: $plist" >&2; exit 1; }

declared="$(plutil -extract LSMinimumSystemVersion raw -o - "$plist")"

# Die Dateiliste geht bewusst über eine Datei statt über eine Pipe: Hinter einer
# Pipe liefe die while-Schleife in einer Subshell — ein Fehler von `find` bliebe
# dort unsichtbar, und `exit 1` aus der Schleife beendete nur die Subshell.
list="$(mktemp)"
trap 'rm -f "$list"' EXIT
find "$app/Contents/MacOS" "$app/Contents/Frameworks" -type f -print > "$list"

checked=0
while IFS= read -r binary; do
    kind="$(file -b "$binary")" || {
        echo "FEHLER: Dateityp von $binary nicht bestimmbar." >&2
        exit 1
    }
    case "$kind" in
        *Mach-O*) ;;
        *) continue ;;
    esac

    # Erst der Erfolg von vtool, dann die Auswertung: In einer Pipeline
    # `vtool … | awk` bestimmt nur awk den Status, ein vtool-Fehler verschwände.
    if ! build_info="$(xcrun vtool -show-build "$binary" 2>&1)"; then
        echo "FEHLER: vtool konnte $binary nicht lesen:" >&2
        printf '%s\n' "$build_info" >&2
        exit 1
    fi

    # Universal-Binaries tragen je Architektur einen eigenen minos-Wert; jeder
    # davon wird geprüft, nicht nur der erste.
    versions="$(printf '%s\n' "$build_info" | awk '$1 == "minos" { print $2 }')"
    [ -n "$versions" ] || {
        echo "FEHLER: $binary nennt keine Mindestversion (minos)." >&2
        exit 1
    }
    for actual in $versions; do
        newest="$(printf '%s\n%s\n' "$declared" "$actual" | sort -V | tail -1)"
        if [ "$newest" != "$declared" ]; then
            echo "FEHLER: $binary verlangt macOS $actual, App verspricht $declared." >&2
            exit 1
        fi
    done
    checked=$((checked + 1))
done < "$list"

# Null geprüfte Dateien heißt nicht "alles in Ordnung", sondern dass die Suche
# ins Leere lief (falscher Pfad, leeres Bundle).
[ "$checked" -gt 0 ] || {
    echo "FEHLER: Kein Mach-O gefunden — ist $app wirklich ein App-Bundle?" >&2
    exit 1
}

echo "MINIMUM SYSTEM OK: macOS $declared ($checked Mach-O geprüft)"

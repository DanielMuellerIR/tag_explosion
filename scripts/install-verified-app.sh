#!/usr/bin/env bash
# Setzt ein bereits gebautes und vorgeprueftes App-Bundle atomar am Ziel ein.
# Der Helfer ist getrennt, damit die Rollback-Logik mit temporaeren Zielen
# getestet werden kann, ohne jemals /Applications anzufassen.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Aufruf: scripts/install-verified-app.sh <app-bundle> <ziel>" >&2
    exit 2
fi

app=$1
dest=$2
parent=$(dirname "$dest")
name=$(basename "$dest")
new="$parent/.$name.new.$$"
old="$parent/.$name.old.$$"

installed=0
replacement_deployed=0

# Ein früherer fehlgeschlagener Rollback bewahrt $old absichtlich. Wird die
# Prozess-ID später wiederverwendet, darf mv das neue Ziel nicht in dieses
# Bundle hinein verschachteln. In diesem seltenen Fall vor jeder Mutation
# abbrechen und beide bestehenden Stände unangetastet lassen.
if [ -e "$new" ] || [ -e "$old" ]; then
    echo "FEHLER: Installer-Zwischenpfad existiert bereits; nichts wurde verändert: $old" >&2
    exit 1
fi

verify_bundle() {
    local bundle=$1
    xcrun stapler validate "$bundle"
    spctl --assess --type execute --verbose=2 "$bundle"
    codesign --verify --deep --strict --verbose=2 "$bundle"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP

    if [ "$installed" -eq 0 ]; then
        if [ -e "$old" ]; then
            # Die alte Fassung wurde bereits beiseitegestellt. Ein eventuell
            # eingesetzter Ersatz muss weg, bevor das atomare Restore gelingt.
            if [ -e "$dest" ]; then rm -rf -- "$dest"; fi
            if mv "$old" "$dest"; then
                # Erst der erfolgreiche mv beweist, dass die gute Fassung
                # wieder am Ziel liegt. Vorher darf $old nie entfernt werden.
                :
            else
                echo "FEHLER: Rollback fehlgeschlagen; die gute Installation bleibt erhalten: $old" >&2
                status=1
            fi
        # Auch eine abgelehnte Erstinstallation muss wieder verschwinden.
        elif [ "$replacement_deployed" -eq 1 ] && [ -e "$dest" ]; then
            rm -rf -- "$dest"
        fi
    fi

    rm -rf -- "$new"
    if [ "$installed" -eq 1 ]; then
        # Das neue Bundle ist am echten Ziel vollständig geprüft. Erst jetzt
        # wird die beiseitegelegte alte Installation nicht mehr gebraucht.
        rm -rf -- "$old"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

ditto "$app" "$new"
verify_bundle "$new"

if [ -e "$dest" ]; then
    mv "$dest" "$old"
fi
replacement_deployed=1
if ! mv "$new" "$dest"; then
    echo "FEHLER: Konnte $dest nicht ersetzen; Rollback folgt." >&2
    exit 1
fi

# Nur die Pruefung am tatsaechlichen Ziel entscheidet ueber Erfolg. Bei einem
# Fehler entfernt cleanup den Ersatz und stellt die vorige Fassung wieder her.
verify_bundle "$dest"
installed=1

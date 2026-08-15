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
lock="$parent/.$name.lock"

installed=0
replacement_deployed=0
lock_held=0

# Zwei gleichzeitige Installationen auf DASSELBE Ziel würden einander in die
# Quere kommen: Legt der zweite Lauf zwischen "altes Ziel beiseite" und
# "neues Ziel einsetzen" wieder ein Verzeichnis am Ziel an, verschöbe BSD-mv
# das neue Bundle in dieses Verzeichnis hinein und meldete trotzdem Erfolg.
# `mkdir` ist die atomare Sperre dafür: Es gelingt genau einem Lauf.
#
# Der Besitzer steht als "PID|Prozessstartzeit" in $lock/owner. Die Startzeit
# schützt vor wiederverwendeten PIDs: `kill -0` allein hielte nach einem
# Absturz jeden fremden Prozess mit derselben PID für einen aktiven Installer.

# Startzeit eines Prozesses (leer, wenn er nicht mehr existiert).
proc_start_time() {
    ps -o lstart= -p "$1" 2>/dev/null | head -n 1
}

# Versucht, die Sperre atomar zu erwerben, und veröffentlicht sofort den
# Besitzer. Erst mit geschriebener owner-Datei gilt die Sperre als vollständig
# initialisiert.
claim_lock() {
    mkdir "$lock" 2>/dev/null || return 1
    lock_held=1
    printf '%s|%s\n' "$$" "$(proc_start_time "$$")" > "$lock/owner"
    return 0
}

# Entfernt eine fremde, tote Sperre atomar: Das Umbenennen gelingt genau einem
# von mehreren Übernehmern; die Verlierer laufen anschließend gegen die frische
# Sperre des Gewinners und brechen dort sauber ab.
takeover_stale_lock() {
    echo "Hinweis: verwaiste Installer-Sperre wird entfernt: $lock" >&2
    if mv "$lock" "$lock.stale.$$" 2>/dev/null; then
        rm -rf -- "$lock.stale.$$"
    fi
}

acquire_lock() {
    claim_lock && return 0
    # Die Sperre existiert. Kurz warten erlaubt einem gerade startenden
    # Besitzer, seine owner-Datei zu schreiben (Fenster zwischen mkdir und
    # owner-Write) — erst danach gilt eine besitzerlose Sperre als Leiche
    # eines abgestürzten Laufs.
    local waited=0 total=0 owner_pid owner_start
    while :; do
        total=$((total + 1))
        if [ "$total" -gt 200 ]; then
            echo "FEHLER: Installer-Sperre nicht erhalten: $lock" >&2
            exit 1
        fi
        if [ -f "$lock/owner" ]; then
            IFS='|' read -r owner_pid owner_start < "$lock/owner" || true
            if [ -n "${owner_pid:-}" ] && kill -0 "$owner_pid" 2>/dev/null \
               && [ "$(proc_start_time "$owner_pid")" = "$owner_start" ]; then
                echo "FEHLER: Eine andere Installation arbeitet bereits an $dest; nichts wurde verändert." >&2
                exit 1
            fi
            # Besitzer tot (oder PID inzwischen an einen anderen Prozess
            # vergeben): einmalig übernehmen — sonst blockierte ein Absturz
            # jede weitere Installation.
            takeover_stale_lock
            claim_lock && return 0
            waited=0
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt 40 ]; then
            # Über zwei Sekunden ohne owner-Datei: Der Erzeuger ist zwischen
            # mkdir und owner-Write gestorben.
            takeover_stale_lock
            claim_lock && return 0
            waited=0
            continue
        fi
        sleep 0.05
        # Inzwischen ganz verschwunden? Dann regulär erwerben.
        claim_lock && return 0
    done
}

acquire_lock

# Ein früherer fehlgeschlagener Rollback bewahrt $old absichtlich. Wird die
# Prozess-ID später wiederverwendet, darf mv das neue Ziel nicht in dieses
# Bundle hinein verschachteln. In diesem seltenen Fall vor jeder Mutation
# abbrechen und beide bestehenden Stände unangetastet lassen.
# Gibt die Sperre nur frei, wenn sie noch UNS gehört: Hätte ein Übernehmer sie
# uns wider Erwarten weggenommen, löschte ein blindes rm die aktive Sperre des
# anderen Laufs.
release_lock() {
    if [ "$lock_held" -eq 1 ] \
       && [ "$(head -n 1 "$lock/owner" 2>/dev/null | cut -d'|' -f1)" = "$$" ]; then
        rm -rf -- "$lock"
    fi
    lock_held=0
}

if [ -e "$new" ] || [ -e "$old" ]; then
    echo "FEHLER: Installer-Zwischenpfad existiert bereits; nichts wurde verändert: $old" >&2
    release_lock
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
    # EXIT abhängen (sonst liefe cleanup am Ende erneut), die übrigen Signale
    # aber IGNORIEREN statt auf ihr Standardverhalten zurückzusetzen: Zwischen
    # `rm "$dest"` und `mv "$old" "$dest"` würde ein zweites Ctrl-C den Prozess
    # sonst beenden, wenn der Ersatz schon weg und die gute Fassung noch nicht
    # zurück ist — das Ziel bliebe ohne App.
    trap - EXIT
    trap '' INT TERM HUP

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
    # Die Sperre zuletzt: Bis hierher darf kein zweiter Lauf an dieses Ziel.
    release_lock
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
# Vertragsprüfung zum Rename: Lag am Ziel wider Erwarten doch ein Verzeichnis,
# hätte mv das neue Bundle hineinverschoben statt es einzusetzen. Der Lock
# oben verhindert das; der Beleg dafür kostet nichts.
if [ -e "$dest/$(basename "$new")" ]; then
    echo "FEHLER: $dest war belegt, das neue Bundle wurde hineinverschoben; Rollback folgt." >&2
    exit 1
fi

# Nur die Pruefung am tatsaechlichen Ziel entscheidet ueber Erfolg. Bei einem
# Fehler entfernt cleanup den Ersatz und stellt die vorige Fassung wieder her.
verify_bundle "$dest"
installed=1

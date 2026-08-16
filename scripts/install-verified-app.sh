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
takeover_lock="$lock.takeover"

# Zwei gleichzeitige Installationen auf DASSELBE Ziel würden einander in die
# Quere kommen: Legt der zweite Lauf zwischen "altes Ziel beiseite" und
# "neues Ziel einsetzen" wieder ein Verzeichnis am Ziel an, verschöbe BSD-mv
# das neue Bundle in dieses Verzeichnis hinein und meldete trotzdem Erfolg.
#
# Die Sperre ist ein Symlink, dessen LINKZIEL den Besitzer trägt
# ("PID|Prozessstartzeit"). `ln -s` legt Link samt Inhalt in EINEM atomaren
# Schritt an — es gibt also kein Fenster, in dem die Sperre schon existiert,
# aber noch besitzerlos ist (das frühere mkdir-Verzeichnis brauchte einen
# zweiten Schritt für die owner-Datei; ein genau dort angehaltener Lauf wurde
# fälschlich für abgestürzt gehalten und verlor seine Sperre).
# Die Startzeit schützt vor wiederverwendeten PIDs: `kill -0` allein hielte
# nach einem Absturz jeden fremden Prozess mit derselben PID für einen
# aktiven Installer.

# Startzeit eines Prozesses (leer, wenn er nicht mehr existiert).
proc_start_time() {
    ps -o lstart= -p "$1" 2>/dev/null | head -n 1
}

my_owner="$$|$(proc_start_time "$$")"

# Besitzer der aktuellen Sperre (leer, wenn keine lesbar ist). Der zweite
# Zweig liest das owner-Dateiformat früherer Skriptfassungen, damit deren
# noch laufende Installationen respektiert werden.
lock_owner() {
    readlink "$lock" 2>/dev/null || head -n 1 "$lock/owner" 2>/dev/null || true
}

# Lebt der als "PID|Startzeit" notierte Besitzer wirklich noch?
owner_alive() {
    local owner=$1 pid start
    pid=${owner%%|*}
    start=${owner#*|}
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
        && [ "$(proc_start_time "$pid")" = "$start" ]
}

claim_lock() {
    ln -s "$my_owner" "$lock" 2>/dev/null || return 1
    # Zeigt der Pfad auf ein VERZEICHNIS (Altformat-Sperre), legt ln den Link
    # dort hinein statt zu scheitern. Nur das eigene Linkziel am Sperrpfad
    # beweist den Erwerb.
    [ "$(lock_owner)" = "$my_owner" ] || return 1
    lock_held=1
}

# Entfernt eine fremde Sperre NUR im gegenseitigen Ausschluss aller
# Übernehmer und NUR nach erneuter Besitzer-Prüfung innerhalb dieses
# Ausschlusses: Zwischen der Diagnose "Besitzer ist tot" beim Aufrufer und
# dem Entfernen hier könnte ein anderer Übernehmer die tote Sperre längst
# durch seine eigene, aktive ersetzt haben — ein blindes Entfernen stähle
# dann eine lebende Sperre und bräche die gegenseitige Ausschließung.
# Rückgabe 1 = gerade nicht möglich, der Aufrufer wartet und versucht es neu.
takeover_stale_lock() {
    if ! mkdir "$takeover_lock" 2>/dev/null; then
        # Ein anderer Übernehmer arbeitet gerade. Sein Hilfs-Lock umfasst nur
        # wenige Dateisystem-Operationen; steht es länger als 60 Sekunden,
        # ist der Übernehmer selbst abgestürzt und das Hilfs-Lock verwaist.
        local mtime now
        mtime=$(stat -f %m "$takeover_lock" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [ $((now - mtime)) -gt 60 ]; then
            rm -rf -- "$takeover_lock"
        fi
        return 1
    fi
    local owner
    owner=$(lock_owner)
    if [ -n "$owner" ] && owner_alive "$owner"; then
        # Die Sperre gehört inzwischen einem lebenden Lauf — nichts entfernen.
        rmdir "$takeover_lock" 2>/dev/null || true
        echo "FEHLER: Eine andere Installation arbeitet bereits an $dest; nichts wurde verändert." >&2
        exit 1
    fi
    if [ -e "$lock" ] || [ -L "$lock" ]; then
        echo "Hinweis: verwaiste Installer-Sperre wird entfernt: $lock" >&2
        rm -rf -- "$lock"
    fi
    rmdir "$takeover_lock" 2>/dev/null || true
}

acquire_lock() {
    local total=0 owner
    while :; do
        claim_lock && return 0
        total=$((total + 1))
        if [ "$total" -gt 200 ]; then
            echo "FEHLER: Installer-Sperre nicht erhalten: $lock" >&2
            exit 1
        fi
        owner=$(lock_owner)
        if [ -n "$owner" ] && owner_alive "$owner"; then
            echo "FEHLER: Eine andere Installation arbeitet bereits an $dest; nichts wurde verändert." >&2
            exit 1
        fi
        # Besitzer tot, Sperre unlesbar oder Altformat: exklusiv übernehmen.
        # Schlägt das fehl (ein anderer Übernehmer ist dran), kurz warten.
        takeover_stale_lock || sleep 0.05
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
    if [ "$lock_held" -eq 1 ] && [ "$(lock_owner)" = "$my_owner" ]; then
        rm -f -- "$lock"
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

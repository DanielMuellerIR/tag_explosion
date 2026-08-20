#!/usr/bin/env bash
# Regressionen fuer den Installer-Austausch. Alle Ziele liegen unter mktemp;
# /Applications wird weder gelesen noch beschrieben.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=./shell-test-support.sh
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-install-tests)

# Hintergrundlaeufe des Nebenlaeufigkeitstests. Ohne dieses Aufraeumen verlor ein
# noch laufender Installer beim Abbruch mitten in der Ausfuehrung seine
# PATH-Attrappen und sein Zielverzeichnis, und eine wartende spctl-Attrappe
# hielt die geerbte stdout/stderr-Pipe des CI-Schritts offen — der Job hing bis
# zum globalen Timeout, statt mit der eigentlichen Fehlermeldung zu enden
# (Review-Fund 2026-08-20).
background_pids=""
note_background() { background_pids="$background_pids $1"; }
stop_background_runs() {
    [ -n "$background_pids" ] || return 0
    # Erst die Haltepunkte freigeben, damit kein Hintergrundlauf in einer
    # Warteschleife stirbt, dann beenden und einsammeln.
    : > "$work/release" 2>/dev/null || true
    : > "$work/takeover-inner.release" 2>/dev/null || true
    for pid in $background_pids; do kill "$pid" 2>/dev/null || true; done
    for pid in $background_pids; do wait "$pid" 2>/dev/null || true; done
    background_pids=""
}
trap 'stop_background_runs; rm -rf -- "$work"' EXIT
fake_bin="$work/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ditto" <<'SH'
#!/usr/bin/env bash
cp -R "$1" "$2"
SH
cat > "$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fake_bin/codesign" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fake_bin/spctl" <<'SH'
#!/usr/bin/env bash
count=0
if [ -f "$VERIFY_COUNT_FILE" ]; then count=$(cat "$VERIFY_COUNT_FILE"); fi
count=$((count + 1))
printf '%s\n' "$count" > "$VERIFY_COUNT_FILE"
# Haltepunkt für den Nebenläufigkeitstest: Der Lauf bleibt mitten in der
# Pruefung stehen, bis die Freigabedatei auftaucht.
if [ "${BLOCK_SPCTL_CALL:-0}" -eq "$count" ]; then
    # Begrenzt wie die readlink-Attrappe unten: Bricht der Test ab, bevor die
    # Freigabedatei entsteht, darf dieser Lauf nicht ewig warten.
    waited=0
    while [ ! -f "${RELEASE_FILE:-/nonexistent}" ] && [ "$waited" -lt 400 ]; do
        sleep 0.05
        waited=$((waited + 1))
    done
fi
[ "${FAIL_SPCTL_CALL:-0}" -ne "$count" ]
SH
# Schickt auf Wunsch ein Signal im gefaehrlichsten Moment: nachdem der
# abgelehnte Ersatz am Ziel entfernt wurde, aber bevor die gute alte Fassung
# zurueckgeschoben ist.
cat > "$fake_bin/rm" <<'SH'
#!/usr/bin/env bash
if [ -n "${SIGNAL_ON_RM_OF:-}" ]; then
    for arg in "$@"; do
        if [ "$arg" = "$SIGNAL_ON_RM_OF" ]; then
            /bin/rm "$@"
            kill -TERM "$PPID" 2>/dev/null
            sleep 0.3
            exit 0
        fi
    done
fi
exec /bin/rm "$@"
SH
# Marker fuer den Wettlauf-Test: Sobald der Anwaerter den Besitzer des
# Uebernahme-Hilfslocks liest, wartet er nachweislich dort. Ein blosses
# `sleep 0.5` bewies das nicht — wurde der Hintergrundlauf erst nach dem
# Sperrtausch eingeplant, sah er sofort den lebenden Besitzer, brach
# erwartungsgemaess ab, und der Test bestand, ohne die erneute Pruefung in
# takeover_stale_lock je auszufuehren (Review-Fund 2026-08-17).
cat > "$fake_bin/readlink" <<'SH'
#!/usr/bin/env bash
if [ -n "${TAKEOVER_WAIT_MARKER:-}" ]; then
    for arg in "$@"; do
        case $arg in
            *.lock.takeover) : > "$TAKEOVER_WAIT_MARKER" ;;
        esac
    done
fi
# Zweiter Haltepunkt: erst NACH dem Erwerb des Hilfslocks, beim Lesen der
# HAUPTSPERRE. Genau dort sitzt die erneute Besitzerpruefung im gegenseitigen
# Ausschluss. Der Zustand liegt in Dateien, weil jeder readlink-Aufruf ein
# eigener Prozess ist: ".takeover-seen" heisst "Hilfslock erworben und
# geprueft", ".done" sorgt dafuer, dass nur der ERSTE solche Lesevorgang haelt.
if [ -n "${LOCK_READ_BLOCK_MARKER:-}" ]; then
    for arg in "$@"; do
        case $arg in
            *.lock.takeover) : > "$LOCK_READ_BLOCK_MARKER.takeover-seen" ;;
            *.lock)
                if [ -f "$LOCK_READ_BLOCK_MARKER.takeover-seen" ] &&
                   [ ! -f "$LOCK_READ_BLOCK_MARKER.done" ]; then
                    : > "$LOCK_READ_BLOCK_MARKER.done"
                    : > "$LOCK_READ_BLOCK_MARKER"
                    waited=0
                    while [ ! -f "${LOCK_READ_BLOCK_RELEASE:-}" ] && [ "$waited" -lt 200 ]; do
                        sleep 0.05
                        waited=$((waited + 1))
                    done
                fi
                ;;
        esac
    done
fi
exec /usr/bin/readlink "$@"
SH
cat > "$fake_bin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${FAIL_ROLLBACK:-0}" -eq 1 ] && [[ "$1" == *.old.* ]]; then
    exit 1
fi
exec /bin/mv "$@"
SH
chmod +x "$fake_bin"/*

assert_text() {
    local expected=$1 file=$2
    [ "$(cat "$file/payload")" = "$expected" ] || {
        echo "FEHLER: $file enthaelt nicht '$expected'" >&2
        exit 1
    }
}

# Wartet auf eine Bedingung (max. 10 s) statt auf eine feste Zeit. `condition`
# ist ein Kommando; ist es leer, wird auf die Marker-Datei `$path` gewartet.
# Alle Warteschleifen dieses Tests laufen hierueber, damit das Aufraeumen der
# Hintergrundlaeufe an einer Stelle sitzt (Review-Fund 2026-08-20).
wait_for() {
    local message=$1; shift
    local waited=0
    until "$@"; do
        sleep 0.05
        waited=$((waited + 1))
        [ "$waited" -lt 200 ] || { echo "FEHLER: $message" >&2; exit 1; }
    done
}

wait_for_file() {
    local path=$1 message=$2
    wait_for "$message" test -f "$path"
}

run_installer() {
    local source=$1 destination=$2
    PATH="$fake_bin:/usr/bin:/bin" \
        VERIFY_COUNT_FILE="$work/verify-count" \
        FAIL_SPCTL_CALL="${FAIL_SPCTL_CALL:-0}" \
        FAIL_ROLLBACK="${FAIL_ROLLBACK:-0}" \
        BLOCK_SPCTL_CALL="${BLOCK_SPCTL_CALL:-0}" \
        RELEASE_FILE="${RELEASE_FILE:-}" \
        SIGNAL_ON_RM_OF="${SIGNAL_ON_RM_OF:-}" \
        TAKEOVER_WAIT_MARKER="${TAKEOVER_WAIT_MARKER:-}" \
        LOCK_READ_BLOCK_MARKER="${LOCK_READ_BLOCK_MARKER:-}" \
        LOCK_READ_BLOCK_RELEASE="${LOCK_READ_BLOCK_RELEASE:-}" \
        "$root/scripts/install-verified-app.sh" "$source" "$destination"
}

new_source="$work/source.app"
mkdir -p "$new_source"
printf 'new\n' > "$new_source/payload"

# Erfolg: neue Fassung am Ziel, keine Geschwisterreste.
success_root="$work/success"
mkdir -p "$success_root"
rm -f "$work/verify-count"
run_installer "$new_source" "$success_root/TagExplosion.app"
assert_text new "$success_root/TagExplosion.app"
[ -z "$(find "$success_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Abgelehnte Erstinstallation: das schon eingesetzte Bundle muss verschwinden.
first_root="$work/first"
mkdir -p "$first_root"
rm -f "$work/verify-count"
if FAIL_SPCTL_CALL=2 run_installer "$new_source" "$first_root/TagExplosion.app"; then
    echo "FEHLER: abgelehnte Erstinstallation meldete Erfolg" >&2
    exit 1
fi
[ ! -e "$first_root/TagExplosion.app" ]
[ -z "$(find "$first_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Abgelehntes Update: alte Fassung wird wiederhergestellt.
update_root="$work/update"
mkdir -p "$update_root/TagExplosion.app"
printf 'old\n' > "$update_root/TagExplosion.app/payload"
rm -f "$work/verify-count"
if FAIL_SPCTL_CALL=2 run_installer "$new_source" "$update_root/TagExplosion.app"; then
    echo "FEHLER: abgelehntes Update meldete Erfolg" >&2
    exit 1
fi
assert_text old "$update_root/TagExplosion.app"
[ -z "$(find "$update_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Scheitert das Zurueckholen selbst, bleibt die gute Fassung unter $old liegen.
rollback_root="$work/rollback"
mkdir -p "$rollback_root/TagExplosion.app"
printf 'old\n' > "$rollback_root/TagExplosion.app/payload"
rm -f "$work/verify-count"
if FAIL_SPCTL_CALL=2 FAIL_ROLLBACK=1 \
    run_installer "$new_source" "$rollback_root/TagExplosion.app"; then
    echo "FEHLER: Rollback-Fehler meldete Erfolg" >&2
    exit 1
fi
[ ! -e "$rollback_root/TagExplosion.app" ]
old_backup=$(find "$rollback_root" -maxdepth 1 -name '.TagExplosion.app.old.*' -print)
[ -n "$old_backup" ]
assert_text old "$old_backup"

# Eine wiederverwendete PID darf ein erhaltenes $old nicht überschreiben oder
# das aktuelle Ziel hineinverschachteln. Ein exec hält die PID des vorbereitenden
# Testprozesses für den Installer-Helfer fest.
collision_root="$work/collision"
mkdir -p "$collision_root/TagExplosion.app"
printf 'current\n' > "$collision_root/TagExplosion.app/payload"
rm -f "$work/verify-count"
if PATH="$fake_bin:/usr/bin:/bin" \
    VERIFY_COUNT_FILE="$work/verify-count" \
    /bin/bash -c '
        helper=$1; source=$2; destination=$3
        parent=$(dirname "$destination"); name=$(basename "$destination")
        old="$parent/.$name.old.$$"
        mkdir -p "$old"
        printf "preserved\n" > "$old/payload"
        exec "$helper" "$source" "$destination"
    ' _ "$root/scripts/install-verified-app.sh" "$new_source" \
        "$collision_root/TagExplosion.app"; then
    echo "FEHLER: vorhandener Rollback-Pfad meldete Erfolg" >&2
    exit 1
fi
assert_text current "$collision_root/TagExplosion.app"
collision_backup=$(find "$collision_root" -maxdepth 1 -name '.TagExplosion.app.old.*' -print)
[ -n "$collision_backup" ]
assert_text preserved "$collision_backup"

# Zwei gleichzeitige Installationen auf dasselbe Ziel: Der zweite Lauf muss
# abbrechen, ohne irgendetwas anzufassen — sonst könnte er dem ersten die App
# unter den Händen wegräumen oder sein Bundle ins Ziel hineinverschachteln.
concurrent_root="$work/concurrent"
mkdir -p "$concurrent_root/TagExplosion.app"
printf 'old\n' > "$concurrent_root/TagExplosion.app/payload"
rm -f "$work/verify-count" "$work/release"
BLOCK_SPCTL_CALL=1 RELEASE_FILE="$work/release" \
    run_installer "$new_source" "$concurrent_root/TagExplosion.app" &
first_installer=$!
note_background "$first_installer"
# Warten, bis der erste Lauf die Sperre hält (der Symlink entsteht atomar
# mitsamt Besitzer) und die blockierende spctl-Attrappe ihren Haltepunkt
# erreicht hat.
lock_held_and_blocked() {
    [ -L "$concurrent_root/.TagExplosion.app.lock" ] \
        && [ "$(cat "$work/verify-count" 2>/dev/null)" = "1" ]
}
wait_for "erster Lauf hat keine Sperre angelegt" lock_held_and_blocked
second_output="$work/second.log"
if run_installer "$new_source" "$concurrent_root/TagExplosion.app" \
    > "$second_output" 2>&1; then
    echo "FEHLER: zweite gleichzeitige Installation meldete Erfolg" >&2
    exit 1
fi
grep -q "andere Installation" "$second_output" || {
    echo "FEHLER: zweiter Lauf brach aus einem anderen Grund ab:" >&2
    cat "$second_output" >&2
    exit 1
}
# Der erste Lauf muss unbeschadet zu Ende laufen können.
touch "$work/release"
wait "$first_installer"
assert_text new "$concurrent_root/TagExplosion.app"
[ -z "$(find "$concurrent_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Ein Signal mitten im Rollback — zwischen "Ersatz entfernt" und "gute Fassung
# zurück" — darf die Installation nicht ohne App am Ziel zurücklassen.
signal_root="$work/signal"
mkdir -p "$signal_root/TagExplosion.app"
printf 'old\n' > "$signal_root/TagExplosion.app/payload"
rm -f "$work/verify-count"
if FAIL_SPCTL_CALL=2 SIGNAL_ON_RM_OF="$signal_root/TagExplosion.app" \
    run_installer "$new_source" "$signal_root/TagExplosion.app"; then
    echo "FEHLER: abgelehntes Update meldete trotz Signal Erfolg" >&2
    exit 1
fi
assert_text old "$signal_root/TagExplosion.app"

# Eine verwaiste Sperre (abgestürzter Lauf) darf spätere Installationen nicht
# dauerhaft blockieren.
stale_root="$work/stale"
mkdir -p "$stale_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$stale_root/.TagExplosion.app.lock"
rm -f "$work/verify-count"
run_installer "$new_source" "$stale_root/TagExplosion.app"
assert_text new "$stale_root/TagExplosion.app"
[ -z "$(find "$stale_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Eine wiederverwendete PID (lebender Prozess, aber andere Startzeit) zählt
# NICHT als aktiver Installer — sonst blockierte ein Absturz Updates für die
# gesamte Laufzeit eines unbeteiligten Prozesses.
reuse_root="$work/pid-reuse"
mkdir -p "$reuse_root"
ln -s "$$|Mon Jan  1 00:00:00 2001" "$reuse_root/.TagExplosion.app.lock"
rm -f "$work/verify-count"
run_installer "$new_source" "$reuse_root/TagExplosion.app"
assert_text new "$reuse_root/TagExplosion.app"
[ -z "$(find "$reuse_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Altformat-Sperren früherer Skriptfassungen (mkdir-Verzeichnis mit
# owner-Datei bzw. besitzerlos nach Absturz im Initialisierungsfenster)
# werden weiterhin erkannt und übernommen.
legacy_root="$work/legacy-lock"
mkdir -p "$legacy_root/.TagExplosion.app.lock"
printf '999999|Mon Jan  1 00:00:00 2001\n' > "$legacy_root/.TagExplosion.app.lock/owner"
rm -f "$work/verify-count"
run_installer "$new_source" "$legacy_root/TagExplosion.app"
assert_text new "$legacy_root/TagExplosion.app"
[ -z "$(find "$legacy_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

headless_root="$work/headless-lock"
mkdir -p "$headless_root/.TagExplosion.app.lock"
rm -f "$work/verify-count"
run_installer "$new_source" "$headless_root/TagExplosion.app"
assert_text new "$headless_root/TagExplosion.app"
[ -z "$(find "$headless_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Wettlauf 1 — Anwärter wartet am BELEGTEN Hilfslock: Ein "Nachfolger" ersetzt
# die tote Sperre durch eine lebende, während der Anwärter noch gar keinen
# Zugriff auf die Übernahme hat. Danach muss er die lebende Sperre in der
# äußeren Schleife erkennen und abbrechen, statt sie zu stehlen.
# (Die innere Prüfung nach eigenem Hilfslock-Erwerb erreicht dieser Fall
# ausdrücklich NICHT — dafür gibt es Wettlauf 2 weiter unten.)
race_root="$work/takeover-race"
mkdir -p "$race_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$race_root/.TagExplosion.app.lock"
# Das belegte Hilfslock hält jede Übernahme auf, bis wir es freigeben. Es trägt
# jetzt selbst einen LEBENDEN Besitzer (diese Shell) — ein besitzerloses
# Verzeichnis wäre nach 60 s verdrängbar und genau das war der Fehler.
ln -s "$$|$(ps -o lstart= -p $$ | head -n 1)" "$race_root/.TagExplosion.app.lock.takeover"
rm -f "$work/verify-count"
race_output="$work/takeover-race.log"
race_marker="$work/takeover-race.waiting"
rm -f "$race_marker"
TAKEOVER_WAIT_MARKER="$race_marker" \
run_installer "$new_source" "$race_root/TagExplosion.app" \
    > "$race_output" 2>&1 &
race_installer=$!
note_background "$race_installer"
# Erst weitermachen, wenn der Anwärter das Hilfslock nachweislich gelesen hat.
wait_for_file "$race_marker" "Anwärter erreichte das Übernahme-Hilfslock nicht"
# "Nachfolger": tote Sperre ATOMAR gegen eine lebende (unsere Shell)
# tauschen — ein rm+ln-Fenster würde der wartende Anwärter sofort selbst
# mit claim_lock füllen. Erst danach die Übernahme freigeben.
ln -s "$$|$(ps -o lstart= -p $$ | head -n 1)" "$race_root/.live-lock"
/bin/mv "$race_root/.live-lock" "$race_root/.TagExplosion.app.lock"
rm -f "$race_root/.TagExplosion.app.lock.takeover"
if wait "$race_installer"; then
    echo "FEHLER: Anwärter hat eine lebende Sperre gestohlen" >&2
    exit 1
fi
grep -q "andere Installation" "$race_output" || {
    echo "FEHLER: Anwärter brach aus einem anderen Grund ab:" >&2
    cat "$race_output" >&2
    exit 1
}
[ -L "$race_root/.TagExplosion.app.lock" ] || {
    echo "FEHLER: die lebende Sperre wurde entfernt" >&2
    exit 1
}
[ ! -e "$race_root/TagExplosion.app" ] || {
    echo "FEHLER: Anwärter hat trotz fremder Sperre installiert" >&2
    exit 1
}
rm -f "$race_root/.TagExplosion.app.lock"

# Wettlauf 2 — Anwärter hält das Hilfslock BEREITS: Genau dann greift die
# erneute Besitzerprüfung im gegenseitigen Ausschluss (install-verified-app.sh,
# takeover_stale_lock). Der readlink-Stub hält den Anwärter erst an, nachdem er
# das Hilfslock erworben und seinen Besitz bestätigt hat; erst dann wird die
# tote Hauptsperre gegen eine lebende getauscht. Ohne die innere Prüfung würde
# er die lebende Sperre jetzt entfernen und installieren.
inner_root="$work/takeover-inner"
mkdir -p "$inner_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$inner_root/.TagExplosion.app.lock"
rm -f "$work/verify-count"
inner_output="$work/takeover-inner.log"
inner_marker="$work/takeover-inner.waiting"
inner_release="$work/takeover-inner.release"
rm -f "$inner_marker" "$inner_marker.takeover-seen" "$inner_marker.done" "$inner_release"
LOCK_READ_BLOCK_MARKER="$inner_marker" \
LOCK_READ_BLOCK_RELEASE="$inner_release" \
run_installer "$new_source" "$inner_root/TagExplosion.app" \
    > "$inner_output" 2>&1 &
inner_installer=$!
note_background "$inner_installer"
wait_for_file "$inner_marker" "Anwärter erreichte die innere Besitzerprüfung nicht"
# Beweis, dass wirklich der innere Pfad erreicht ist: Das Hilfslock gehört ihm.
[ -L "$inner_root/.TagExplosion.app.lock.takeover" ] || {
    echo "FEHLER: Anwärter hält das Übernahme-Hilfslock nicht" >&2
    exit 1
}
# Tote Sperre atomar gegen eine lebende (unsere Shell) tauschen, dann freigeben.
ln -s "$$|$(ps -o lstart= -p $$ | head -n 1)" "$inner_root/.live-lock"
/bin/mv "$inner_root/.live-lock" "$inner_root/.TagExplosion.app.lock"
: > "$inner_release"
if wait "$inner_installer"; then
    echo "FEHLER: Anwärter hat trotz innerer Prüfung eine lebende Sperre übernommen" >&2
    exit 1
fi
grep -q "andere Installation" "$inner_output" || {
    echo "FEHLER: Anwärter brach aus einem anderen Grund ab:" >&2
    cat "$inner_output" >&2
    exit 1
}
[ -L "$inner_root/.TagExplosion.app.lock" ] || {
    echo "FEHLER: die lebende Sperre wurde entfernt" >&2
    exit 1
}
[ ! -e "$inner_root/TagExplosion.app" ] || {
    echo "FEHLER: Anwärter hat trotz fremder Sperre installiert" >&2
    exit 1
}
# -L UND -e: Das Hilfslock ist ein Symlink auf "PID|Startzeit", also ein
# BAUMELNDER Link. `-e` folgt dem Link und ist deshalb immer falsch — die
# Zusicherung lief ins Leere (Review-Fund 2026-08-20).
[ ! -L "$inner_root/.TagExplosion.app.lock.takeover" ] \
    && [ ! -e "$inner_root/.TagExplosion.app.lock.takeover" ] || {
    echo "FEHLER: das Übernahme-Hilfslock blieb liegen" >&2
    exit 1
}
rm -f "$inner_root/.TagExplosion.app.lock"

# Ein verwaistes Übernahme-Hilfslock (Absturz mitten in der Übernahme) darf
# nicht ewig blockieren: Nach Ablauf der Frist wird es weggeräumt.
old_tko_root="$work/stale-takeover"
mkdir -p "$old_tko_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$old_tko_root/.TagExplosion.app.lock"
# Besitzerloses Altformat-Verzeichnis: Genau das darf nach Fristablauf weg.
mkdir "$old_tko_root/.TagExplosion.app.lock.takeover"
touch -t 202001010000 "$old_tko_root/.TagExplosion.app.lock.takeover"
rm -f "$work/verify-count"
run_installer "$new_source" "$old_tko_root/TagExplosion.app"
assert_text new "$old_tko_root/TagExplosion.app"
[ -z "$(find "$old_tko_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Ein Sperrbesitzer, dem dieser Benutzer kein Signal schicken darf, gilt
# trotzdem als LEBEND. `kill -0` liefert dafuer EPERM, und der Code hielt ihn
# frueher fuer tot — zwei Benutzer mit Schreibrecht am selben Ziel konnten
# dadurch gleichzeitig installieren (Review-Fund 2026-08-17).
# Kein Stub noetig: PID 1 (launchd) gehoert root, existiert immer, und `ps`
# sieht sie. Ein Stub waere hier ohnehin wirkungslos, weil `kill` ein
# Shell-Builtin ist und nicht aus dem PATH kommt.
eperm_root="$work/eperm-owner"
mkdir -p "$eperm_root"
if [ "$(id -u)" -eq 0 ]; then
    echo "Hinweis: als root uebersprungen — jedes Signal ist erlaubt." >&2
else
    ln -s "1|$(ps -o lstart= -p 1 | head -n 1)" "$eperm_root/.TagExplosion.app.lock"
    rm -f "$work/verify-count"
    eperm_output="$work/eperm.log"
    if run_installer "$new_source" "$eperm_root/TagExplosion.app" \
            > "$eperm_output" 2>&1; then
        echo "FEHLER: Sperre eines nicht signalisierbaren Besitzers wurde uebergangen" >&2
        exit 1
    fi
    grep -q "andere Installation" "$eperm_output" || {
        echo "FEHLER: falscher Abbruchgrund beim nicht signalisierbaren Besitzer:" >&2
        cat "$eperm_output" >&2
        exit 1
    }
    [ ! -e "$eperm_root/TagExplosion.app" ] || {
        echo "FEHLER: trotz lebender fremder Sperre installiert" >&2
        exit 1
    }
    rm -f "$eperm_root/.TagExplosion.app.lock"
fi

echo "Installer-Rollback-Tests: OK"

#!/usr/bin/env bash
# Regressionen fuer den Installer-Austausch. Alle Ziele liegen unter mktemp;
# /Applications wird weder gelesen noch beschrieben.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=./shell-test-support.sh
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-install-tests)
trap 'rm -rf -- "$work"' EXIT
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
    while [ ! -f "${RELEASE_FILE:-/nonexistent}" ]; do sleep 0.05; done
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

run_installer() {
    local source=$1 destination=$2
    PATH="$fake_bin:/usr/bin:/bin" \
        VERIFY_COUNT_FILE="$work/verify-count" \
        FAIL_SPCTL_CALL="${FAIL_SPCTL_CALL:-0}" \
        FAIL_ROLLBACK="${FAIL_ROLLBACK:-0}" \
        BLOCK_SPCTL_CALL="${BLOCK_SPCTL_CALL:-0}" \
        RELEASE_FILE="${RELEASE_FILE:-}" \
        SIGNAL_ON_RM_OF="${SIGNAL_ON_RM_OF:-}" \
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
# Warten, bis der erste Lauf die Sperre VOLLSTÄNDIG hält (owner-Datei
# veröffentlicht) und die blockierende spctl-Attrappe ihren Haltepunkt
# erreicht hat. Nur auf das Sperr-Verzeichnis zu warten träfe genau das
# Initialisierungsfenster zwischen mkdir und owner-Write.
for _ in $(seq 1 200); do
    [ -f "$concurrent_root/.TagExplosion.app.lock/owner" ] \
        && [ "$(cat "$work/verify-count" 2>/dev/null)" = "1" ] && break
    sleep 0.05
done
[ -f "$concurrent_root/.TagExplosion.app.lock/owner" ] || {
    echo "FEHLER: erster Lauf hat keine vollständige Sperre angelegt" >&2
    exit 1
}
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
mkdir -p "$stale_root/.TagExplosion.app.lock"
printf '999999|Mon Jan  1 00:00:00 2001\n' > "$stale_root/.TagExplosion.app.lock/owner"
rm -f "$work/verify-count"
run_installer "$new_source" "$stale_root/TagExplosion.app"
assert_text new "$stale_root/TagExplosion.app"
[ -z "$(find "$stale_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Eine wiederverwendete PID (lebender Prozess, aber andere Startzeit) zählt
# NICHT als aktiver Installer — sonst blockierte ein Absturz Updates für die
# gesamte Laufzeit eines unbeteiligten Prozesses.
reuse_root="$work/pid-reuse"
mkdir -p "$reuse_root/.TagExplosion.app.lock"
printf '%s|Mon Jan  1 00:00:00 2001\n' "$$" > "$reuse_root/.TagExplosion.app.lock/owner"
rm -f "$work/verify-count"
run_installer "$new_source" "$reuse_root/TagExplosion.app"
assert_text new "$reuse_root/TagExplosion.app"
[ -z "$(find "$reuse_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

# Absturz genau zwischen mkdir und owner-Write: Die besitzerlose Sperre wird
# nach der Wartefrist übernommen, statt für immer zu blockieren.
headless_root="$work/headless-lock"
mkdir -p "$headless_root/.TagExplosion.app.lock"
rm -f "$work/verify-count"
run_installer "$new_source" "$headless_root/TagExplosion.app"
assert_text new "$headless_root/TagExplosion.app"
[ -z "$(find "$headless_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

echo "Installer-Rollback-Tests: OK"

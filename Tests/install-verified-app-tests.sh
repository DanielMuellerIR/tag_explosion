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
# Warten, bis der erste Lauf die Sperre hält (der Symlink entsteht atomar
# mitsamt Besitzer) und die blockierende spctl-Attrappe ihren Haltepunkt
# erreicht hat.
for _ in $(seq 1 200); do
    [ -L "$concurrent_root/.TagExplosion.app.lock" ] \
        && [ "$(cat "$work/verify-count" 2>/dev/null)" = "1" ] && break
    sleep 0.05
done
[ -L "$concurrent_root/.TagExplosion.app.lock" ] || {
    echo "FEHLER: erster Lauf hat keine Sperre angelegt" >&2
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

# Die Übernahme einer toten Sperre muss den Besitzer im AUSSCHLUSS erneut
# prüfen: Hier ersetzt ein "Nachfolger" die tote Sperre durch eine lebende,
# während der Anwärter am Übernahme-Hilfslock wartet. Der Anwärter darf die
# lebende Sperre danach nicht stehlen, sondern muss sauber abbrechen.
race_root="$work/takeover-race"
mkdir -p "$race_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$race_root/.TagExplosion.app.lock"
# Das belegte Hilfslock hält jede Übernahme auf, bis wir es freigeben.
mkdir "$race_root/.TagExplosion.app.lock.takeover"
rm -f "$work/verify-count"
race_output="$work/takeover-race.log"
run_installer "$new_source" "$race_root/TagExplosion.app" \
    > "$race_output" 2>&1 &
race_installer=$!
sleep 0.5
# "Nachfolger": tote Sperre ATOMAR gegen eine lebende (unsere Shell)
# tauschen — ein rm+ln-Fenster würde der wartende Anwärter sofort selbst
# mit claim_lock füllen. Erst danach die Übernahme freigeben.
ln -s "$$|$(ps -o lstart= -p $$ | head -n 1)" "$race_root/.live-lock"
/bin/mv "$race_root/.live-lock" "$race_root/.TagExplosion.app.lock"
rmdir "$race_root/.TagExplosion.app.lock.takeover"
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

# Ein verwaistes Übernahme-Hilfslock (Absturz mitten in der Übernahme) darf
# nicht ewig blockieren: Nach Ablauf der Frist wird es weggeräumt.
old_tko_root="$work/stale-takeover"
mkdir -p "$old_tko_root"
ln -s '999999|Mon Jan  1 00:00:00 2001' "$old_tko_root/.TagExplosion.app.lock"
mkdir "$old_tko_root/.TagExplosion.app.lock.takeover"
touch -t 202001010000 "$old_tko_root/.TagExplosion.app.lock.takeover"
rm -f "$work/verify-count"
run_installer "$new_source" "$old_tko_root/TagExplosion.app"
assert_text new "$old_tko_root/TagExplosion.app"
[ -z "$(find "$old_tko_root" -maxdepth 1 -name '.TagExplosion.app.*' -print)" ]

echo "Installer-Rollback-Tests: OK"

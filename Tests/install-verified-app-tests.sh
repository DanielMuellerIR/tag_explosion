#!/usr/bin/env bash
# Regressionen fuer den Installer-Austausch. Alle Ziele liegen unter mktemp;
# /Applications wird weder gelesen noch beschrieben.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tagx-install-tests.XXXXXX")
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
[ "${FAIL_SPCTL_CALL:-0}" -ne "$count" ]
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

echo "Installer-Rollback-Tests: OK"

#!/usr/bin/env bash
# Regressionen fuer die Mindestversions-Pruefung des Release-Builds.
# `file` und `xcrun vtool` werden durch Attrappen ersetzt, damit die Faelle
# ohne echte Mach-O-Dateien und ohne Xcode-Installation pruefbar sind.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=./shell-test-support.sh
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-minimums-tests)
trap 'rm -rf -- "$work"' EXIT
fake_bin="$work/bin"
mkdir -p "$fake_bin"

# Jede Datei gilt als Mach-O; die Unterscheidung ist hier nicht der Prüfgegenstand.
cat > "$fake_bin/file" <<'SH'
#!/usr/bin/env bash
printf 'Mach-O 64-bit executable arm64\n'
SH

# vtool-Attrappe: VTOOL_MODE steuert, was gemeldet wird.
cat > "$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
case "${VTOOL_MODE:-ok}" in
    ok)      printf 'Load command 1\n  cmd LC_BUILD_VERSION\n  minos 14.0\n  sdk 14.0\n' ;;
    new)     printf 'Load command 1\n  cmd LC_BUILD_VERSION\n  minos 26.0\n  sdk 26.0\n' ;;
    nominos) printf 'Load command 1\n  cmd LC_VERSION_MIN_MACOSX\n' ;;
    fat)     printf 'architecture arm64\n  minos 14.0\narchitecture x86_64\n  minos 26.0\n' ;;
    fail)    printf 'vtool: kaputt\n' >&2; exit 1 ;;
esac
SH
chmod +x "$fake_bin"/*

make_bundle() {
    local bundle=$1
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks"
    printf 'binary\n' > "$bundle/Contents/MacOS/TagExplosion"
    cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST
}

run_check() {
    local bundle=$1
    PATH="$fake_bin:/usr/bin:/bin" VTOOL_MODE="${VTOOL_MODE:-ok}" \
        "$root/scripts/verify-macos-minimums.sh" "$bundle"
}

expect_failure() {
    local label=$1 bundle=$2 output
    if output=$(run_check "$bundle" 2>&1); then
        echo "FEHLER: $label wurde durchgewunken" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
    if printf '%s\n' "$output" | grep -q 'MINIMUM SYSTEM OK'; then
        echo "FEHLER: $label meldete trotzdem MINIMUM SYSTEM OK" >&2
        exit 1
    fi
}

bundle="$work/TagExplosion.app"
make_bundle "$bundle"

# Passende Mindestversion: geht durch.
VTOOL_MODE=ok run_check "$bundle" | grep -q 'MINIMUM SYSTEM OK'

# Zu neu gebautes Mach-O: muss auffallen.
VTOOL_MODE=new expect_failure "zu neues Mach-O" "$bundle"

# Universal-Binary, erst der ZWEITE Slice ist zu neu. Frueher endete die
# Auswertung nach dem ersten minos-Wert.
VTOOL_MODE=fat expect_failure "zweiter Architektur-Slice" "$bundle"

# vtool selbst scheitert: ungeprueft ist nicht in Ordnung.
VTOOL_MODE=fail expect_failure "vtool-Fehler" "$bundle"

# Keine Mindestversion in der Ausgabe: ebenfalls ablehnen.
VTOOL_MODE=nominos expect_failure "fehlende minos-Angabe" "$bundle"

# Fehlendes Verzeichnis: `find` scheitert und darf nicht folgenlos bleiben.
broken="$work/Broken.app"
make_bundle "$broken"
rm -rf "$broken/Contents/Frameworks"
VTOOL_MODE=ok expect_failure "fehlendes Frameworks-Verzeichnis" "$broken"

# Bundle ganz ohne Mach-O: Null geprueft ist kein Erfolg.
empty="$work/Empty.app"
make_bundle "$empty"
rm -f "$empty/Contents/MacOS/TagExplosion"
VTOOL_MODE=ok expect_failure "Bundle ohne Mach-O" "$empty"

echo "Mindestversions-Tests: OK"

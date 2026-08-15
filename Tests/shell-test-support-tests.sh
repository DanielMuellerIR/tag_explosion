#!/usr/bin/env bash
# Regressionen für die gemeinsame Auswahl eines temporären Testordners.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=./shell-test-support.sh
. "$root/Tests/shell-test-support.sh"

custom_parent=$(/usr/bin/mktemp -d /tmp/tagx-shell-support-parent.XXXXXX)
first=
second=
cleanup() {
    [ -z "$first" ] || rm -rf -- "$first"
    [ -z "$second" ] || rm -rf -- "$second"
    rm -rf -- "$custom_parent"
}
trap cleanup EXIT

# Ein gültiges TMPDIR wird weiterhin respektiert.
first=$(TMPDIR="$custom_parent" tagx_make_test_workdir tagx-shell-support-valid)
case "$first" in
    "$custom_parent"/*) ;;
    *) echo "FEHLER: gültiges TMPDIR wurde nicht verwendet: $first" >&2; exit 1 ;;
esac

# Ein gesetztes, aber fehlendes TMPDIR fällt kontrolliert auf /tmp zurück.
missing_parent="$custom_parent/nicht-vorhanden"
second=$(TMPDIR="$missing_parent" tagx_make_test_workdir tagx-shell-support-fallback)
case "$second" in
    /tmp/*) ;;
    *) echo "FEHLER: ungültiges TMPDIR ergab keinen /tmp-Pfad: $second" >&2; exit 1 ;;
esac

echo "Shell-Test-Tempordner: OK"

#!/usr/bin/env bash
# Führt den echten DMG-Abschnitt mit Werkzeugattrappen aus. Die Attrappen
# schreiben ausschließlich ins Testverzeichnis; /Volumes bleibt unangetastet.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-dmg-ownership)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/app" "$work/source"
awk '/^echo "== DMG bauen =="/ { emit=1 } /^# f\)/ { emit=0 } emit' \
    "$root/build.sh" > "$work/dmg-section.sh"
[ -s "$work/dmg-section.sh" ]
cat > "$work/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
here="$TEST_WORK/source"
app="$TEST_WORK/app"
version=0.0.0
finder_layout=0
uuidgen() { printf 'OWNED-TEST-UUID\n'; }
mktemp() { /usr/bin/mktemp -d "$TEST_WORK/staging.XXXXXX"; }
swift() { [ "$TEST_MODE" != before_mount ] || return 71; touch "$2"; }
sips() { :; }
tiffutil() { touch "${@: -1}"; }
chflags() { :; }
sync() { :; }
sleep() { :; }
mkdir() { case "${*: -1}" in /Volumes/*) : ;; *) command mkdir "$@" ;; esac; }
ln() { :; }
cp() {
    if [ "$TEST_MODE" = signal_failure ]; then kill -TERM "$$"; return 72; fi
    [ "$TEST_MODE" != copy_failure ] && [ "$TEST_MODE" != detach_failure ]
}
hdiutil() {
    printf '%s\n' "$*" >> "$TEST_WORK/$TEST_MODE.calls"
    case "$1" in
        create) touch "${@: -1}" ;;
        attach) [ "$TEST_MODE" != attach_failure ] ;;
        detach) [ "$TEST_MODE" != detach_failure ] ;;
        convert) touch "${@: -1}" ;;
        *) return 73 ;;
    esac
}
. "$TEST_WORK/dmg-section.sh"
RUNNER

run_case() {
    local mode=$1 expected=$2 status=0
    TEST_WORK="$work" TEST_MODE="$mode" bash "$work/runner.sh" \
        > "$work/$mode.log" 2>&1 || status=$?
    if [ "$expected" = success ]; then
        [ "$status" = 0 ] || { cat "$work/$mode.log"; exit 1; }
    else
        [ "$status" != 0 ] || { echo "FEHLER: $mode meldet Erfolg" >&2; exit 1; }
    fi
    if [ -f "$work/$mode.calls" ]; then
        # Kein Fehlerpfad darf ein fremdes, gleichnamiges Volume aushängen.
        if grep '^detach /Volumes/Tag Explosion -' "$work/$mode.calls" >/dev/null; then
            echo "FEHLER: fremdes Volume erreicht detach" >&2; exit 1
        fi
        while IFS= read -r line; do
            case "$line" in
                detach*) [[ "$line" == 'detach /Volumes/Tag Explosion-OWNED-TEST-UUID '* ]] ;;
            esac
        done < "$work/$mode.calls"
    fi
}
run_case before_mount failure
[ ! -e "$work/before_mount.calls" ]
run_case attach_failure failure
run_case copy_failure failure
run_case signal_failure failure
run_case success success
# Nur ein fehlgeschlagenes Aushängen behält seine eigenen Arbeitsdaten.
[ -z "$(find "$work" -maxdepth 1 -type d -name 'staging.*' -print)" ]
run_case detach_failure failure
[ -n "$(find "$work" -maxdepth 1 -type d -name 'staging.*' -print)" ]
grep 'Arbeitsdaten bleiben' "$work/detach_failure.log" >/dev/null
echo "DMG-Besitztests: OK"

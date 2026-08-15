#!/usr/bin/env bash
# Regressionen fuer scripts/taglib-refs.sh: Ladepfade auslesen, umbiegen,
# pruefen. otool und install_name_tool sind Attrappen — geprueft wird die
# Auswertung, nicht Apples Werkzeuge.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=./shell-test-support.sh
. "$root/Tests/shell-test-support.sh"
work=$(tagx_make_test_workdir tagx-taglib-refs-tests)
trap 'rm -rf -- "$work"' EXIT
fake_bin="$work/bin"
mkdir -p "$fake_bin"

# otool-Attrappe: Die Ausgabe steht in der Datei, deren Name in OTOOL_FIXTURE
# steht. OTOOL_FAIL=1 laesst sie scheitern.
cat > "$fake_bin/otool" <<'SH'
#!/usr/bin/env bash
if [ "${OTOOL_FAIL:-0}" -eq 1 ]; then
    echo "otool: kann Datei nicht lesen" >&2
    exit 1
fi
cat "$OTOOL_FIXTURE"
SH

# install_name_tool-Attrappe: protokolliert Argumentanzahl und jedes Argument
# einzeln (Tab-getrennt). "$*" wuerde Argumentgrenzen verwischen — ein
# unquotierter Pfad mit Leerzeichen ergaebe dieselbe Zeile wie die korrekt
# uebergebenen Argumente, und genau diese Regression soll Test 1 fangen.
cat > "$fake_bin/install_name_tool" <<'SH'
#!/usr/bin/env bash
{ printf '%s' "$#"; printf '\t%s' "$@"; printf '\n'; } >> "$INSTALL_NAME_LOG"
SH
chmod +x "$fake_bin"/*

export PATH="$fake_bin:/usr/bin:/bin"
export OTOOL_FIXTURE="$work/otool-out.txt"
export INSTALL_NAME_LOG="$work/install-name.log"
export OTOOL_FAIL=0

# shellcheck source=../scripts/taglib-refs.sh
. "$root/scripts/taglib-refs.sh"

fail() { echo "FEHLER: $1" >&2; exit 1; }

# 1) Build-Pfad mit Leerzeichen: Der Ladepfad muss ganz bleiben. Frueher
#    zerlegte awk ihn am ersten Leerzeichen und bog gar nichts um.
spaced="/Users/tester/Mein Ordner/taglib/lib/libtag_c.2.dylib"
cat > "$OTOOL_FIXTURE" <<EOF
/pfad/zur/TagExplosion:
	$spaced (compatibility version 2.0.0, current version 2.0.1)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
EOF
: > "$INSTALL_NAME_LOG"
rewrite_taglib_refs "/pfad/zur/TagExplosion" || fail "rewrite schlug fehl"
# Genau vier Argumente, jedes einzeln — der Pfad mit Leerzeichen als EIN Argument.
expected=$(printf '%s\t%s\t%s\t%s\t%s' 4 "-change" "$spaced" \
    "@executable_path/../Frameworks/libtag_c.2.dylib" "/pfad/zur/TagExplosion")
[ "$(cat "$INSTALL_NAME_LOG")" = "$expected" ] \
    || fail "Ladepfad mit Leerzeichen wurde nicht als Ganzes umgebogen: $(cat "$INSTALL_NAME_LOG")"

# 2) otool-Fehler darf nicht als "keine Abhaengigkeiten" durchgehen.
OTOOL_FAIL=1
if dylib_deps "/pfad/zur/TagExplosion" >/dev/null 2>&1; then
    fail "otool-Fehler wurde verschluckt"
fi
OTOOL_FAIL=0

# 3) Ein Verweis, der nach dem Umbiegen weiterhin nach draussen zeigt.
cat > "$OTOOL_FIXTURE" <<'EOF'
/pfad/zur/TagExplosion:
	/opt/homebrew/opt/taglib/lib/libtag_c.2.dylib (compatibility version 2.0.0, current version 2.0.1)
EOF
if verify_taglib_refs "/pfad/zur/TagExplosion" 1 >/dev/null 2>&1; then
    fail "externer TagLib-Verweis wurde akzeptiert"
fi

# 4) Alles im Bundle: geht durch.
cat > "$OTOOL_FIXTURE" <<'EOF'
/pfad/zur/TagExplosion:
	@executable_path/../Frameworks/libtag_c.2.dylib (compatibility version 2.0.0, current version 2.0.1)
	@executable_path/../Frameworks/libtag.2.dylib (compatibility version 2.0.0, current version 2.0.1)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
EOF
verify_taglib_refs "/pfad/zur/TagExplosion" 1 || fail "gueltige Bundle-Verweise wurden abgelehnt"

# 5) Bei einer dylib nennt otool in Zeile 2 ihre eigene Install-ID. Sie zaehlt
#    nicht als Abhaengigkeit — sonst ginge eine libtag_c ohne jeden Verweis auf
#    libtag als "hat einen TagLib-Verweis" durch.
cat > "$OTOOL_FIXTURE" <<'EOF'
/bundle/libtag_c.2.dylib:
	@executable_path/../Frameworks/libtag_c.2.dylib (compatibility version 2.0.0, current version 2.3.0)
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
EOF
if verify_taglib_refs "/bundle/libtag_c.2.dylib" 1 >/dev/null 2>&1; then
    fail "eigene Install-ID wurde als TagLib-Verweis gezaehlt"
fi
[ "$(dylib_deps "/bundle/libtag_c.2.dylib")" = "/usr/lib/libSystem.B.dylib" ] \
    || fail "Install-ID-Zeile landete in den Abhaengigkeiten"

# 6) Gar kein TagLib-Verweis erkannt: Das ist ein Fehler, kein Erfolg.
cat > "$OTOOL_FIXTURE" <<'EOF'
/pfad/zur/TagExplosion:
	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
EOF
if verify_taglib_refs "/pfad/zur/TagExplosion" 1 >/dev/null 2>&1; then
    fail "fehlender TagLib-Verweis wurde als Erfolg gewertet"
fi
# Ohne Mindestanforderung (libtag selbst) bleibt derselbe Stand in Ordnung.
verify_taglib_refs "/pfad/zur/TagExplosion" 0 || fail "Datei ohne TagLib-Verweis abgelehnt"

echo "TagLib-Ladepfad-Tests: OK"

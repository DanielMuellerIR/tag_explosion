#!/usr/bin/env bash
# Tag Explosion — notarisierten Build erzeugen und nach /Applications installieren.
#
# Baut CLI und App als Release, bündelt TagLib und Sparkle, signiert mit
# Developer ID und Hardened Runtime, notarisiert bei Apple, heftet das Ticket
# ans Bundle und installiert es. Danach startet die App ohne Gatekeeper-
# Rückfrage, auch auf einem anderen Mac.
#
# Nach /Applications wandert ausschließlich ein nachweislich notarisiertes
# Bundle: Stapler, Gatekeeper und Signatur werden vor dem Kopieren geprüft.
# Ein nur signierter Test-Build (--no-notarize) bleibt im Projektordner.
#
# Aufruf:
#   ./install.sh                          # Notary-Profil aus git config/Abfrage
#   NOTARY_PROFILE=<profil> ./install.sh  # Profil für diesen Lauf
#   ./install.sh --no-notarize            # schneller Testbau, ohne Installation
#
# Das notarytool-Profil ist pro Mac lokal (kein iCloud-Sync). Beim ersten Lauf
# auf einem neuen Mac fragt das Skript danach und richtet es auf Wunsch ein.
#
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   INSTALL OK: /Applications/TagExplosion.app (<version>)

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

NOTARIZE=1
for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        *) echo "Unbekannte Option: $arg" >&2
           echo "Aufruf: ./install.sh [--no-notarize]" >&2; exit 2 ;;
    esac
done

version="$(tr -d '[:space:]' < "$here/VERSION")"
app="$here/TagExplosion.app"
dest="/Applications/TagExplosion.app"

if [ "$NOTARIZE" -eq 0 ]; then
    # Nur bauen und ad-hoc signieren — bleibt bewusst im Projektordner.
    ./build.sh
    echo
    echo "BUILD OK: $app ($version, nicht notarisiert — nicht für /Applications)"
    exit 0
fi

# Das Profil vor dem teuren Build klären.
# shellcheck source=scripts/notary-profile.sh
source "$here/scripts/notary-profile.sh"
tagx_require_notary_profile

# Baut, bündelt, signiert, notarisiert und stapelt die App (ohne DMG).
./build.sh --release --no-dmg

# Vor dem Kopieren beweisen, dass das Bundle wirklich notarisiert ist.
echo "== Prüfe das Bundle vor der Installation =="
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# Eine laufende Instanz würde beim Kopieren ein offenes Binary treffen.
if pgrep -x TagExplosion >/dev/null 2>&1; then
    echo "== Beende die laufende Instanz =="
    osascript -e 'tell application id "io.github.danielmuellerir.tagexplosion" to quit' \
        >/dev/null 2>&1 || true
    sleep 2
    pkill -x TagExplosion 2>/dev/null || true
fi

echo "== Installiere nach /Applications =="
rm -rf "$dest"
ditto "$app" "$dest"

# Dieselben Prüfungen noch einmal am tatsächlich installierten Bundle: Erst das
# beweist, dass in /Applications eine gültige, notarisierte App liegt.
xcrun stapler validate "$dest"
spctl --assess --type execute --verbose=2 "$dest"
codesign --verify --deep --strict --verbose=2 "$dest"

echo
echo "INSTALL OK: $dest ($version)"

#!/usr/bin/env bash
# Tag Explosion — verteilbares DMG bauen (signiert, notarisiert, gestapelt).
#
# Ergebnis: TagExplosion-<version>.dmg mit Hintergrundbild, /Applications-
# Symlink und Finder-Layout. Die App im DMG ist notarisiert und gestapelt, das
# DMG selbst ebenfalls — es öffnet also auch offline ohne Gatekeeper-Warnung.
#
# Aufruf:
#   ./release.sh                          # Notary-Profil aus git config/Abfrage
#   NOTARY_PROFILE=<profil> ./release.sh  # Profil für diesen Lauf
#   ./release.sh --no-finder-layout       # headless (ohne AppleScript-Layout)
#
# Danach: GitHub-Release mit genau diesem DMG anlegen; der Workflow
# .github/workflows/publish-appcast.yml erzeugt daraus den signierten
# Sparkle-Feed. Ablauf im Detail: docs/sparkle-release.md.
#
# Letzte Zeile bei Erfolg (maschinenlesbar):
#   RELEASE OK: <pfad zum dmg>

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

extra_args=()
for arg in "$@"; do
    case "$arg" in
        --no-finder-layout) extra_args+=("$arg") ;;
        *) echo "Unbekannte Option: $arg" >&2
           echo "Aufruf: ./release.sh [--no-finder-layout]" >&2; exit 2 ;;
    esac
done

# shellcheck source=scripts/notary-profile.sh
source "$here/scripts/notary-profile.sh"
tagx_require_notary_profile

./build.sh --release "${extra_args[@]+"${extra_args[@]}"}"

version="$(tr -d '[:space:]' < "$here/VERSION")"
dmg="$here/TagExplosion-$version.dmg"
[ -f "$dmg" ] || { echo "✗ DMG fehlt: $dmg" >&2; exit 1; }

# Beweisen, dass das ausgelieferte DMG wirklich gestapelt ist.
xcrun stapler validate "$dmg"

echo
echo "RELEASE OK: $dmg"

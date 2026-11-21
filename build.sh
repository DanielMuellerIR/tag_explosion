#!/bin/sh
# Baut tagx (CLI) und TagExplosion.app (GUI). Headless, ohne Xcode-Projekt.
# Version kommt aus der VERSION-Datei. Optionen:
#   --cli-only   nur tagx bauen
#   --debug      Debug- statt Release-Build
#   --release    Distribution: TagLib-dylibs bündeln, Developer-ID-Signatur
#                (Hardened Runtime), Notarisierung + Stapling, verteilbares DMG.
#                Benötigt die Umgebungsvariable NOTARY_PROFILE
#                (notarytool-Keychain-Profil).
#   --no-finder-layout  DMG ohne AppleScript-Finder-Layout bauen (headless/CI;
#                das DMG funktioniert, das Fenster sieht nur schlichter aus).
#   --no-dmg     nur die notarisierte App erzeugen, kein DMG (nutzt install.sh).
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
if [ "$(uname -s)" = Linux ] || [ "${1:-}" = --linux ]; then
    if [ "${1:-}" = --linux ]; then shift; fi
    exec bash "$here/Linux/build.sh" "$@"
fi
version="$(tr -d '[:space:]' < "$here/VERSION")"
config="release"
cli_only=0
release=0
finder_layout=1
build_dmg=1
portable_taglib_root=""

for arg in "$@"; do
    case "$arg" in
        --cli-only) cli_only=1 ;;
        --debug) config="debug" ;;
        --release) release=1 ;;
        --no-finder-layout) finder_layout=0 ;;
        --no-dmg) build_dmg=0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
    esac
done

echo "== Tag Explosion $version ($config) =="

# Ein Release darf die aktuelle Homebrew-TagLib nicht blind übernehmen: Auf
# einem neueren Build-Mac kann deren eigenes LC_BUILD_VERSION neuer sein als
# das von der App versprochene macOS 14. Die gepinnte, verifizierte Flasche wird
# sowohl zum Übersetzen als auch zum Bündeln verwendet. Saubere SwiftPM-Builds
# verhindern, dass Objekte aus einem früheren Homebrew-Build wiederverwendet
# werden.
if [ "$release" = "1" ]; then
    portable_taglib_root="$("$here/scripts/prepare-portable-taglib.sh")"
    PKG_CONFIG_PATH="$portable_taglib_root/lib/pkgconfig"
    PKG_CONFIG_LIBDIR="$portable_taglib_root/lib/pkgconfig"
    DYLD_LIBRARY_PATH="$portable_taglib_root/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH PKG_CONFIG_LIBDIR DYLD_LIBRARY_PATH
    swift package --package-path "$here" clean
    swift package --package-path "$here/App" clean
fi

# 1) CLI + Core
swift build -c "$config" --package-path "$here"
echo "tagx: $here/.build/$config/tagx"

[ "$cli_only" = "1" ] && exit 0

# 2) App-Binary
swift build -c "$config" --package-path "$here/App"

# Bundle, Signatur und notarisiertes Distributionsimage sind getrennte Schritte.
sh "$here/scripts/bundle-macos-app.sh" "$here" "$config" "$version"
app="$here/TagExplosion.app"
. "$here/scripts/macos-signing.sh"

if [ "$release" = "0" ]; then
    tagx_sign_local_app "$here" "$app" "$config"
    echo "App: $app"
    exit 0
fi

identity="$(tagx_developer_id)"
echo "== Signiere als: $identity =="
tagx_sign_release_app "$here" "$app" "$portable_taglib_root" "$identity"
tagx_notarize_app "$app" "$here/TagExplosion-$version.zip"

if [ "$build_dmg" = "0" ]; then
    echo "App (notarisiert): $app"
    exit 0
fi
exec sh "$here/scripts/make-macos-dmg.sh" "$here" "$app" "$here/TagExplosion-$version.dmg" \
    "$finder_layout" "$identity"

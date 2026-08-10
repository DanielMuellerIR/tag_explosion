#!/bin/sh
# Stellt für den macOS-Release eine arm64-TagLib bereit, die wirklich ab
# macOS 14 läuft. Homebrew liefert auf neueren Build-Macs nur noch eine für
# deren aktuelle macOS-Version gebaute Flasche; ein bloßes Kopieren dieser
# Bibliotheken würde die in Info.plist zugesagte Mindestversion brechen.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
version="2.1.1"
bottle_sha="a8d56fabd553d9d4f5de8a78476f803ea5e6d7d7dc00861f767fbe54b161f50d"
bottle_url="https://ghcr.io/v2/homebrew/core/taglib/blobs/sha256:$bottle_sha"
cache_dir="${TAGX_PORTABLE_TAGLIB_CACHE:-$here/build/vendor}"
archive="$cache_dir/taglib-$version-arm64-sonoma.tar.gz"
root="$cache_dir/taglib-$version-arm64-sonoma"

[ "$(uname -m)" = "arm64" ] || {
    echo "FEHLER: Der macOS-Release wird nur für arm64 gebaut." >&2
    exit 1
}

mkdir -p "$cache_dir"

archive_is_valid() {
    [ -f "$archive" ] &&
        [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$bottle_sha" ]
}

if ! archive_is_valid; then
    download="$archive.download.$$"
    trap 'rm -f "$download"' EXIT HUP INT TERM

    # GHCR verlangt auch für öffentliche Homebrew-Flaschen ein kurzlebiges
    # anonymes Zugriffstoken. Es bleibt ausschließlich in einer Shellvariable
    # und wird per stdin an curl übergeben, nie als Argument oder Ausgabe.
    token="$(curl -fsSL \
        'https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/taglib:pull' \
        | plutil -extract token raw -o - -)"
    printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl -K - -fsSL "$bottle_url" -o "$download"
    unset token

    [ "$(shasum -a 256 "$download" | awk '{print $1}')" = "$bottle_sha" ] || {
        echo "FEHLER: Prüfsumme der portablen TagLib stimmt nicht." >&2
        exit 1
    }
    mv "$download" "$archive"
    trap - EXIT HUP INT TERM
fi

# Das Ziel enthält ausschließlich aus der oben verifizierten Flasche erzeugte
# Build-Daten. Neu entpacken verhindert halbe oder lokal veränderte Caches.
rm -rf "$root"
mkdir -p "$root"
tar -xzf "$archive" -C "$root" --strip-components=2

# Homebrew ersetzt diesen Platzhalter normalerweise erst bei der Installation.
# SwiftPM/pkg-config braucht für unseren isolierten Cache stattdessen den echten
# Pfad. Die Mach-O-Install-Namen werden später im App-Bundle separat umgebogen.
for pc in "$root"/lib/pkgconfig/*.pc; do
    sed -i '' "s|@@HOMEBREW_CELLAR@@/taglib/$version|$root|g" "$pc"
done

printf '%s\n' "$root"

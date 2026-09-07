#!/bin/sh
# Installiert unter Debian/Ubuntu alles, was Core, CLI und Tests brauchen.
# Wird vom Linux-Job in `.github/workflows/tests.yml` und vom lokalen
# Docker-Lauf (`swift:6.0`-Image) gleichermaßen benutzt, damit beide exakt
# dieselbe Umgebung prüfen.
#
# Warum TagLib aus dem Quelltext: Der Shim braucht die TagLib-2-API (komplexe
# Properties, MP4-/Matroska-Kapitel ab 2.3). Ubuntu 24.04 liefert im Paket
# `libtag1-dev` nur TagLib 1.13, damit baut der Shim nicht. Die Version ist
# hier gepinnt, die Prüfsumme kommt aus der Homebrew-Formel derselben Version.
set -eu

taglib_version="2.3.1"
taglib_sha256="a19d90e6fd41d09a0281ec0fe762d51491d7a6ccffc923c4f7868c5e647ca230"
taglib_url="https://taglib.org/releases/taglib-$taglib_version.tar.gz"
prefix="${TAGX_LINUX_PREFIX:-/usr/local}"

# Ohne root (CI-Runner) über sudo; im Docker-Container sind wir schon root.
if [ "$(id -u)" -eq 0 ]; then
    as_root() { "$@"; }
else
    as_root() { sudo "$@"; }
fi

export DEBIAN_FRONTEND=noninteractive
as_root apt-get update -qq
# cmake/g++/zlib/utfcpp: TagLib bauen · pkg-config: SwiftPM findet TagLib ·
# mediainfo/exiftool/ffmpeg: Tests, die ohne sie nur übersprungen würden ·
# curl/ca-certificates: Quelltext laden · python3/zip: vollständige Fixtures.
as_root apt-get install -y -qq --no-install-recommends \
    build-essential cmake pkg-config zlib1g-dev libutfcpp-dev \
    curl ca-certificates \
    mediainfo libimage-exiftool-perl ffmpeg python3-minimal zip

# Schon vorhanden (zweiter Lauf im selben Container)? Dann nichts bauen.
if pkg-config --exists "taglib_c >= $taglib_version" 2>/dev/null; then
    echo "TagLib $(pkg-config --modversion taglib_c) ist bereits installiert."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
archive="$work/taglib.tar.gz"
curl -fsSL "$taglib_url" -o "$archive"
echo "$taglib_sha256  $archive" | sha256sum -c - >/dev/null || {
    echo "FEHLER: Prüfsumme von taglib-$taglib_version.tar.gz stimmt nicht." >&2
    exit 1
}
tar -xzf "$archive" -C "$work"
cmake -S "$work/taglib-$taglib_version" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DBUILD_BINDINGS=ON -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF \
    -DWITH_ZLIB=ON -DCMAKE_INSTALL_PREFIX="$prefix" >/dev/null
# Auf gemeinsam genutzten Testrechnern lässt sich die Parallelität begrenzen.
cmake --build "$work/build" -j "${TAGX_BUILD_JOBS:-$(nproc)}" >/dev/null
as_root cmake --install "$work/build" >/dev/null
# Der dynamische Linker muss die neue Bibliothek unter /usr/local/lib finden.
as_root ldconfig
echo "TagLib $(pkg-config --modversion taglib_c) installiert nach $prefix."

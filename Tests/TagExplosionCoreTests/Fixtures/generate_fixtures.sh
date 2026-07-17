#!/bin/sh
# Erzeugt kleine Test-Mediendateien (Sinuston, 2 s) in allen unterstützten
# Audio-Formaten plus ein Testbild. Benötigt ffmpeg. Ausgabe nach $1
# (Standard: ./generated neben diesem Skript). Idempotent.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/generated}"
mkdir -p "$out"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg nicht gefunden — Fixtures können nicht erzeugt werden" >&2
    exit 1
fi

# 2 Sekunden 440-Hz-Sinus als Quelle (einmalig als wav)
src="$out/source.wav"
[ -f "$src" ] || ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=440:duration=2" "$src"

# Formate: <ausgabedatei> <ffmpeg-optionen>
gen() {
    target="$out/$1"; shift
    [ -f "$target" ] && return 0
    ffmpeg -nostdin -v error -y -i "$src" "$@" "$target"
}

gen sample.mp3  -codec:a libmp3lame -b:a 64k
gen sample.m4a  -codec:a aac -b:a 64k
gen sample.flac -codec:a flac
# ffmpeg ohne libvorbis: eingebauter (experimenteller) Vorbis-Encoder reicht für
# Fixtures, kann aber nur Stereo -> -ac 2
gen sample.ogg  -ac 2 -codec:a vorbis -strict experimental
gen sample.opus -codec:a libopus -b:a 64k
gen sample.wav  -codec:a pcm_s16le
gen sample.aiff -codec:a pcm_s16be
gen sample.wv   -codec:a wavpack

# m4b = m4a-Container mit anderer Endung (Hörbuch)
[ -f "$out/sample.m4b" ] || cp "$out/sample.m4a" "$out/sample.m4b"

# Video-Fixtures: 1 s Testbild + Ton
genv() {
    target="$out/$1"; shift
    [ -f "$target" ] && return 0
    ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=128x96:duration=1:rate=10" \
        -i "$src" -t 1 -codec:v libx264 -preset ultrafast -codec:a aac -b:a 48k "$@" "$target"
}
genv sample.mp4
genv sample.mkv
genv sample.m4v

# Testbilder: 64x64 rot (jpg) und blau (png)
[ -f "$out/cover.jpg" ] || ffmpeg -nostdin -v error -y -f lavfi -i "color=red:size=64x64:duration=0.04" -frames:v 1 "$out/cover.jpg"
[ -f "$out/cover.png" ] || ffmpeg -nostdin -v error -y -f lavfi -i "color=blue:size=64x64:duration=0.04" -frames:v 1 "$out/cover.png"

# ---- E-Book-Fixtures --------------------------------------------------------
# Minimale, handgebaute EPUBs (ZIP via zip-CLI; mimetype MUSS unkomprimiert als
# erster Eintrag liegen -> zip -X -0). Kein NCX/keine Vollvalidierung nötig —
# die Tests prüfen nur unser Metadaten-IO.

# EPUB 2: Serie als Calibre-Metas, Cover über <meta name="cover">, ISBN mit
# opf:scheme.
if [ ! -f "$out/book2.epub" ] && command -v zip >/dev/null 2>&1; then
    tmp="$out/epub2-tmp"
    rm -rf "$tmp"
    mkdir -p "$tmp/META-INF" "$tmp/OEBPS"
    printf 'application/epub+zip' > "$tmp/mimetype"
    cat > "$tmp/META-INF/container.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
XML
    cat > "$tmp/OEBPS/content.opf" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Testbuch Zwei</dc:title>
    <dc:creator opf:role="aut">Erika Beispiel</dc:creator>
    <dc:description>Ein kleines Testbuch.</dc:description>
    <dc:publisher>Testverlag</dc:publisher>
    <dc:language>de</dc:language>
    <dc:date>2020-01-01</dc:date>
    <dc:subject>Test</dc:subject>
    <dc:subject>Fixtures</dc:subject>
    <dc:identifier id="uid" opf:scheme="ISBN">9783161484100</dc:identifier>
    <meta name="calibre:series" content="Testreihe"/>
    <meta name="calibre:series_index" content="2.0"/>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
    <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="text"/></spine>
</package>
XML
    cat > "$tmp/OEBPS/text.xhtml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head>
<body><p>Hallo.</p></body></html>
XML
    cp "$out/cover.jpg" "$tmp/OEBPS/cover.jpg"
    (cd "$tmp" \
        && zip -X -0 -q ../book2.epub mimetype \
        && zip -rX -q ../book2.epub META-INF OEBPS)
    rm -rf "$tmp"
fi

# EPUB 3: Serie als belongs-to-collection, Cover über properties="cover-image",
# ISBN als urn:isbn.
if [ ! -f "$out/book3.epub" ] && command -v zip >/dev/null 2>&1; then
    tmp="$out/epub3-tmp"
    rm -rf "$tmp"
    mkdir -p "$tmp/META-INF" "$tmp/OEBPS"
    printf 'application/epub+zip' > "$tmp/mimetype"
    cat > "$tmp/META-INF/container.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
XML
    cat > "$tmp/OEBPS/package.opf" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Testbuch Drei</dc:title>
    <dc:creator>Max Muster</dc:creator>
    <dc:creator>Erika Beispiel</dc:creator>
    <dc:language>en</dc:language>
    <dc:date>2021-06-15</dc:date>
    <dc:identifier id="uid">urn:isbn:9780306406157</dc:identifier>
    <meta property="belongs-to-collection" id="c01">Dreierreihe</meta>
    <meta refines="#c01" property="group-position">3</meta>
    <meta property="dcterms:modified">2021-06-15T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine><itemref idref="nav"/></spine>
</package>
XML
    cat > "$tmp/OEBPS/nav.xhtml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Nav</title></head>
<body><nav epub:type="toc"><ol><li><a href="nav.xhtml">Start</a></li></ol></nav></body></html>
XML
    cp "$out/cover.png" "$tmp/OEBPS/cover.png"
    (cd "$tmp" \
        && zip -X -0 -q ../book3.epub mimetype \
        && zip -rX -q ../book3.epub META-INF OEBPS)
    rm -rf "$tmp"
fi

# PDF: sips (macOS) wandelt das Testbild um; unter Linux entfällt die Fixture
# (die zugehörigen Tests werden dann übersprungen).
if [ ! -f "$out/book.pdf" ] && command -v sips >/dev/null 2>&1; then
    sips -s format pdf "$out/cover.jpg" --out "$out/book.pdf" >/dev/null
fi

# azw3 nur mit Calibre (ebook-convert) — für die ebook-meta-Tests. Auf macOS
# liegt Calibre oft nur als App-Bundle vor (nicht im PATH).
ebook_convert=""
if command -v ebook-convert >/dev/null 2>&1; then
    ebook_convert="ebook-convert"
elif [ -x /Applications/calibre.app/Contents/MacOS/ebook-convert ]; then
    ebook_convert=/Applications/calibre.app/Contents/MacOS/ebook-convert
fi
if [ ! -f "$out/book.azw3" ] && [ -n "$ebook_convert" ]; then
    "$ebook_convert" "$out/book2.epub" "$out/book.azw3" >/dev/null 2>&1 || true
fi

echo "$out"

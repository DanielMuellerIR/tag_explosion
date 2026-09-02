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

# ---- Weitere Audio-/Container-Endungen (AP1) --------------------------------
gen sample.mp2  -codec:a mp2 -b:a 64k
# AIFF-C: Bei Little-Endian-PCM schreibt ffmpeg den AIFC-Container (FORM/AIFC)
gen sample.aifc -codec:a pcm_s16le -f aiff
# Sun/NeXT AU (µ-law). TagLib kennt das Format nicht — nur Anzeige-Tests.
gen sample.au   -codec:a pcm_mulaw -f au
# Matroska nur mit Tonspur
gen sample.mka  -codec:a libopus -b:a 48k -f matroska
# 3GP/3GP2 = MP4-Container mit eigenem ftyp-Brand, hier nur mit Tonspur
gen sample.3gp  -codec:a aac -b:a 48k -f 3gp
gen sample.3g2  -codec:a aac -b:a 48k -f 3g2
# Ogg-Video: VP8 + Vorbis (Homebrew-ffmpeg hat keinen Theora-Encoder; der
# eingebaute Vorbis-Encoder kann nur Stereo). TagLib liest ogv nicht — nur
# Anzeige-Tests.
if [ ! -f "$out/sample.ogv" ]; then
    ffmpeg -nostdin -v error -y -f lavfi -i "testsrc=size=128x96:duration=1:rate=10" \
        -i "$src" -t 1 -codec:v libvpx -ac 2 -codec:a vorbis -strict experimental \
        -f ogg "$out/sample.ogv"
fi

# ---- Tracker-Module (synthetisch, ohne fremdes Material) -------------------
# Kleinstmögliche gültige Dateien: nur Kopf, leere Pattern, keine Sample-Daten.
# TagLib liest daraus Titel, Sample-/Instrumentnamen (= Kommentar) und den
# Tracker-Namen. Byte-Helfer, damit das Skript in jeder POSIX-Shell läuft.
zeros() { head -c "$1" /dev/zero; }
byte()  { printf "\\$(printf '%03o' "$1")"; }
u16le() { byte $(( $1 & 255 )); byte $(( ($1 >> 8) & 255 )); }
u32le() { u16le $(( $1 & 65535 )); u16le $(( ($1 >> 16) & 65535 )); }
u16be() { byte $(( ($1 >> 8) & 255 )); byte $(( $1 & 255 )); }
# Text auf feste Breite, Rest mit Nullbytes auffüllen
field() { printf '%s' "$1" | head -c "$2"; zeros $(( $2 - $(printf '%s' "$1" | wc -c) )); }
# Denselben Befehl n-mal ausführen: rep 3 byte 255
rep()   { n=$1; shift; while [ "$n" -gt 0 ]; do "$@"; n=$((n - 1)); done; }

# ProTracker MOD: 20 Byte Titel, 31 Samples je 30 Byte, Länge, Restart,
# 128 Byte Reihenfolge, Kennung "M.K." (4 Kanäle), ein leeres Pattern.
if [ ! -f "$out/sample.mod" ]; then
    {
        field "Testmodul" 20
        i=1
        while [ "$i" -le 31 ]; do
            field "Sample $i" 22
            u16be 0; byte 0; byte 64; u16be 0; u16be 1   # Länge, Finetune, Lautstärke, Repeat-Start/-Länge
            i=$((i + 1))
        done
        byte 1; byte 127          # Songlänge 1, Restart-Position
        zeros 128                 # Pattern-Reihenfolge (nur Pattern 0)
        printf 'M.K.'
        zeros 1024                # 64 Zeilen × 4 Kanäle × 4 Byte
    } > "$out/sample.mod"
fi

# FastTracker II XM: 60 Byte Kennung/Titel/Tracker, 276 Byte Header,
# ein leeres Pattern, ein Instrument ohne Samples.
if [ ! -f "$out/sample.xm" ]; then
    {
        printf 'Extended Module: '; field "Testmodul XM" 20; byte 26
        field "TagxTracker" 20; u16le 260   # Tracker-Name, Version 1.04
        u32le 276; u16le 1; u16le 0; u16le 4; u16le 1; u16le 1   # Header-Größe, Länge, Restart, Kanäle, Pattern, Instrumente
        u16le 1; u16le 6; u16le 125; zeros 256                   # Flags, Tempo, BPM, Reihenfolge
        u32le 9; byte 0; u16le 64; u16le 0                       # Pattern-Header: 64 Zeilen, keine gepackten Daten
        u32le 29; field "Instrument 1" 22; byte 0; u16le 0       # Instrument-Header ohne Samples
    } > "$out/sample.xm"
fi

# Scream Tracker 3 S3M: 96 Byte Kopf, eine Reihenfolge-Marke (255 = Ende),
# ein Instrument ohne Sample-Daten (TagLib legt den Kommentar in den
# Instrumentnamen ab — ohne Instrument ginge er verloren), keine Pattern.
# Instrument-Header liegen auf 16-Byte-Grenzen („Parapointer“ × 16).
if [ ! -f "$out/sample.s3m" ]; then
    {
        field "Testmodul S3M" 28; byte 26; byte 16; byte 0; byte 0
        u16le 1; u16le 1; u16le 0; u16le 0; u16le 4896; u16le 2  # Orders, Instrumente, Pattern, Flags, Tracker-Version 0x1320, Dateiformat
        printf 'SCRM'; byte 64; byte 6; byte 125; byte 48; byte 0; byte 0
        zeros 8; u16le 0
        byte 0; byte 1; byte 2; byte 3; rep 28 byte 255           # 4 Kanäle belegt, Rest frei
        byte 255                                                 # Reihenfolge: Ende (Offset 96)
        u16le 7                                                  # Parapointer Instrument 1 → Offset 112
        zeros 13                                                 # Auffüllen bis 112
        byte 1; field "INSTR1.SMP" 12; byte 0; u16le 0           # Typ Sample, Dateiname, Speichersegment
        u32le 0; u32le 0; u32le 0                                # Länge, Loop-Anfang, Loop-Ende
        byte 64; byte 0; byte 0; byte 0; u32le 8363; zeros 12    # Lautstärke, reserviert, Packung, Flags, C2-Frequenz, reserviert
        field "Instrument 1" 28; printf 'SCRS'
    } > "$out/sample.s3m"
fi

# Impulse Tracker IT: 192 Byte Kopf mit Nachricht (= Kommentar), eine
# Reihenfolge-Marke, keine Instrumente/Samples/Pattern.
if [ ! -f "$out/sample.it" ]; then
    {
        printf 'IMPM'; field "Testmodul IT" 26
        u16le 4100; u16le 1; u16le 0; u16le 0; u16le 0           # Pattern-Highlight, Orders, Instrumente, Samples, Pattern
        u16le 5120; u16le 512; u16le 73; u16le 1                 # Erstellt mit 0x1400, kompatibel 0x0200, Flags, Special (Nachricht vorhanden)
        byte 128; byte 48; byte 6; byte 125; byte 128; byte 0    # Lautstärken, Tempo, Panning-Trennung, Pitch-Wheel
        u16le 16; u32le 193; zeros 4                             # Nachricht: 16 Byte ab Offset 193
        rep 4 byte 32; rep 60 byte 128; rep 64 byte 64           # Kanal-Panning (4 aktiv) und -Lautstärke
        byte 255                                                 # Reihenfolge: Ende
        printf 'Kommentar aus IT'
    } > "$out/sample.it"
fi

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

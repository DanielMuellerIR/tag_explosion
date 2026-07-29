<p align="center">
  <img src="docs/app-icon.png" width="128" alt="Tag-Explosion-Symbol">
</p>

<h1 align="center">Tag Explosion</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Native macOS-App zum Anzeigen und Bearbeiten von Medien-Metadaten —
  Audio-Tags, Bild-Metadaten (EXIF/IPTC/XMP), Video-Tags und E-Book-Metadaten in
  einem schnellen Editor im Apple-Stil, mit skriptfähiger CLI.</strong>
</p>

<p align="center">
  <img alt="Lizenz: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg">
  <img alt="Plattform: macOS 14+" src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange.svg">
</p>

![Ein Hörbuch bearbeiten: Cover, Tags und Kopier-Menüs an jedem Feld](docs/screenshots/de/audio.png)
*Der Audio-Editor: Cover, alle Tag-Felder und an jedem Feld ein Kopier-Menü.*

## Funktionen

- **Audio** — alle Tag-Felder inklusive Custom-Keys, Coverbilder und
  Batch-Bearbeitung: gemeinsame Felder, Tracks nummerieren, Titel aus
  Dateinamen, ein Cover für alle Dateien.
- **Bilder** — EXIF/IPTC/XMP nach MWG harmonisiert (Titel, Beschreibung,
  Schlagwörter, Ersteller, Copyright, Datum, Bewertung, GPS), dazu eine
  vollständige Ansicht aller rohen Metadaten-Gruppen.
- **Video** — MP4- und Matroska-Tags bearbeitbar; andere Container werden
  read-only angezeigt.
- **E-Books/Dokumente** — der Metadaten-Umfang von Calibres Dialog (Titel,
  Autoren, Serie, Beschreibung, Cover, ISBN, Verlag, Sprache, Datum,
  Schlagwörter). EPUB nativ, PDF über exiftool; mit installiertem Calibre
  werden mobi/azw3/fb2 über dessen CLI `ebook-meta` bearbeitet.
- **Werte zwischen Tags kopieren** — jedes Textfeld (Einzeldatei und Batch)
  kann seinen Wert pro Datei aus einem anderen Tag übernehmen. Funktioniert
  auch über Tag-Formate hinweg (z. B. EXIF → IPTC/XMP), beschränkt auf
  typkompatible Textfelder.
- **Abgesicherter Modus** — vor jeder Änderung landet eine unveränderte Kopie
  der Datei im Papierkorb, und jeder Schreibvorgang läuft über eine geprüfte
  Kopie. Siehe [Wie die Dateien geschützt werden](#wie-die-dateien-geschützt-werden).
- **Tag-Export/-Import mit Auto-Backup** — die Batch-Editoren exportieren alle
  Tags einer Auswahl (Cover eingebettet) in eine selbständige JSON-Datei und
  stellen daraus wieder her; vor Batch-Speichern legt die App automatisch ein
  `tags-backup-<Zeitstempel>.json` neben die Dateien (Einstellung, Default an).
- **Technik-Panel** — der vollständige `mediainfo`-Bericht zu jeder Datei,
  filterbar und kopierbar.
- **Auto-Updates** — über [Sparkle](https://sparkle-project.org); installiert
  wird nur nach Bestätigung.
- **CLI `tagx`** — alles auch headless, mit JSON-Ausgabe und Exit-Codes:
  `tagx show --json`, `tagx set`, `tagx cover`, `tagx info`, `tagx exif`,
  `tagx ebook`.

Die Oberfläche der App ist deutsch und englisch (folgt der Systemsprache);
die CLI spricht Englisch.

![Batch-Bearbeitung eines Albums](docs/screenshots/de/batch.png)
*Batch-Bearbeitung: eine Änderung wirkt auf alle ausgewählten Dateien; die
Kopier-Menüs befüllen jede Datei aus einem ihrer eigenen Tags.*

![Bild-Metadaten-Editor](docs/screenshots/de/image.png)
*Der Bild-Editor mit MWG-harmonisierten EXIF/IPTC/XMP-Feldern.*

![E-Book-Metadaten-Editor](docs/screenshots/de/ebook.png)
*Der E-Book-Editor: Metadaten wie in Calibre plus Cover für EPUB, PDF und
Calibre-Formate.*

## Wie die Dateien geschützt werden

Tag Explosion bearbeitet Dateien, die sich nicht ohne Weiteres wiederherstellen
lassen. Ein Hörbuch oder ein gescanntes Foto für einen korrigierten
Künstlernamen zu verlieren, wäre ein schlechtes Geschäft. Deshalb ist die App so
gebaut, dass das unwahrscheinlich wird — und im Ernstfall umkehrbar bleibt.

**Jede Änderung entsteht zuerst an einer Kopie.** Die neue Fassung wird neben
dem Original angelegt, geprüft (lässt sich die Datei noch öffnen, sind Kanäle,
Samplerate und Spielzeit unverändert, stimmt die Zahl der Cover) und ersetzt das
Original erst danach in einem einzigen atomaren Schritt. Ein Absturz, ein
Formatfehler oder ein voller Datenträger kann keine halb geschriebene Datei
hinterlassen: Entweder die Änderung ist vollständig, oder das Original ist
unberührt. Auf APFS ist die Kopie ein Klon und kostet dadurch weder spürbar Zeit
noch Speicherplatz.

**Der abgesicherte Modus legt die alte Fassung in den Papierkorb.** Vor jeder
Änderung wandert eine unveränderte Kopie der Datei dorthin — gesammelt in einem
Ordner je Sitzung und Datenträger, benannt `Tag Explosion Sicherung
<Zeitstempel>`. Stellt sich eine Änderung als falsch heraus, ziehen Sie die
Kopie einfach zurück. Zum Aufräumen genügt es, den Papierkorb zu leeren; es
sammelt sich nichts in einem versteckten Ordner an, in den nie jemand schaut.
Auch hier ist die Kopie auf APFS ein Klon und belegt nur das, was sich
tatsächlich ändert. Der Modus ist standardmäßig an, solange die App jung ist;
abschalten unter ⌘, oder in der CLI mit `--no-backup` bzw. `TAGX_NO_BACKUP=1`.

**Fremde Änderungen werden nicht stillschweigend überschrieben.** Hat sich eine
Datei nach dem Öffnen auf der Platte geändert, hält das Speichern an und fragt
nach. Auch „Trotzdem speichern" bleibt sicher: Der Stand, der gerade auf der
Platte liegt, ist genau das, was der abgesicherte Modus vorher in den Papierkorb
kopiert.

**Vor dem Schreiben wird geprüft, ob genug Platz da ist.** Ein Stapel, dem der
Speicherplatz ausginge, wird abgelehnt statt begonnen.

**Vor Batch-Speichern entsteht zusätzlich ein Tag-Backup.** Bei mehr als einer
Datei wird ein `tags-backup-<Zeitstempel>.json` mit dem bisherigen Zustand
(inklusive Cover) neben die Dateien gelegt, wiederherstellbar über denselben
Import-Weg oder `tagx import`.

**Was sich nicht sicher schreiben lässt, bleibt read-only.** Container, die
TagLib nicht schreiben kann, PDFs ohne Cover-Unterstützung und E-Book-Formate,
die Calibre brauchen, es aber nicht vorfinden, werden angezeigt statt bearbeitet.
Ein Feld, das ein Format nicht aufnehmen kann, wird vor dem Schreiben abgelehnt
und nicht stillschweigend verworfen.

**Durch Tests belegt, nicht bloß behauptet.** Die Testsuite prüft, dass der
Audiostream vor und nach dem Tag-Schreiben bitgleich ist, dass ein
fehlgeschlagener Schreibvorgang das Original bytegleich stehen lässt, dass eine
schreibgeschützte Datei, ein schreibgeschützter Ordner und ein wirklich voller
Datenträger abgelehnt werden, dass kaputte und feindselige Eingaben (leer,
abgeschnitten, Zufallsbytes, führender Bindestrich im Dateinamen) nichts
beschädigen, und dass die Papierkorb-Kopie wirklich den Stand vor der Änderung
enthält. Das läuft bei jedem Push (siehe `.github/workflows/tests.yml`).

## Unterstützte Formate

| Medium | Dateiformate | Tag-Formate |
|--------|--------------|-------------|
| Audio | mp3, m4a, m4b, m4r, mp4, aac, flac, ogg, oga, opus, spx, wav, aiff, aif, wv, ape, mpc, tta, dsf, dff, wma, asf | ID3v1/v2, MP4-Atome, Vorbis Comments, APEv2, ASF, RIFF-Info |
| Bilder | jpg, jpeg, png, heic, heif, tif, tiff, webp, dng, gif | EXIF, IPTC, XMP (MWG-harmonisiert) |
| Video | mp4, m4v, mkv, webm (bearbeitbar) · mov, avi (nur Anzeige) | MP4-Atome, Matroska-Tags |
| E-Books | epub, pdf · mobi, azw3, fb2 (mit Calibre) | EPUB-OPF, PDF Info/XMP (PDF: keine Serie/kein Cover) |

![Startbildschirm mit der Format-Übersicht](docs/screenshots/de/empty.png)
*Der Startbildschirm listet alle unterstützten Datei- und Tag-Formate.*

## Installation

Das notarisierte DMG von der [Releases-Seite](../../releases) laden, öffnen
und `TagExplosion.app` auf den Ordner `Programme` ziehen. Benötigt macOS 14
oder neuer und Apple Silicon (`arm64`). Es gibt keinen Intel/x86_64- oder
Universal-Build.

TagLib steckt im App-Bundle. Für den vollen Funktionsumfang die beiden
externen Werkzeuge installieren, die die App aufruft:

```sh
brew install mediainfo exiftool   # Technik-Panel, Bild- und PDF-Metadaten
```

Fehlen die Werkzeuge, bietet die App das bei jedem Start selbst an: Mit
vorhandenem Homebrew installiert sie die fehlenden Formeln auf Klick, ohne
Homebrew verweist sie auf [brew.sh](https://brew.sh). Das Angebot endet,
sobald nichts mehr fehlt oder „Nicht mehr fragen" gewählt wurde.

Optional: mit installiertem [Calibre](https://calibre-ebook.com) bearbeitet
die App zusätzlich mobi/azw3/fb2 über dessen Kommandozeilenwerkzeug
`ebook-meta`.

Spätere Updates kommen über den eingebauten Updater
(**Tag Explosion → Nach Updates suchen …**). Dabei ruft die App den
Update-Feed auf GitHub Pages ab; weitere Daten sendet sie nicht.

## CLI

```sh
tagx show --json song.mp3                      # alle Tags als JSON
tagx set song.mp3 -t ARTIST="Miles Davis"      # Felder setzen
tagx set song.mp3 -c ALBUMARTIST=ARTIST        # Tag in anderes Feld kopieren
tagx cover set song.mp3 cover.jpg              # Cover einbetten
tagx exif set foto.jpg --copy description=IFD0:ImageDescription
tagx ebook set buch.epub --series "Foundation" --series-index 2
tagx export Album/ -o tags.json                # alle Tags sichern (Cover eingebettet)
tagx import --dry-run tags.json                # Wiederherstellung als Vorschau
tagx info video.mkv                            # vollständiger mediainfo-Bericht
tagx set song.mp3 -t ARTIST="X" --no-backup    # ohne Sicherungskopie im Papierkorb
```

Importe bearbeiten standardmäßig nur Dateien innerhalb des JSON-Ordners. Ein
Archiv mit absichtlich externen Zielen braucht ausdrücklich
`--allow-external-targets`; `tagx` gibt vor dem Anwenden die vollständige
aufgelöste Zielliste aus. Bewertungen akzeptieren nur ganze Zahlen von 0 bis
5; ausschließlich ein explizit leerer `--rating`-Wert löscht das Feld.

## Aus dem Quelltext bauen

Voraussetzungen: Xcode-Toolchain, Homebrew mit `taglib`; zur Laufzeit
`mediainfo`, optional `exiftool` und `ffmpeg` für die Tests.

```sh
./build.sh          # baut tagx und TagExplosion.app im Projektordner
swift test          # Tests generieren sich ihre Fixtures selbst
swift test --package-path App   # App-Tests (headless, ohne Fenster)
```

Mit einer Apple Developer ID im Schlüsselbund gibt es zwei weitere Skripte.
Beide fragen einmalig nach dem lokalen notarytool-Schlüsselbundprofil und
merken sich dessen Namen nur für diesen Clone:

```sh
./install.sh        # notarisierter Build, installiert nach /Applications
./release.sh        # notarisiertes DMG mit Hintergrundbild, fertig zum Veröffentlichen
```

`install.sh` kopiert erst nach `/Applications`, wenn Stapler, Gatekeeper und
Signatur bestätigen, dass das Bundle wirklich notarisiert ist;
`./install.sh --no-notarize` baut ein schnelles Testbundle, das im Projektordner
bleibt.

Core-Bibliothek und CLI bleiben frei von AppKit/SwiftUI und damit
Linux-portabel. Architektur und Meilensteine stehen in
[docs/PLAN.md](docs/PLAN.md), der Release-Ablauf in
[docs/sparkle-release.md](docs/sparkle-release.md).

## Lizenz

MIT (siehe [LICENSE](LICENSE)), © 2026 Daniel Müller.

TagLib (LGPL-2.1-or-later oder MPL-1.1) wird dynamisch gelinkt und unverändert
im App-Bundle mitgeliefert, bleibt dort also austauschbar. Ebenfalls gelinkt
sind Sparkle (MIT), ZIPFoundation (MIT) und swift-argument-parser (Apache-2.0).
mediainfo (BSD-2), exiftool (Artistic/GPL) und Calibres `ebook-meta` (GPL)
werden weder gebündelt noch gelinkt, sondern nur als externe Programme
aufgerufen. Vollständige Lizenztexte und die Begründung:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Die Demo-Dateien und Cover in den Screenshots sind vollständig für diese
Dokumentation generiert — die Titel, Autoren und Künstler existieren nicht.

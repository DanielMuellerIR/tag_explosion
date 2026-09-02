<p align="center">
  <img src="docs/app-icon.png" width="128" alt="Tag-Explosion-Symbol">
</p>

<h1 align="center">Tag Explosion</h1>

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <strong>Native macOS-App zum Anzeigen und Bearbeiten von Medien-Metadaten —
  Audio-Tags, Bild-Metadaten (EXIF/IPTC/XMP), Video-Tags und E-Book-Metadaten in
  einem schnellen Editor im Apple-Stil, mit skriptfähiger CLI. Zeigt außerdem
  E-Rechnungen an (ZUGFeRD/Factur-X, XRechnung, Peppol), rein lesend.</strong>
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
  Cover-Werkzeuge: Maße, Format und Prüfhinweise unter dem Cover (zu klein,
  zu groß, nicht quadratisch, progressives JPEG, CMYK); verkleinern auf
  500/1000/1500 px, nach JPEG wandeln, Bild-Metadaten entfernen,
  `folder.jpg`/`cover.jpg`/`front.jpg` aus dem Ordner übernehmen oder das
  Cover als `folder.jpg` exportieren — für eine Datei oder die ganze Auswahl.
- **Online nachschlagen** — „Online nachschlagen …" im Einzel- und
  Batch-Editor fragt MusicBrainz oder Discogs nach einem Release (Interpret +
  Album, bei einer einzelnen Datei Interpret + Titel) oder erkennt eine Datei
  per Audio-Fingerabdruck über AcoustID (`fpcalc` aus Homebrew `chromaprint`,
  braucht einen kostenlosen Client-Key). Kandidaten, Zuordnung Datei → Titel
  (Tracknummer, sonst Dauer ±3 s und Titelähnlichkeit) und Vorschau je Feld
  (alt → neu, Cover-Vorschau); „Übernehmen" füllt nur den Editor, gespeichert
  wird wie gewohnt. Schreibt auch die Kennungen von MusicBrainz, Discogs und
  AcoustID. Gesendet wird nichts, solange Online-Dienste nicht in den
  Einstellungen erlaubt und der Datenschutzhinweis bestätigt sind — siehe unten.
- **Bilder** — EXIF/IPTC/XMP nach MWG harmonisiert (Titel, Beschreibung,
  Schlagwörter, Ersteller, Copyright, Datum, Bewertung, GPS), dazu eine
  vollständige Ansicht aller rohen Metadaten-Gruppen.
- **Kamera-RAW und XMP-Sidecars** — cr2, cr3, nef, arw, raf, orf, rw2, pef
  werden über exiftool gelesen und nie direkt beschrieben: Änderungen gehen
  in die XMP-Sidecar `<name>.xmp` neben der Datei (wird bei Bedarf angelegt).
  Beim Lesen überlagern Sidecar-Werte die eingebetteten feldweise, wie in
  Lightroom und Bridge; der Editor markiert, welche Werte aus der Sidecar
  stammen. Eine `.xmp` allein öffnet sich wie ein Bild ohne Pixel. Für alle
  Bildformate wählbar („Sidecar statt Original schreiben", `tagx exif set
  --sidecar`); für RAW und für Formate, die exiftool nicht schreiben kann
  (bmp, svg), erzwungen.
- **Video** — MP4- und Matroska-Tags bearbeitbar; andere Container werden
  read-only angezeigt.
- **Video-Sidecars** — Kodi/Jellyfin `.nfo` (movie, episodedetails, tvshow,
  musicvideo, album, artist): Titel, Original-/Sortiertitel, Jahr, Premiere,
  Handlung, Kurzbeschreibung, Tagline, Genres, Tags, Studio, Regie,
  Drehbuch, Bewertung, Altersfreigabe, Laufzeit, Staffel/Folge; Darsteller,
  IDs und Artwork nur zur Anzeige. Unbekannte Elemente, ihre Reihenfolge und
  die Einrückung der Datei überstehen das Speichern; eine Nur-URL-NFO wird
  angezeigt, nie beschrieben. Ein Video mit `<name>.nfo` daneben bekommt im
  Editor den Abschnitt „NFO-Sidecar", der in die NFO schreibt, nie ins
  Video. Untertitel `.srt`/`.vtt`: Anzahl Cues, Zeitspanne, Zeichensatz
  (UTF-8/BOM/Latin-1), Sprache und Flags aus dem Dateinamen
  (`film.en.forced.vtt`), der WebVTT-Kopf (Titel und `Language:`
  editierbar) und die Zeitverschiebung aller Cues (`tagx subtitle shift`).
- **Kapitel** — für Hörbücher und Podcasts: editierbare Kapitelliste (Titel,
  Beginn, Ende) mit Import/Export als JSON oder Text (`HH:MM:SS.mmm Titel`,
  eine Zeile je Kapitel). MP3 (ID3v2 CHAP/CTOC), MP4/M4A/M4B (Nero-`chpl`
  und QuickTime-Kapitelspur, beide werden geschrieben) und Matroska/WebM.
  MP4 speichert nur Startzeiten; das Ende eines Kapitels ergibt sich aus dem
  nächsten Beginn.
- **Tag-Schichten** — MP3-Dateien tragen oft ID3v1 *und* ID3v2 (manchmal
  auch APEv2), WAV trägt ID3v2 und RIFF INFO, FLAC Vorbis plus verirrte
  ID3-Tags. Der Editor listet jede Schicht mit Version (ID3v2.3/2.4, APEv2)
  und Feldanzahl und entfernt auf Wunsch eine einzelne Schicht — die anderen
  Schichten und der Audiostream bleiben unangetastet (`tagx layers show` /
  `tagx layers strip`). Optionale Einstellung: ID3v2.3 statt v2.4 schreiben
  für alte Player (`tagx set --id3v23`); v2.3 speichert Text als UTF-16 und
  kürzt Datumsangaben auf die Minute.
- **Lyrics, Lautheit, Podcast-Felder** — feste Felder mit Prüfung:
  mehrzeilige Lyrics mit Sprache (ID3v2 USLT; MP4 `©lyr`; Vorbis/APE
  `LYRICS`), synchronisierte Lyrics als ID3v2 SYLT mit LRC-Import/-Export —
  Formate ohne ID3v2 bekommen eine Sidecar `<name>.lrc` neben der Datei;
  ReplayGain Track/Album Gain und Peak (`-6.50 dB`, `0.987654`) und Opus R128
  (Q7.8-Ganzzahl, als dB angezeigt) mit Wertebereichsprüfung (Gain −60…+60
  dB, Peak 0…10, R128 −32768…32767) — ein ungültiger Wert wird mit Feldname
  abgelehnt, bevor etwas geschrieben wird; Podcast-Felder für MP3 und MP4
  (Flag, Feed-URL, Episoden-GUID, Kategorie, Stichwörter, Staffel, Episode,
  Beschreibung; ID3v2 PCST/WFED/TGID/TCAT/TKWD/TVSN/TVEP/TDES, MP4
  pcst/purl/egid/catg/keyw/tvsn/tves/desc/ldes). Lautheitswerte werden nur
  gespeichert und geprüft, nicht aus dem Audio berechnet.
- **E-Books/Dokumente** — der Metadaten-Umfang von Calibres Dialog (Titel,
  Autoren, Serie, Beschreibung, Cover, ISBN, Verlag, Sprache, Datum,
  Schlagwörter). EPUB nativ, PDF über exiftool; mit installiertem Calibre
  werden mobi/azw3/fb2 über dessen CLI `ebook-meta` bearbeitet.
- **Dokumente** — Office (docx, xlsx, pptx: `docProps/core.xml`),
  OpenDocument (odt, ods, odp: `meta.xml`), Comic-Archive (cbz:
  `ComicInfo.xml`, erste Seite als Cover) und Markdown mit YAML-Frontmatter:
  Titel, Autoren, Thema, Beschreibung, Schlagwörter, Verlag, Sprache,
  Kategorie, Daten plus formatspezifische Zusatzfelder (ComicInfo
  Serie/Nummer/Band, OOXML-Revision, beliebige Markdown-Schlüssel). Alles
  nativ ohne externe Programme; Felder, die ein Format nicht speichern kann,
  werden vor dem Schreiben abgelehnt statt still verworfen.
- **Playlists und Cue-Sheets** — `.cue` (Album-Kopf, Trackliste mit
  INDEX-Zeiten und ISRC), `.m3u`/`.m3u8`, `.pls` und `.xspf`: Einträge mit
  aufgelöstem Pfad, Prüfung auf fehlende Dateien und Gesamtdauer. Bearbeitbar
  sind Titel, Interpret, Datum und Genre der Liste (soweit das Format sie
  speichert) sowie Titel/Interpret je Eintrag; Reihenfolge und Pfade bleiben,
  ebenso fremde Zeilen, Zeilenenden und Einrückung. Jede Auswahl lässt sich
  als m3u8/pls/xspf exportieren (Pfade relativ zur Playlist), und `tagx cue
  apply` schreibt Titel, Interpreten und Tracknummern eines Cue-Sheets in die
  referenzierten Audiodateien (eine Datei je Track).
- **E-Rechnungen (nur Anzeige)** — erkennt Standard und Profil aus der
  Spezifikationskennung (BT-24): ZUGFeRD 2.x/Factur-X (MINIMUM bis EXTENDED),
  XRechnung, Peppol BIS und reine EN 16931, in beiden Syntaxen (UN/CEFACT CII
  und OASIS UBL, Rechnung und Gutschrift), dazu Bestellungen: Order-X
  (BASIC/COMFORT/EXTENDED, im PDF als `order-x.xml`) und Peppol
  Order/OrderResponse — Bestellfelder tragen Order-X-Bezeichnungen statt
  BT-Nummern. Die Dokumentart (Rechnung, Gutschrift, Bestellung,
  Bestellantwort) steht als eigenes Feld. Eine Grundvalidierung listet
  Hinweise: fehlende Pflichtfelder nach EN 16931 (XRechnung: auch die
  Leitweg-ID) und die Summenrechnung BT-106 … BT-115 mit Toleranz 0,01 —
  keine vollständige Schematron-Prüfung. Jedes befüllte Feld erscheint mit
  seiner EN-16931-Feldbezeichnung (BT-/BG-Nummer und Name); Felder ohne
  Zuordnung bleiben mit ihrem Rohpfad sichtbar, häufige Codes werden
  entschlüsselt (Rechnungstyp, USt-Kategorie, Zahlungsart, Einheiten).
  Funktioniert für eigenständige XML-Dateien und für PDFs mit eingebetteter
  Rechnung — die bekommen einen zusätzlichen Tab „E-Rechnung“.
- **Dateinamen aus Tags, Tags aus Dateinamen** — Muster im kid3-Stil wie
  `%{track:2} - %{artist} - %{title}` (jeder Tag-Schlüssel geht, `%{track:2}`
  füllt mit Nullen auf). Das Umbenennen zeigt eine Vorschau und verweigert
  Konflikte (zweimal derselbe Zielname, Ziel schon belegt, leerer Name); die
  Gegenrichtung füllt die Felder aus dem Namen und wird wie gewohnt
  gespeichert. Für Audio, Video, Bilder (`%{creator}`, `%{date}`) und E-Books
  (`%{author}`, `%{series}`), in den Editoren und als `tagx rename` /
  `tagx parse` (Probelauf per Voreinstellung, `--apply`, `--json`).
- **Konsistenzprüfung** — ein Bericht über einen Ordner oder eine Auswahl:
  fehlendes Cover, Cover-Größe/-Format im Album uneinheitlich, Album-Interpret
  uneinheitlich oder bei einer Compilation fehlend, Track- und Disc-Nummern
  (fehlend, Lücken, Dubletten, ohne Gesamtzahl, größer als die Gesamtzahl),
  Jahr, Genre und Album-Schreibweise im Album uneinheitlich, leere Felder
  Titel/Interpret/Album, gleicher Titel + Interpret + Dauer (±2 s) über alle
  Dateien und optional Dateinamen gegen ein Muster. Gruppiert wird nach Album
  (ALBUM + ALBUMARTIST, Schreibweise egal), ohne Album-Tag nach Ordner;
  Bilder, E-Books und Dokumente werden nur auf leeren Titel geprüft (E-Books
  auch auf fehlendes Cover). Korrigiert wird nichts automatisch: Der Bericht
  nennt die Dateien, ein Klick wählt eine aus, der Text lässt sich kopieren.
  In der App („Prüfen …" im Batch-Editor, Werkzeugleisten-Knopf für alle
  geladenen Dateien) und als `tagx check` (`--json`, `--pattern`,
  `--only <codes>`, `--fail-on warning|hint` → Exit 4).
- **Batch-Regeln als Skript** — eine JSON-Regeldatei, die der Reihe nach
  über eine Auswahl läuft: `set` (mit Platzhaltern wie `%{artist}`), `copy`
  (wahlweise nur in leere Felder), `replace` (wörtlich oder Regex mit
  `$1`-Gruppen), `case` (Groß, Klein, Titel-Schreibweise mit einstellbarer
  Liste kleiner Wörter, Satz-Schreibweise), `trim`, `remove` und `number`
  (Tracknummern nach Dateiname oder Feld, wahlweise als `n/gesamt`). Jede
  Regel lässt sich auf Medienarten und eine Feld-Bedingung (leer, nicht
  leer, gleich, enthält, Regex) einschränken. Im Batch-Editor gibt es dafür
  einen Regel-Editor mit Vorlagen, Laden/Speichern, zuletzt benutzten
  Dateien und Vorschautabelle (Datei, Feld, alt → neu); in der CLI
  `tagx apply regeln.json [--apply] [--json] <Dateien|Ordner>` (Probelauf
  per Voreinstellung, `--example` gibt eine kommentierte Beispieldatei aus,
  Exit 64 bei ungültiger Regeldatei). Geschrieben wird über den gewohnten
  sicheren Weg.
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
  `tagx show --json`, `tagx set`, `tagx cover`, `tagx chapters`, `tagx info`, `tagx exif`,
  `tagx ebook`, `tagx doc`, `tagx invoice`.

Die Oberfläche der App ist deutsch und englisch (folgt der Systemsprache);
die CLI spricht Englisch. Eine Ausnahme: Die E-Rechnungs-Anzeige beschriftet
Felder in App und CLI mit den offiziellen deutschen
EN-16931-Feldbezeichnungen (wie in der XRechnung-Spezifikation); die
BT-/BG-Nummern daneben sind sprachunabhängig.

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

**Jede Papierkorb-Sicherung wird verzeichnet — deshalb gibt es ein Undo.**
Jede Kopie landet in einem kleinen Journal (`~/Library/Application
Support/TagExplosion/backup-journal.json`: Originalpfad, Pfad im Papierkorb,
Zeit, Größe, SHA-256, Auslöser). Der Knopf „Versionen …“ im Editor listet die
Sicherungen der geöffneten Datei, zeigt je Version, welche Felder sich vom
jetzigen Stand unterscheiden, und stellt eine gewählte Version wieder her;
„Ablage → Letzte Änderung rückgängig“ (⌘⇧Z) holt die jüngste zurück.
Wiederherstellen ist ein normaler Schreibweg: Der jetzige Stand wandert
vorher in den Papierkorb, ein Undo lässt sich also selbst rückgängig machen.
In der CLI: `tagx history list|diff|restore|prune`. Mit dem Leeren des
Papierkorbs endet die Historie — das Journal verzeichnet nur Kopien, die noch
existieren, und die App löscht nie etwas aus dem Papierkorb.

**Fremde Änderungen werden nicht stillschweigend überschrieben.** Hat sich eine
Datei nach dem Öffnen auf der Platte geändert, hält das Speichern an und fragt
nach. Auch „Trotzdem speichern" bleibt sicher: Der Stand, der gerade auf der
Platte liegt, ist genau das, was der abgesicherte Modus vorher in den Papierkorb
kopiert. Metadaten-Reads werden vorher und nachher als ein Schnappschuss geprüft
— bei E-Books Felder und Cover gemeinsam — und erneut vor einer No-op-Meldung
oder dem atomaren Austausch. Eine Ersetzung am gleichen Pfad fällt durch ihre
neue Dateiidentität auf und gilt nicht als die zuvor gelesene Datei.

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

## Datenschutz: Online-Dienste

Tag Explosion nimmt von sich aus keinen Kontakt zu einem Server auf — kein
automatisches Nachschlagen beim Öffnen einer Datei, keine Nutzungsdaten, keine
Update-Suche außer der von Sparkle, der Sie selbst zustimmen. Das Nachschlagen
ist ab Werk aus (Einstellungen → „Online-Dienste erlauben") und zeigt vor der
ersten Anfrage, welche Daten wohin gehen: Suchbegriffe (Interpret, Album,
Titel, Jahr, Titelanzahl) an MusicBrainz und Discogs, die Release-Kennung ans
Cover Art Archive für Cover sowie ein Audio-Fingerabdruck (nicht das Audio)
mit Spieldauer und Ihrem Client-Key an AcoustID. Jede Anfrage trägt den
User-Agent `TagExplosion/<Version>` mit der Projektadresse, wie MusicBrainz es
verlangt; je Dienst geht höchstens eine Anfrage pro Sekunde. Discogs-Token und
AcoustID-Key liegen im macOS-Schlüsselbund, nicht in den Voreinstellungen; die
CLI liest sie aus `TAGX_DISCOGS_TOKEN` und `TAGX_ACOUSTID_KEY` und sendet nur
mit `TAGX_ONLINE=1` (`tagx lookup --privacy` zeigt den Hinweis).

## Unterstützte Formate

| Medium | Dateiformate | Tag-Formate |
|--------|--------------|-------------|
| Audio | mp3, mp2, m4a, m4b, m4r, mp4, aac, flac, ogg, oga, opus, spx, wav, aiff, aif, aifc, wv, ape, mpc, tta, dsf, dff, wma, asf, mka (kein Cover) · mod, s3m, xm, it (nur Titel und Kommentar) · au (nur Anzeige) | ID3v1/v2, MP4-Atome, Vorbis Comments, APEv2, ASF, RIFF-Info, Matroska-Tags, Tracker-Kopfdaten · Kapitel: ID3v2 CHAP/CTOC, MP4 (Nero + QuickTime), Matroska · Tag-Schichten einzeln anzeigen/entfernen für mp3/mp2, wav, aiff, flac, ape, mpc, wv, tta, dsf; ID3v2.3-Option für mp3/mp2, wav, aiff, dsf |
| Bilder | jpg, jpeg, png, heic, heif, tif, tiff, webp, dng, gif, avif, jxl, psd · bmp, svg (nur Sidecar) · xmp | EXIF, IPTC, XMP (MWG-harmonisiert) |
| Kamera-RAW | cr2, cr3, nef, arw, raf, orf, rw2, pef | eingebettet lesen; schreiben nur in die XMP-Sidecar `<name>.xmp` |
| Video | mp4, m4v, 3gp, 3g2, mkv, webm (bearbeitbar) · mov, avi, ogv (nur Anzeige) | MP4-Atome, Matroska-Tags |
| Video-Sidecars | nfo (Kodi/Jellyfin-XML; Nur-URL-NFO nur Anzeige) · srt (nur Anzeige, Sprache über den Dateinamen) · vtt (Kopf editierbar) | NFO-Elemente (unbekannte bleiben erhalten), WebVTT-Kopf; Zeitverschiebung der Cues für srt/vtt |
| E-Books | epub, pdf · mobi, azw3, fb2 (mit Calibre) | EPUB-OPF, PDF Info/XMP (PDF: keine Serie/kein Cover) |
| Dokumente | docx, xlsx, pptx · odt, ods, odp · cbz · md, markdown | OOXML core.xml (+ app.xml nur Anzeige), ODF meta.xml, ComicInfo.xml (Cover = erste Seite, nur Anzeige), YAML-Frontmatter (fremde Schlüssel bleiben erhalten) |
| Playlists | cue · m3u, m3u8 · pls · xspf | Cue-Kopf/Track-Zeilen, `#PLAYLIST`/`#EXTINF`, `TitleN`, XSPF title/creator (Anzeige: Pfade, Existenz, Dauer; Bearbeiten: nur Beschriftung; Export: m3u8/pls/xspf) |
| E-Rechnungen (nur Anzeige) | xml · pdf (eingebettete Rechnung) | ZUGFeRD/Factur-X, XRechnung, Peppol BIS, EN 16931 — CII und UBL, Felder mit BT-/BG-Bezeichnungen; Order-X und Peppol-Bestellungen mit Order-X-Bezeichnungen; Hinweise der Grundvalidierung |

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
tagx cover info --json *.mp3                   # Cover-Maße/Format/Farbe plus Prüfungen (zu klein, nicht quadratisch, CMYK …)
tagx cover convert --max-size 1000 --jpeg 0.85 *.flac   # eingebettetes Cover verkleinern und neu kodieren (--png, --strip-metadata)
tagx cover from-folder Album/*.mp3             # folder.jpg/cover.jpg/front.jpg (oder .png) aus dem Ordner einbetten
tagx cover to-folder song.mp3                  # eingebettetes Cover als folder.jpg schreiben (--force ersetzt)
tagx chapters show buch.m4b --json             # Kapitel als JSON (Zeiten in ms)
tagx chapters set buch.m4b --from kapitel.txt  # Kapitel ersetzen (JSON oder Zeilen "HH:MM:SS.mmm Titel")
tagx chapters clear buch.m4b                   # alle Kapitel entfernen
tagx layers show song.mp3 --json               # Tag-Schichten (ID3v1/ID3v2/APE …) mit Version und Feldern
tagx layers strip song.mp3 --layer id3v1       # eine Schicht entfernen, die anderen bleiben
tagx set song.mp3 -t TITLE=X --id3v23          # ID3v2.3 statt v2.4 schreiben (alte Player)
tagx lyrics set song.mp3 --from song.lrc --language deu   # LRC → SYLT (+ Text, Sprache)
tagx lyrics set song.flac --from song.lrc      # ohne ID3v2: schreibt die Sidecar song.lrc
tagx lyrics show song.mp3 --lrc                # synchronisierte Zeilen als LRC
tagx lyrics export song.mp3                    # → song.lrc (ohne Sync: .txt)
tagx set song.mp3 -t REPLAYGAIN_TRACK_GAIN="-6.50 dB" PODCAST=1 TVSEASON=2   # geprüft, Exit 1 bei ungültigem Wert
tagx exif set foto.jpg --copy description=IFD0:ImageDescription
tagx exif set IMG_0001.cr2 --rating 5        # RAW: landet in IMG_0001.xmp
tagx exif set foto.jpg --sidecar --title X   # jedes Bild: Sidecar statt Datei
tagx ebook set buch.epub --series "Foundation" --series-index 2
tagx doc set bericht.docx --title "Q3-Bericht" --keywords "Vertrieb, 2026"
tagx doc set comic.cbz --custom Series=Foo Number=2   # ComicInfo-Zusatzfelder
tagx playlist show album.cue                   # Kopf, Tracks, aufgelöste Pfade, fehlende Dateien, Gesamtdauer
tagx playlist set liste.m3u8 --title "Mix" --entry-title 2="Zweites Lied"
tagx playlist export --out Album/album.m3u8 Album/*.flac   # relative Pfade; --absolute, --format pls|xspf
tagx cue apply album.cue --apply               # Cue-Titel/-Interpreten/-Tracknummern in die Audiodateien schreiben
tagx nfo set film.mkv --title "Titel" --year 2019     # schreibt film.nfo, nicht das Video
tagx subtitle show film.de.srt --json          # Cues, Zeitspanne, Zeichensatz, Sprache
tagx subtitle shift film.srt --seconds=-1.5    # alle Cues verschieben (negativ: mit "=")
tagx check Musik/ --json                       # Konsistenzbericht je Album/Ordner (Cover, Track-Lücken, leere Felder …)
tagx check Album/ --fail-on warning            # Exit 4 bei Warnungen; --only track-gap,missing-cover; -p '%{track:2} - %{title}'
tagx history list song.mp3                     # Papierkorb-Sicherungen dieser Datei (Undo-Historie), jüngste zuerst
tagx history restore song.mp3 --version 1 --apply   # jüngste Sicherung zurückholen (ohne --apply nur Vorschau)
tagx apply --example > regeln.json             # kommentierte Beispiel-Regeldatei
tagx apply regeln.json Album/                  # Vorschau: FELD: alt -> neu je Datei
tagx apply regeln.json --apply Album/          # Änderungen schreiben (Papierkorb-Kopie, atomarer Austausch)
tagx export Album/ -o tags.json                # alle Tags sichern (Cover eingebettet)
tagx import --dry-run tags.json                # Wiederherstellung als Vorschau
tagx info video.mkv                            # vollständiger mediainfo-Bericht
tagx invoice rechnung.pdf                      # E-Rechnung: Profil, Hinweise + alle Felder (BT-Nummern)
tagx invoice bestellung.xml --strict           # Exit 3, wenn die Grundvalidierung Hinweise meldet
TAGX_ONLINE=1 tagx lookup Album/*.flac         # MusicBrainz-Kandidaten + Plan (alt -> neu), nur Vorschau
TAGX_ONLINE=1 tagx lookup --source discogs --choose 2 --apply --cover Album/*.flac   # Kandidat 2 samt Cover schreiben
TAGX_ONLINE=1 TAGX_ACOUSTID_KEY=… tagx lookup --source acoustid song.mp3   # per Fingerabdruck erkennen (fpcalc); Exit 5 = kein Treffer
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
bleibt. Scheitert die Endprüfung der eingesetzten App, wird eine vorhandene
Installation wiederhergestellt; eine abgelehnte Erstinstallation wird entfernt.

Core-Bibliothek und CLI bleiben frei von AppKit/SwiftUI und bauen und testen
auch unter Linux (CI-Job auf Ubuntu 24.04; `scripts/linux-deps.sh` installiert
die Abhängigkeiten und baut TagLib 2.3.1 aus dem Quelltext, weil das
Distributionspaket noch TagLib 1.x ist). Der abgesicherte Modus funktioniert
dort ebenfalls: Die Sicherungskopie landet im freedesktop-Papierkorb
(`~/.local/share/Trash`, auf anderen Datenträgern `.Trash-<uid>` im
Einhängepunkt), den jeder Dateimanager anzeigt. Architektur und Meilensteine
stehen in [docs/PLAN.md](docs/PLAN.md), der Release-Ablauf in
[docs/sparkle-release.md](docs/sparkle-release.md).

## Lizenz

MIT (siehe [LICENSE](LICENSE)), © 2026 Daniel Müller.

TagLib (LGPL-2.1-or-later oder MPL-1.1) wird dynamisch gelinkt und im
App-Bundle mitgeliefert, bleibt dort also austauschbar. Der Bibliothekscode
bleibt dabei unverändert; nur die Install-Namen werden auf den Ordner im
Bundle umgebogen und die Dateien neu signiert. Ebenfalls gelinkt
sind Sparkle (MIT), ZIPFoundation (MIT) und swift-argument-parser (Apache-2.0).
mediainfo (BSD-2), exiftool (Artistic/GPL) und Calibres `ebook-meta` (GPL)
werden weder gebündelt noch gelinkt, sondern nur als externe Programme
aufgerufen. Die Feldbezeichnungen der E-Rechnungs-Anzeige folgen dem
semantischen Modell der EN 16931 und den UNTDID-/UN-ECE-Codelisten; es wird
kein Text aus den Normdokumenten wiedergegeben, die Kurzbezeichnungen sind
eigene Formulierungen. Vollständige Lizenztexte und die Begründung:
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Die Demo-Dateien und Cover in den Screenshots sind vollständig für diese
Dokumentation generiert — die Titel, Autoren und Künstler existieren nicht.

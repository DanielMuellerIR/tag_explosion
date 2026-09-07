# Changelog

Produktgeschichte von Tag Explosion. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei beginnt mit 0.16.0. Die Entwicklungsschritte davor stehen in den
Meilensteinen in [docs/PLAN.md](docs/PLAN.md); die ausführliche Begründung
jeder Entscheidung steht im jeweiligen Commit.

## 0.46.15 — 2026-09-08

- Die App berücksichtigt beim Wiederherstellen von LRC-, NFO- und XMP-
  Sicherungen deren Lesestand. Fremde Änderungen und neu angelegte Sidecars
  bleiben bei einem Konflikt erhalten.
- Core und CLI unterscheiden beim Restore bekannte Existenz, Abwesenheit
  und unbekannten Zustand. Ein inzwischen gelöschtes bekanntes Ziel wird
  nicht ungefragt neu angelegt. Der bisherige Stempel-Aufruf bleibt verfügbar.

## 0.46.14 — 2026-09-08

- Linux-Abhängigkeiten enthalten `zip` für vollständige Fixtures; die
  TagLib-Bauparallelität lässt sich mit `TAGX_BUILD_JOBS` begrenzen.
- Die CI startet unmittelbar `swift test`, das Core, CLI und App selbst
  baut. Separate vorgeschaltete Builds entfallen.
- Der Plist-Test verwendet vorhandene Debug-Artefakte. Seine beiden Builds
  benötigten lokal 3 statt 71 Sekunden; die Bundle-Prüfung bleibt erhalten.

## 0.46.13 — 2026-09-08

- Archivziele werden über Mengen kanonischer Pfade und Dateiidentitäten
  dedupliziert. Eine lokale Prüfung mit 10.000 Zielen sank von 6,38 auf
  0,54 Sekunden; Symlink- und Hardlink-Kollisionen werden weiter abgelehnt.
- NFO-Daten in Audio-, Bild-, E-Book- oder Dokument-Einträgen werden vor
  dem Import abgelehnt. Archivtests räumen ihre temporären Medienordner auf.

## 0.46.12 — 2026-09-08

- Journale mit unbekannter Formatversion bleiben unverändert; schreibende
  Operationen melden einen Fehler. Mehrere defekte Journale werden getrennt
  aufbewahrt, statt die vorherige Diagnosekopie zu löschen.
- `history restore` prüft bei Sidecar-Versionen den Stempel der tatsächlichen
  Zieldatei. Ein bislang fälschlicher Konflikt mit dem Medium entfällt.
- Restore-Tests sind auch unter Linux aktiviert und räumen ihre eigenen
  Dateien auf. Ein Test ohne Bezug zum geprüften Journal wurde entfernt.

## 0.46.11 — 2026-09-08

- FileEntry nutzt beim Öffnen und Neuladen denselben Weg zum Übernehmen
  der Daten. Neue Felder müssen dadurch an weniger Stellen ergänzt werden.
- Beim Übertragen eines Eintrags auf einen neuen Pfad bleiben nun auch
  bearbeitete Kapitel, synchronisierte Lyrics und deren Sprache erhalten.

## 0.46.10 — 2026-09-08

- LRC und Video-NFO werden auch bei reinen Sidecar-Änderungen gemeinsam
  geprüft und gesichert. Ungültige NFO-Felder verhindern damit einen
  vorzeitigen LRC-Austausch; nach Korrektur gelingt der erneute Versuch.
- Beide Audio-Speicherzweige teilen Vorbereitung und Sidecar-Schreiber.
  Bei späteren Fehlern nennt die App bereits geschriebene Dateien.

## 0.46.9 — 2026-09-08

- Lyrics-Sidecars erkennen auch fremdes Anlegen oder Löschen seit dem Lesen.
  App und CLI unterscheiden bekannte Abwesenheit vom bewusst ungeprüften
  Überschreiben. Vorab erkannte Konflikte verhindern Änderungen an beiden Dateien.
- XMP und LRC teilen den Typ für den Sidecar-Lesestand; der bisherige
  LRC-Schreibaufruf mit optionalem Dateistempel bleibt verfügbar.

## 0.46.8 — 2026-09-08

- Core- und CLI-Konflikttests verwenden dieselbe Hilfe für den atomaren
  Dateiaustausch. Die Fixture-Sperre wird nicht an gestartete Werkzeuge vererbt.

## 0.46.7 — 2026-09-08

- Lyrics, deren Sprache und Video-NFO-Felder behalten Eingaben, die erst
  während eines laufenden Speichervorgangs begonnen wurden.
- Doppelte Testhilfen und AVI-Lesetests zusammengeführt; der Test für
  konsistente Dateischnappschüsse prüft nun auch den zurückgegebenen Inhalt.

## 0.46.6 — 2026-09-08

- Core-, CLI- und App-Tests teilen die Fixture-Erzeugung und Kopierhilfe.
  Eine Dateisperre verhindert überlappende Erzeugung in parallelen Testprozessen.
- Fehlende DOCX-/Comic-Varianten werden auch dann ergänzt, wenn ihre Basisdatei
  schon existiert. Vorhandene Dateien bleiben dabei bytegleich; vollständige
  Fixture-Sätze benötigen keinen erneuten ffmpeg-Aufruf.

## 0.46.5 — 2026-09-08

- Core- und CLI-Tests teilen einen Prozessstarter statt 16 Kopien. Er verwendet
  das Binary aus der laufenden Testkonfiguration und beendet hängende Prozesse
  mit einem Fehler. Wiederholte SwiftPM-Unterprozesse entfallen.
- Die unveränderte CLI-Suite mit 51 Tests benötigte im lokalen Vergleich
  1,12 statt 6,93 Sekunden; ein zusätzlicher Test prüft die Prozessfrist.

## 0.46.4 — 2026-09-08

- Sicherungen erkennen fremde Änderungen während der Kopie, bevor Größe und
  Prüfsumme als gesicherte Version im Journal landen.
- Der XDG-Papierkorb lehnt umgebogene oder fremd beschreibbare Verzeichnisse ab,
  ordnet verknüpfte Datenverzeichnisse dem richtigen Datenträger zu und ignoriert
  relative XDG-Datenpfade.
- Überlappende Sicherungstests zusammengeführt, temporäre Quellen aufgeräumt
  und die exklusive Dateineuanlage einschließlich Konflikten direkt geprüft.

## 0.46.3 — 2026-09-07

- ZIP-Dokumente behalten beim Speichern ihre äußeren Dateirechte, ACLs und
  erweiterten Attribute. Temporäre ZIP-Inhalte entstehen in einem privaten
  Verzeichnis und werden erst nach erfolgreichem Schreiben ausgetauscht.

## 0.46.2 — 2026-09-05

- Der MediaInfo-Abbruchtest lässt seinem gesteuerten Leser unter paralleler
  CI-Last mehr Zeit und gibt ihn auch bei einer fehlgeschlagenen Voraussetzung
  frei. Das Verhalten der App bleibt unverändert.

## 0.46.1 — 2026-09-05

- Laufende Speicheraufträge sperren konkurrierende Entfernen-/Import-/Schließen-
  Aktionen für alle Auftragsziele. Bestätigte Konfliktwiederholungen warten auf
  das Auftragsende und starten keinen parallelen Schreiber.
- Speicherfortschritt und Abbruch sind auch direkt unter der Dateiliste sichtbar.
- Mehrwertige Regelketten zusätzlich per CLI in MP3 und M4A geprüft; die Tests
  vergleichen die vollständigen JSON-Wertelisten.

## 0.46.0 — 2026-09-05

- FileEntry samt Speicher-Snapshots, geladene Daten, Ladeablauf und Medien-IO
  aus AppModel in ihre zuständigen Dateien verschoben. IO erhält Schreiboptionen
  als Parameter und kennt keinen Fensterzustand; Konfliktentscheidungen bleiben
  zentral im AppModel. Keine Änderung der Format- oder Speicherregeln.

## 0.45.0 — 2026-09-05

- `tagx info` startet nur die angeforderte JSON- oder Textabfrage.
- Die MediaInfo-Ansicht teilt identische Leseaufträge und nutzt einen nach
  Dateistempel invalidierten Cache (acht Berichte, acht MiB Textdaten).
- Abbruch beendet den eigenen Abonnenten sofort; beim letzten Abonnenten
  wird die Prozessgruppe mit SIGTERM, nötigenfalls SIGKILL beendet. Auch
  geerbte Ausgabepipes blockieren den Abschluss dann nicht mehr.

## 0.44.1 — 2026-09-05

- Gemeinsame Prozessausführung, Werkzeugauflösung und Byte-Dekodierung aus
  MediaInfoReader in ExternalToolRunner/ExternalToolText verschoben.
  ExifTool, Calibre und AcoustID verwenden diese Mechanik direkt; Verhalten
  und kompatible MediaInfo-Einstiege bleiben unverändert.

## 0.44.0 — 2026-09-05

- Dateiliste mit Suche, Medienart-/Änderungs-/Fehlerfilter und stabiler Sortierung.
  Ausgeblendete Auswahl bleibt erhalten und wird gezählt; gemischte Auswahl
  lässt sich auf eine Medienart begrenzen.
- Konsistenzprüfung läuft nach 250 ms Eingabepause im Hintergrund auf Snapshots.
  Veraltete Ergebnisse und Berichte zu ungültigen Mustern werden verworfen.

## 0.43.0 — 2026-09-05

- Speicheraufträge behalten Status und Ursache je Datei in einer Ergebnisliste.
  Fehlgeschlagene Dateien lassen sich gezielt wiederholen; Abbruch überspringt
  die verbleibenden Dateien nach dem laufenden sicheren Schreibvorgang.
- Konfliktentscheidungen aktualisieren das Dateiergebnis. Scheitert eine
  Audio-Sidecar nach dem Container, nennt die Fehlermeldung bereits geschriebene
  Ziele; der Bearbeitungspuffer bleibt erhalten.

## 0.42.0 — 2026-09-05

- Öffnen zeigt fertige Einträge während weitere Leser arbeiten. Dateizähler
  und Abbruch stehen unter der Dateiliste. Laufende Leser dürfen auslaufen;
  weitere Starts enden, Reservierungen werden anschließend freigegeben.
- Eingabereihenfolge, vorhandene Puffer und Benutzerauswahl bleiben erhalten.

## 0.41.0 — 2026-09-05

- Audio-Regeln erhalten mehrere Werte pro Feld bei Bereinigung und Kopieren.
  App und CLI zeigen vollständige Listen in der Vorschau; bestehende Regeldateien
  und skalare JSON-Felder bleiben kompatibel.
- CLI-Regelpläne prüfen den Dateistempel vor dem Schreiben; doppelte Eingabepfade
  erzeugen keine doppelten Aufträge.

## [0.40.0] — 2026-09-03

Abarbeitung des Code-Reviews vom 2026-09-02 (20 Funde, alle behoben).

### Behoben

- Lyrics-CLI: `lyrics set --sidecar` bei ID3v2-Dateien war für `show`,
  `export` und `clear` unsichtbar. Jetzt gilt überall dieselbe Regel:
  eingebettete SYLT-Zeilen haben Vorrang, sonst zählt die Sidecar
  `<name>.lrc` — auch bei MP3. `--sidecar` neben vorhandenem SYLT wird
  abgelehnt statt still geschrieben; `clear` räumt beide Speicherorte.
- App: Die `.lrc`-Sidecar bekommt beim Lesen einen eigenen Dateistempel.
  Ändert ein anderes Programm sie zwischen Öffnen und Speichern, erscheint
  der Konfliktdialog wie beim Medium; „Trotzdem überschreiben“ gilt dann
  auch für die Sidecar. Die CLI prüft den Stempel ebenso.
- App: Audio-Speichern läuft zweiphasig — erst Stempel, Feldprüfung und
  Papierkorb-Sicherung der Sidecars (`.lrc`, NFO), dann der Container,
  zuletzt der Sidecar-Austausch. Ein Save übernimmt so nie Containerfelder,
  während die Lyrics-Änderung an einem Sicherungsfehler scheitert.
- App: Die NFO-Felder neben einem Video liegen jetzt im Eintrag und werden
  mit ihm gespeichert (⌘S). Sie zählen zu den ungespeicherten Änderungen —
  Schließen und Beenden fragen nach, statt Eingaben still zu verwerfen. Am
  Video selbst ändert sich dabei nichts, wenn nur die NFO bearbeitet wurde.
- Kapitel: Überlappende Bereiche (`[0,1000]`, `[500,1500]`) werden wie
  dokumentiert abgelehnt; bisher prüfte die Validierung nur den Beginn gegen
  den vorigen Beginn.
- `tagx playlist export --force` und das Anlegen eines neuen Ordner-Covers
  (`folder.jpg`) laufen jetzt über Papierkorb-Sicherung beziehungsweise die
  geprüfte Geschwisterkopie mit atomarem Austausch wie jeder andere
  Schreibweg; ein Abbruch hinterlässt keine halbe Datei mehr.
- Untertitel-Verschiebung: Riesige oder unendliche Sekundenwerte (`1e16`,
  `inf`) enden als Fehler statt als Laufzeitabbruch (CLI und App); zulässig
  sind bis zu 1000 Stunden.
- NFO-Prüfung: `rating`/`userrating` nur als Zahl von 0 bis 10; `premiered`
  nur als existierender Kalendertag (`2026-02-31` wird abgelehnt).
- Markdown-Frontmatter: Leer- und Kommentarzeilen hinter einem geänderten
  oder entfernten Wert bleiben stehen.
- Playlists: Windows-Pfade (`C:\…`, `\\server\…`) gelten als absolut und
  werden nicht mehr an den Playlist-Ordner gehängt; unendliche oder riesige
  `#EXTINF`-/`Length`-Werte werden als unbekannte Dauer gelesen statt den
  Prozess zu beenden; Zeilenumbrüche in Titel oder Interpret landen beim
  M3U-/PLS-Export auf einer Zeile.
- Konsistenzprüfung: Track- und Disc-Nummern 0 oder negativ sind eigene
  Befunde (`track-invalid`, `disc-invalid`) und verdecken keine Lücken mehr.
- `lyrics set` lehnt Nicht-Audio (Bilder, Dokumente, unbekannte Endungen)
  vor dem Öffnen mit klarer Meldung ab.
- Umbenennen: Neben `.xmp` wandern jetzt auch `.lrc` (Audio) und `.nfo`
  (Video) mit; schlägt der Rückweg nach einem Sidecar-Fehler fehl, nennt das
  Ergebnis den Zustand ausdrücklich. Die Undo-Historie folgt dem neuen Namen
  (Journalpfade werden nachgezogen) und zeigt bei Audio und Video auch die
  Sicherungen ihrer `.lrc`-/`.nfo`-Sidecars.

## [0.39.0] — 2026-09-03

### Hinzugefügt

- Abgesicherter Modus unter Linux: Die Papierkorb-Sicherung folgt dort der
  freedesktop-Spezifikation (`~/.local/share/Trash/files` plus `.trashinfo`,
  auf anderen Datenträgern `.Trash/<uid>` oder `.Trash-<uid>` im
  Einhängepunkt). Damit laufen `set`, `cover`, `import` und die anderen
  ändernden `tagx`-Befehle unter Linux ohne `--no-backup`; die Kopie bleibt
  wie unter macOS auf dem Datenträger des Originals. Neuer Typ `XDGTrash`
  im Core, auf allen Plattformen testbar.
- Linux-Job in der Test-CI (Ubuntu 24.04, TagLib 2.3.1 aus dem Quelltext
  über `scripts/linux-deps.sh`); dasselbe Skript richtet einen lokalen
  `swift:6.0`-Docker-Container ein.

### Geändert

- Freiplatz-Prüfung vor dem Schreiben nutzt unter Linux `statvfs`
  (`attributesOfFileSystem`); die Volume-Schlüssel von `URL.resourceValues`
  gibt es dort nicht.

### Behoben

- Release-Build (`build.sh --release`) gegen die portable TagLib 2.1.1 brach
  im Shim ab, weil `mp4file.h` nur zusammen mit dem Kapitel-Header von
  TagLib 2.3 eingebunden wurde. Hinweis: Das verteilte DMG bringt TagLib
  2.1.1 mit (Mindestversion macOS 14); MP4- und Matroska-Kapitel brauchen
  TagLib 2.3 und sind dort deshalb nicht verfügbar, ID3-Kapitel (MP3) schon.
- Linux: Untertitel und Kodi-NFOs in Latin-1 oder Windows-1252 mit
  CRLF-Zeilenenden ließen sich weder lesen noch zurückschreiben
  (Linux-Foundation kodiert und dekodiert `\r\n` in diesen Kodierungen
  nicht; Umweg über `NSString` in `TextEncoding.swift`).
- Linux: Die Undo-Historie bekommt jetzt auch ohne CryptoKit SHA-256-
  Prüfsummen (`PortableSHA256`), damit „Zurückholen" die Kopie prüfen kann.
- mediainfo-Aufruf ohne UTF-8-Locale (Container, CI, `LANG=C`) lieferte
  Umlaute als „?"; der Wrapper gibt jetzt `LC_ALL=C.UTF-8` mit, wenn keine
  UTF-8-Locale gesetzt ist.

## [0.38.0] — 2026-09-02

### Hinzugefügt

- Online-Lookup: „Online nachschlagen …“ im Einzel- und Batch-Editor fragt
  MusicBrainz oder Discogs nach einem Release oder erkennt eine Datei per
  AcoustID-Fingerabdruck (`fpcalc`); Kandidatenliste, Zuordnung Datei → Titel
  (Tracknummer, sonst Dauer ±3 s und Titelähnlichkeit), Vorschau alt → neu je
  Feld, Cover-Vorschau. „Übernehmen“ füllt nur den Editor, gespeichert wird
  wie gewohnt. Schreibt MusicBrainz-, Discogs- und AcoustID-Kennungen.
  Netz- und Datenschutzregeln:
  [knowledge/online-lookup-dienste.md](knowledge/online-lookup-dienste.md).
- `tagx lookup [--source musicbrainz|discogs|acoustid] [--choose n] [--apply]
  [--cover] [--json]` (Probelauf per Voreinstellung, Exit 5 ohne Treffer;
  ohne `TAGX_ONLINE=1` kein Netzzugriff, `--privacy` zeigt den
  Datenschutzhinweis).
- Einstellungen „Online-Dienste erlauben“ (Voreinstellung aus), Discogs-Token
  und AcoustID-Key in der Keychain; Datenschutzhinweis vor der ersten
  Anfrage; Homebrew-Angebot für `chromaprint`, wenn `fpcalc` fehlt. Keine
  Suche beim Öffnen, keine Telemetrie.

### Geändert

- `tagx` wartet auf Netzantworten asynchron (Wurzelbefehl ist jetzt
  `AsyncParsableCommand`; übrige Befehle unverändert).

### Bekannte Grenzen

- Discogs- und AcoustID-Pfade sind nur mit Stub-Antworten getestet, nicht
  gegen die echten Dienste. AcoustID nimmt den Fingerabdruck der ersten Datei.

## [0.37.0] — 2026-09-02

### Hinzugefügt

- Batch-Regeln als Skript: JSON-Regeldatei mit den Aktionen `set`
  (Platzhalter wie `%{artist}`), `copy` (wahlweise nur in leere Felder),
  `replace` (wörtlich oder Regex mit Gruppen), `case` (Groß, Klein,
  Titel-Schreibweise mit einstellbaren kleinen Wörtern, Satz-Schreibweise),
  `trim`, `remove` und `number` (Tracknummern nach Dateiname oder Feld,
  wahlweise `n/gesamt`); je Regel Filter nach Medienart und Feld-Bedingung.
  Fallen: [knowledge/batch-regeln.md](knowledge/batch-regeln.md).
- `tagx apply <regeln.json> [--apply] [--json] <Dateien|Ordner>`: Probelauf
  per Voreinstellung mit Plan „Feld: alt -> neu“, `--example` gibt eine
  kommentierte Beispieldatei aus, Exit 64 bei ungültiger Regeldatei (Meldung
  nennt Regelnummer und Zeile).
- Batch-Editoren: „Regeln anwenden …“ mit Regel-Editor, Vorlagen,
  Laden/Speichern als JSON, zuletzt benutzten Regeldateien und
  Vorschautabelle; Anwenden schreibt über den gewohnten Speichern-Weg.

### Geändert

- kid3-Abgleich: Groß-/Kleinschreibungs-Werkzeuge gelten als umgesetzt.

### Bekannte Grenzen

- Die Regel-Engine sieht nur den ersten Wert mehrwertiger Felder; die
  Titel-Schreibweise macht aus „DJ“ ein „Dj“.

## [0.36.0] — 2026-09-02

### Hinzugefügt

- Undo-Historie: Jede Papierkorb-Sicherung wird in einem Journal
  (`Application Support/TagExplosion/backup-journal.json`) mit Originalpfad,
  Sicherungspfad, Zeit, Größe, SHA-256 und Auslöser verzeichnet. Der Knopf
  „Versionen …“ im Einzel-Editor (Audio, Bild, E-Book, Dokument) listet die
  Sicherungen, zeigt je Version die geänderten Felder und stellt eine Version
  nach Rückfrage wieder her; „Ablage → Letzte Änderung rückgängig“ (⌘⇧Z)
  holt die jüngste zurück. Wiederherstellen sichert vorher den jetzigen
  Stand, ein Undo bleibt also selbst umkehrbar. Begründung und Regeln:
  [knowledge/undo-historie-journal.md](knowledge/undo-historie-journal.md).
- CLI `tagx history list|diff|restore|prune` (Restore ohne `--apply` als
  Vorschau; `prune` räumt nur Journal-Einträge, nie den Papierkorb).

### Geändert

- `TrashBackup.backUp` nimmt einen Auslöser (`reason:`) entgegen; Einträge,
  deren Kopie im Papierkorb fehlt, gelten als verfallen und erscheinen nicht
  mehr in der Liste.

### Bekannte Grenzen

- Nach einem Umbenennen kennt das Journal nur den alten Pfad. `--version <n>`
  erscheint in der Hilfe neben ArgumentParsers globaler Versionsanzeige.

## [0.35.0] — 2026-09-02

### Hinzugefügt

- Konsistenzprüfung über Ordner und Auswahlen: fehlendes oder im Album
  uneinheitliches Cover, Album-Interpret uneinheitlich oder bei einer
  Compilation fehlend, Track- und Disc-Nummern (fehlend, Lücken, Dubletten,
  ohne Gesamtzahl, größer als die Gesamtzahl), Jahr, Genre und
  Album-Schreibweise je Album, leere Felder Titel/Interpret/Album, gleicher
  Titel + Interpret + Dauer (±2 s) über alle Dateien, optional Dateinamen
  gegen ein Muster. Bilder, E-Books und Dokumente nur auf leeren Titel
  (E-Books auch auf fehlendes Cover). Keine automatischen Korrekturen.
  Fallen: [knowledge/konsistenzpruefung.md](knowledge/konsistenzpruefung.md).
- `tagx check` mit `--json`, `--pattern`, `--only <codes>` und
  `--fail-on warning|hint` (Exit 4 bei Befunden ab dem Schweregrad).
- In der App „Prüfen …“ im Batch-Editor und ein Werkzeugleisten-Knopf für
  alle geladenen Dateien; Ergebnis-Sheet je Album/Ordner, Klick auf eine
  Datei wählt sie aus, Bericht als Text kopierbar.

## [0.34.0] — 2026-09-02

### Hinzugefügt

- Cover-Werkzeuge: Das Cover-Feld zeigt Format, Maße, Dateigröße und
  Prüfhinweise (zu klein, zu groß, nicht quadratisch, progressives JPEG,
  CMYK). Kontext- und Zahnradmenü: Verkleinern auf 500/1000/1500 px, nach
  JPEG wandeln, Bild-Metadaten entfernen, Ordner-Cover (folder/cover/front
  .jpg/.png) übernehmen, Cover als `folder.jpg` exportieren, im Einzel- und
  Batch-Editor. Fallen:
  [knowledge/cover-werkzeuge.md](knowledge/cover-werkzeuge.md).
- CLI: `tagx cover info [--json] [--strict]`,
  `tagx cover convert --max-size <px> [--jpeg <q>|--png] [--strip-metadata]`,
  `tagx cover from-folder`, `tagx cover to-folder [--force]`; auch für EPUB
  und Calibre-Formate.

### Geändert

- Fixture-Generator erzeugt zusätzlich `cover-large.jpg` und
  `cover-alpha.png`.

### Bekannte Grenzen

- Unter Linux fehlt die Neukodierung (ImageIO); Analyse und Metadaten-Strip
  laufen dort. Der E-Book-Editor hat das Cover-Menü noch nicht, die CLI deckt
  E-Books ab.

## [0.33.0] — 2026-09-02

### Hinzugefügt

- Lyrics als eigenes mehrzeiliges Feld mit Sprache (ID3v2 USLT);
  synchronisierte Lyrics als ID3v2 SYLT mit LRC-Import/-Export, für Formate
  ohne ID3v2 als Sidecar `<name>.lrc`; `tagx lyrics show|set|export|clear`.
- ReplayGain (Track/Album Gain und Peak) und Opus-R128 als geprüfte Felder
  mit Wertebereich; R128 wird als dB angezeigt. Ungültige Werte werden mit
  Feldname abgelehnt, bevor etwas gesichert oder geschrieben wird
  (`tagx set` Exit 1). Lautheit wird nicht berechnet, nur gelesen,
  geschrieben und geprüft.
- Podcast-Felder für MP3 und MP4 (Flag, Feed-URL, GUID, Kategorie,
  Stichwörter, Staffel, Episode, Beschreibungen) mit eigenem Abschnitt im
  Editor; der Batch-Editor setzt die Album-Lautheit für alle Dateien.
  Fallen: [knowledge/feste-felder-lyrics-lautheit-podcast.md](knowledge/feste-felder-lyrics-lautheit-podcast.md).

### Geändert

- Podcast-Flag, Stichwörter, Staffel/Episode (ID3) und lange Beschreibung
  (MP4) laufen als Frame/Atom statt über TagLibs PropertyMap; dort ging das
  PCST-Flag beim nächsten Speichern verloren.

### Bekannte Grenzen

- Umbenennen nimmt die `.lrc`-Sidecar noch nicht mit; die Sidecar hat keinen
  Stempel-Konfliktschutz.

## [0.32.0] — 2026-09-02

### Hinzugefügt

- Video-Sidecars als eigene Medienart: Kodi/Jellyfin `.nfo` (movie,
  episodedetails, tvshow, musicvideo, album, artist) anzeigen und bearbeiten;
  unbekannte Elemente, Reihenfolge und Einrückung bleiben erhalten, Nur-URL-
  NFOs werden angezeigt, nie beschrieben. Ein Video mit `<name>.nfo` daneben
  zeigt im Editor den Abschnitt „NFO-Sidecar“ (schreibt nur die NFO);
  Ordner-Drops blenden die NFO eines gelisteten Videos aus. Fallen:
  [knowledge/kodi-nfo-untertitel.md](knowledge/kodi-nfo-untertitel.md).
- Untertitel `.srt`/`.vtt`: Cues, Zeitspanne, Zeichensatz, Sprache und Flags
  aus dem Dateinamen, WebVTT-Kopf (Titel und `Language:` editierbar) und
  Zeitverschiebung aller Cues.
- CLI `tagx nfo show|set` und `tagx subtitle show|set|shift --seconds`;
  Muster `%{base}.%{lang}` zum Umbenennen von Untertiteln.
- Tag-Archiv sichert NFO-Felder (Schema 4); Untertitel bleiben außen vor.

### Bekannte Grenzen

- Der NFO-Abschnitt im Video-Editor hat einen eigenen Speichern-Knopf und
  hängt nicht an der Schließen-Rückfrage. Umbenennen eines Videos nimmt
  `.nfo`/`.srt` noch nicht mit.

## [0.31.0] — 2026-09-02

### Hinzugefügt

- Playlists und Cue-Sheets als neue Medienart: `.cue`, `.m3u`, `.m3u8`,
  `.pls`, `.xspf` anzeigen (Einträge mit aufgelöstem Pfad, Existenzprüfung,
  Gesamtdauer) und beschriften (Titel, Interpret, bei Cue-Sheets Datum und
  Genre; Titel/Interpret je Eintrag). Fremde Zeilen, Zeilenenden und
  Einrückung bleiben erhalten; Nicht-UTF-8-Dateien werden per
  Latin1/MacRoman-Fallback gelesen. Fallen:
  [knowledge/playlists-cue.md](knowledge/playlists-cue.md).
- Playlist-Export aus einer Dateiauswahl als m3u8, pls oder xspf (Pfade
  relativ zur Playlist, optional absolut): Menü „Playlist exportieren …“ im
  Batch-Editor und `tagx playlist export`.
- `tagx playlist show|set`, `tagx cue show|set` und `tagx cue apply`, das
  Titel, Interpreten und Tracknummern eines Cue-Sheets in die referenzierten
  Audiodateien schreibt (Probelauf als Voreinstellung, `--apply`; nur bei
  einer Datei je Track).
- Playlist-Editor in der App; Doppelklick auf einen Eintrag öffnet die Datei
  in einem neuen Fenster.

### Geändert

- Tag-Archiv (Export/Import) und Dateinamen-Muster lassen Playlists aus, wie
  bereits E-Rechnungen.

## [0.30.0] — 2026-09-02

### Hinzugefügt

- E-Rechnungen: Order-X-Bestellungen (BASIC/COMFORT/EXTENDED, auch als
  `order-x.xml` im PDF) sowie Peppol UBL Order und OrderResponse werden
  erkannt; ihre Felder tragen Order-X-Bezeichnungen ohne BT-Nummern, weil
  die Order-X-Nummerierung nicht verlässlich belegt werden konnte.
- Dokumentart (Rechnung, Gutschrift, Bestellung, Bestellantwort) als eigenes
  Feld in Ansicht und `tagx invoice --json` (`documentKind`); CII mit
  Typcode 381 gilt als Gutschrift.
- Grundvalidierung mit Hinweisen: fehlende Pflichtfelder nach EN 16931
  (XRechnung: auch Leitweg-ID) und Summenrechnung BT-106 … BT-115 mit
  Toleranz 0,01, Regelcodes der Norm (BR-…, BR-CO-…, BR-DE-15). Abschnitt
  „Hinweise“ in der Rechnungsansicht, `WARNINGS` in `tagx invoice`;
  `--strict` liefert Exit 3. Keine Schematron-Prüfung.

### Geändert

- `tagx invoice --terms-only` behält auch beschriftete Order-X-Felder.

## [0.29.0] — 2026-09-02

### Hinzugefügt

- Tag-Schichten: Der Audio-Editor zeigt je Datei die Schichten ID3v1, ID3v2
  (mit Version 2.3/2.4), APEv2, RIFF INFO und Vorbis mit Feldanzahl und
  entfernt eine einzelne Schicht nach Rückfrage; die übrigen Schichten und
  der Audiostream bleiben unverändert (mp3/mp2, wav, aiff, flac, ape, mpc,
  wv, tta, dsf). CLI: `tagx layers show [--json]` und
  `tagx layers strip --layer id3v1|id3v2|ape|info|vorbis`.
- ID3v2.3-Schreiboption für alte Player: Einstellung „ID3v2.3 statt ID3v2.4
  schreiben“ (Voreinstellung aus) und `tagx set --id3v23` (mp3/mp2, wav,
  aiff, dsf). Grenzen von v2.3 (UTF-16, Datum ohne Sekunden, Originaldatum
  nur Jahr): [knowledge/id3-schichten.md](knowledge/id3-schichten.md).

### Geändert

- `TagData` trägt die Schichtenliste (`layers`); `TagFile.write` nimmt
  `id3Version:` entgegen. Schichten werden nur angezeigt und entfernt, nicht
  getrennt bearbeitet.

## [0.28.0] — 2026-09-02

### Hinzugefügt

- Dokument-Metadaten nativ ohne externe Programme: Office (docx, xlsx, pptx —
  `docProps/core.xml`, `app.xml` als Anzeige), OpenDocument (odt, ods, odp —
  `meta.xml`), Comic-Archive (cbz — `ComicInfo.xml`, erste Seite als Cover)
  und Markdown mit YAML-Frontmatter (fremde Schlüssel und Body bleiben
  erhalten). Einzel- und Stapel-Editor in der App, `tagx doc show|set` mit
  `--json`, Export/Import im Tag-Archiv (Schema 3), Menü „Dateiname“ auch
  für Dokumente. Fallen:
  [knowledge/dokument-container-metadaten.md](knowledge/dokument-container-metadaten.md).

### Geändert

- Felder, die ein Dokumentformat nicht speichern kann, werden vor Sicherung
  und Schreibweg mit Feldname abgelehnt statt still verworfen.
- cbr (RAR) bleibt außen vor: ohne fremde Bibliothek nicht lesbar.

## [0.27.1] — 2026-09-02

### Geändert

- Umbenennen aus Tags nimmt die XMP-Sidecar `<name>.xmp` eines Bildes mit auf
  den neuen Namen; ein belegtes Sidecar-Ziel blockiert den Eintrag als
  Konflikt. RAW+JPEG-Paare teilen sich weiterhin eine Sidecar.

## [0.27.0] — 2026-09-02

### Hinzugefügt

- Kamera-RAW (cr2, cr3, nef, arw, raf, orf, rw2, pef) sowie avif, jxl, bmp,
  psd, svg werden als Bilder gelesen; `.xmp` öffnet sich als eigenes Format
  (gleiche Felder, ohne Pixel).
- XMP-Sidecar: RAW-Dateien werden nie direkt beschrieben; Änderungen gehen in
  `<name>.xmp` daneben (wird bei Bedarf angelegt). Sidecar-Werte überlagern
  beim Lesen die eingebetteten feldweise; Bild- und Batch-Editor zeigen
  Herkunft und Schreibziel. Fallen:
  [knowledge/raw-xmp-sidecar.md](knowledge/raw-xmp-sidecar.md).
- Einstellung „Bild-Metadaten in XMP-Sidecar schreiben statt in die
  Bilddatei“ und `tagx exif set --sidecar`; `tagx exif show` meldet Sidecar,
  Sidecar-Felder und Schreibziel.

### Geändert

- Bilder mit vorhandener Sidecar und Formate ohne exiftool-Schreibweg (bmp,
  svg) schreiben immer in die Sidecar; die Papierkorb-Sicherung gilt dann der
  Sidecar.

## [0.26.0] — 2026-09-02

### Hinzugefügt

- Dateinamen aus Tags und Tags aus Dateinamen mit Mustern im kid3-Stil
  (`%{track:2} - %{artist} - %{title}`, jeder Tag-Schlüssel, `%{year}`,
  Nullen-Auffüllung). Die Muster-Engine liegt im Core; das Umbenennen zeigt
  eine Vorschau und verweigert Konflikte (doppelter Zielname, belegtes Ziel,
  leerer Name, Groß-/Kleinschreibung auf APFS) als Ganzes.
- `tagx rename` und `tagx parse`: Probelauf per Voreinstellung, `--apply`,
  `--json`, Exit-Code 2 bei Konflikt oder nicht passendem Muster. Das
  Schreiben der Tags läuft über den bestehenden abgesicherten Weg.
- Menü „Dateiname“ in Einzel- und Batch-Editoren für Audio, Bilder und
  E-Books mit Musterfeld, zuletzt benutzten Mustern, Vorgaben und
  Vorschautabelle; die Dateiliste folgt umbenannten Dateien.

### Geändert

- Umbenennen läuft bewusst ohne Papierkorb-Sicherung: Der Inhalt bleibt
  unverändert, `moveItem` überschreibt nie
  ([knowledge/dateiname-muster-umbenennen.md](knowledge/dateiname-muster-umbenennen.md)).

## [0.25.0] — 2026-09-02

### Hinzugefügt

- Weitere Audio-/Container-Endungen über TagLib: mp2, aifc, mka, 3gp/3g2
  (Tags und Cover; Matroska ohne Cover) sowie Tracker-Module mod, s3m, xm, it
  (Titel, Kommentar und Tracker-Name). Sun-AU (`au`) und Ogg-Video (`ogv`)
  öffnen zur Anzeige im Technik-Tab. Was TagLib davon wirklich kann:
  [knowledge/weitere-endungen-taglib.md](knowledge/weitere-endungen-taglib.md).
- Fixture-Generator erzeugt die neuen Formate per ffmpeg und Tracker-Module
  als synthetische Minimaldateien; Roundtrip-, Ablehnungs- und
  mediainfo-Cross-Check-Tests dazu.

### Geändert

- Der Editor sperrt Felder, die ein Format nicht speichern kann (Tracker:
  alles außer Titel/Kommentar), und das Cover-Feld bei Formaten ohne
  Cover-Speicherort (Tracker, mkv/mka/webm, Anzeige-Formate), statt erst
  beim Speichern zu scheitern.

## [0.24.0] — 2026-09-02

### Hinzugefügt

- Kapitel für Hörbücher und Podcasts: MP3 (ID3v2 CHAP/CTOC), MP4/M4A/M4B
  (Nero `chpl` und QuickTime-Kapitelspur, beide werden geschrieben) und
  Matroska/WebM lesen und schreiben. Grenzen und Fallen:
  [knowledge/kapitel-hoerbuch.md](knowledge/kapitel-hoerbuch.md).
- Editor-Abschnitt „Kapitel“ (nur bei Formaten mit Kapiteln): Titel, Beginn,
  Ende bearbeiten, Kapitel hinzufügen/entfernen, Import und Export als JSON
  oder Text (`HH:MM:SS.mmm Titel`).
- `tagx chapters show [--json]`, `tagx chapters set --from <json|txt|->`,
  `tagx chapters clear`; `tagx show` listet Kapitel mit.
- Roadmap der offenen Erweiterungen in [docs/ROADMAP.md](docs/ROADMAP.md).

### Geändert

- Tag- und Cover-Schreiben lässt vorhandene Kapitel in allen drei Formaten
  stehen (Test je Format).
- Fixture-Generator erzeugt zusätzlich Kapitel-Dateien per ffmetadata.

## [0.23.15] — 2026-08-30

### Geprüft

- Die CodeQA-Folgekampagne hat die acht durch den Review-Fix veränderten
  Bereiche erneut geprüft: atomare Dateisicherheit, Archivimport,
  TagLib-Roundtripgrenze, Installer-Distribution, E-Book-Schreiben,
  Bildmetadaten sowie CLI- und Prozessausgabe. Alle 14 Bereiche und vier
  Querschnittsthemen stehen damit wieder auf aktuellem Stand.
- Das Schichtenmodell mit gemeinsamem portablem Core, CLI-Adaptern,
  SwiftUI-Beobachtungsmodell und Fensterkoordinator bleibt passend, aber
  gespannt. Die große AppModel-Zustandsschicht bleibt die begründete spätere
  Teilungsgrenze; ein Paradigmenwechsel lohnt den Migrations- und Testaufwand
  nicht.
- Der Abschlusslauf bestand mit 176 Root-Tests in 14 Suites, 65 App-Tests in
  8 Suites und der vollständigen Installer-Rollback-Suite. Ein sichtbarer
  GUI-Lauf war für die nichtvisuellen Änderungen nicht erforderlich.

## [0.23.14] — 2026-08-30

### Behoben

- Der Archiv-Dry-run schreibt Bildwerte nun auf eine Geschwisterkopie und liest
  sie exakt zurück. Normalisiert exiftool einen Wert, lehnen Dry-run und Import
  ihn vor der Papierkorb-Sicherung ab; der Import setzt andernfalls genau die
  geprüfte Kopie atomar ein.
- Klartext und Fehlermeldungen behalten wörtliche Surrogate-Schreibweisen auch
  dann, wenn sie mit `[` oder `{` beginnen. JSON- und Klartext-Aufrufer wählen
  ihren Dekodierweg jetzt ausdrücklich.
- Der Installer-Regressionstest trägt Hintergrundprozesse nach jedem `wait`
  unabhängig vom Exit-Code aus und vergleicht vor dem Aufräumen zusätzlich
  Eltern-PID und Startzeit. Eine wiederverwendete Prozessnummer kann dadurch
  keinen fremden Prozess treffen.
- Der echte Bild-CLI-Test hängt nur noch von der getrackten Bild-Fixture und
  exiftool ab; fehlendes ffmpeg überspringt ihn nicht mehr.

### Geprüft

- 66 gezielte Archiv-, Bild-, Dekodier- und CLI-Tests sowie die vollständige
  Installer-Rollback-Suite bestanden.

## [0.23.13] — 2026-08-29

### Geprüft

- Die CodeQA-Kampagne ist mit allen 14 Bereichen auf aktuellem Stand und
  allen vier Querschnittsthemen abgeschlossen. In diesem Lauf wurden sechs
  Bereiche verbessert und fünf erneut ohne weiteren Befund geprüft; die drei
  unveränderten Bereiche blieben durch ihren aktuellen Abdeckungsstand belegt.
- Der Abschlusslauf bestand mit 175 Root-Tests in 14 Suites, 65 App-Tests in
  8 Suites, einem vollständigen Release-Build und allen sechs CI-Shelltests
  für Tempordner, Bundle, Installer, Mindestversion, TagLib und Icons. Die
  sichtbaren GUI-Selbsttests wurden nicht gestartet.
- Die Schichten aus portablem Core, CLI-Adaptern, SwiftUI-App und
  Fensterkoordinator bleiben passend. `AppModel.swift` ist mit 1.357 Zeilen
  weiterhin die belegte spätere Teilungsgrenze für Laden, Speichern,
  Konflikte, Archivimport und Fensterlebenszyklus.

## [0.23.12] — 2026-08-29

### Behoben

- Der ältere CLI-Mutationsschutztest behandelt Bewertung −1 nicht mehr als
  ungültig. −1 ist der unterstützte XMP-Wert „abgelehnt“; der Test prüft jetzt
  nur noch wirklich ungültige Eingaben gegen den aktuellen Wertebereich und
  passt damit wieder zum separaten −1-Read-back-Test.

### Geprüft

- Die gezielten Export-/Exif-Tests bestanden mit 4 Tests in 2 Suites. Die
  vollständige Root-Suite bestand mit 175 Tests in 14 Suites.

## [0.23.11] — 2026-08-29

### Behoben

- Die GUI-Selbsttests finden Speichern und Neues Fenster jetzt in der
  deutschen wie in der englischen Menüleiste. Der Fenstertest belegt außerdem
  den vorgesehenen Shortcut ⌘N; bisher prüfte er nur den deutschen Titel
  und konnte einen fehlenden oder falschen Shortcut nicht erkennen.

### Geprüft

- CodeQA: Prozessbesitz, Start-/Abbruchfristen, Screenshot-Nachweis,
  Accessibility-Grenzen, Icon-Generatoren und die unveränderten Asset- und
  Fixture-Werkzeuge wurden erneut geprüft. Alle zusammengesetzten
  Swift-GUI-Programme, Shellskripte und Generatoren bestanden die Syntax-
  beziehungsweise Typprüfung; der parallele Icon-Regressionstest bestand.
  Ein sichtbarer GUI-Lauf wurde nicht gestartet.

## [0.23.10] — 2026-08-29

### Behoben

- Der Bewertungs-Picker übersetzt seine dynamisch erzeugten Einträge nun
  auch in der englischen Oberfläche. „keine“ und „— verschieden —“ blieben
  bisher deutsch; für „abgelehnt“ und sichtbare Fremdwerte fehlten zudem die
  englischen Katalogeinträge.

### Geprüft

- CodeQA: Einzel- und Batch-Bewertung samt fehlendem Tag, −1, 0…5,
  tolerierten Bestandswerten und Bild-Speichergrenzen wurden erneut geprüft.
  34 Editor-, Cover-, Speicher- und Lesepfadtests sowie die Kompilierung des
  deutschen und englischen String-Katalogs bestanden.

## [0.23.9] — 2026-08-29

### Geprüft

- CodeQA: Fenster-Registry, Dateiöffnung ohne sichtbares Fenster,
  begrenztes Nachfassen, fensterweise Beenden-Rückfragen, Delegate-Brücke,
  Dokument-URL, Fensterkopf, Seitenleistenregel und Homebrew-Angebot wurden
  erneut geprüft. 28 gezielte App-Tests und der App-Release-Build bestanden.

## [0.23.8] — 2026-08-29

### Geprüft

- CodeQA: E-Rechnungs-Erkennung, BT-24-Profilzuordnung, CII-/UBL-Feldmapping,
  PDF-Anhangs- und Dekompressionsgrenzen, XMP-Auswahl, reine CLI-/App-Anzeige
  sowie die neue adaptive BT-/BG-Spalte wurden erneut geprüft. 31 Core-/CLI-
  und 3 App-Layouttests bestanden; der bestehende Parservertrag lädt keine
  externen Entitäten.

## [0.23.7] — 2026-08-29

### Behoben

- Wörtlicher Text wie `\udcfc` bleibt in Klartextausgaben von MediaInfo,
  Calibre und externen Fehlermeldungen unverändert. Die Reparatur solcher
  Byte-Escapes gehört nur zu MediaInfo-JSON; bisher deutete der gemeinsame
  Decoder dieselbe Zeichenfolge in jedem Text fälschlich als „ü“.

### Geprüft

- CodeQA: Der Prozessrahmen wurde samt vollständigem parallelem Leeren von
  stdout/stderr, Timeout-Grenze, JSON-Struktur, UTF-8-Erhalt sowie
  feldbezogener MacRoman-/Windows-1252-Reparatur erneut geprüft. 20 gezielte
  Decoder-, Prozess- und reale MediaInfo-Tests bestanden.

## [0.23.6] — 2026-08-29

### Behoben

- `tagx exif set --rating=-1` setzt jetzt den gültigen XMP-Wert „abgelehnt“.
  Bisher wies die CLI ihn zurück, obwohl Core, Archiv und App −1 bereits als
  echten Wert behandeln; nur ein explizit leerer Optionswert löscht das Tag.
- Der Bild-Restore prüft die exakte exiftool-Rückgabe jetzt auf der Temp-Datei
  vor dem atomaren Austausch. Normalisiert oder verwirft exiftool einen
  Archivwert, bleibt das Original bytegleich, statt trotz Fehlermeldung bereits
  durch die abweichende Fassung ersetzt zu sein.

### Geprüft

- CodeQA: Bildfelder, Wertebereichs- und Archivgrenzen, exiftool-Argumente,
  Pfadbehandlung und atomarer Austausch wurden erneut geprüft. 12 gezielte
  Core-/CLI-Tests und 35 Archivtests bestanden.

## [0.23.5] — 2026-08-29

### Behoben

- `tagx ebook set` nennt bei einem abgelehnten Cover jetzt die Formate, die
  das konkrete Ziel tatsächlich schreiben kann. Für EPUB 2 versprach die
  Meldung bisher fälschlich WebP, obwohl dieses Format erst in der aktuellen
  EPUB-3-Spezifikation ohne Fallback zulässig ist.

### Geprüft

- CodeQA: Der transaktionale E-Book-Schreibweg wurde samt EPUB-OPF-Struktur,
  formatabhängigen Serien- und Covergrenzen, Calibre-/exiftool-Adaptern und
  exaktem Read-back erneut geprüft. 33 `EbookTool`-Tests bestanden.

## [0.23.4] — 2026-08-29

### Geprüft

- CodeQA: Build, Signatur-/Notarisierungsgrenzen und der atomare Installer
  wurden seit dem letzten Abdeckungsstand erneut auf Bundle-Prüfung,
  Sperrübernahme, Rollback und sichere Temp-Ziele geprüft. Installer-,
  Property-List-, Mindestversions-, Tempordner- und Ladepfadtests bestanden.

## [0.23.3] — 2026-08-29

### Geprüft

- CodeQA: Der TagLib-Shim, seine Swift-Fassade und der ausschließlich atomare
  Schreibzugang wurden nach dem geänderten MediaInfo-Testdelta erneut an ihren
  Speicher-, Cover- und Ladepfadgrenzen geprüft. 13 Roundtrip-/MediaInfo-Tests
  und der TagLib-Ladepfadtest bestanden.

## [0.23.2] — 2026-08-29

### Geprüft

- CodeQA: Archivexport und -import wurden seit dem letzten Abdeckungsstand
  erneut gegen Schema-1/2-Kompatibilität, Zielidentität, externe Freigaben,
  zielbezogene Schreibbarkeit und Read-back geprüft. 38 Archiv- und
  Exportkollisionstests bestätigen den unveränderten Vertrag.

## [0.23.1] — 2026-08-29

### Geprüft

- CodeQA: Die Save- und Konfliktkoordination in `AppModel` wurde seit dem
  letzten Abdeckungsstand samt Cover-No-op, konsistentem Datei-Schnappschuss,
  Dialogentscheidungen und aktuellen Fenstergrenzen erneut geprüft. Die 23
  gezielten AppModel-/Lesepfad-Tests bestätigen den unveränderten Vertrag.

## [0.23.0] — 2026-08-22

### Inkompatibel (Library-Produkte `TagExplosionCore`, `EInvoiceCore`)

Zwei Änderungen aus 0.22.2 waren quellinkompatibel und hätten dort keinen
Patch-Sprung verdient; sie werden hier als Minor-Sprung nachgetragen:

- `ImageCoreFields.rating` ist seit 0.22.2 `Int?` statt `Int`: `nil` heißt
  „die Datei trägt kein Rating-Tag“, −1 ist der echte Wert „abgelehnt“.
  Aufrufer, die `rating` als `Int` lesen oder `-1` als Leerwert benutzen,
  müssen auf das Optional umstellen. Die Abwesenheitssemantik bleibt, sie
  ist fachlich richtig (siehe 0.22.2).
- `EInvoiceReader.containsInvoice(url:)` war in 0.22.2 entfernt worden und
  ist wieder da — als veralteter Wrapper (`@available(*, deprecated)`) mit
  dem bisherigen Verhalten. Neuer Code nutzt `sniffXML(url:)` für XML und
  `read(url:)` für PDF.

### Behoben

- Der Bewertungs-Picker kennt jetzt „abgelehnt“ (−1). Vorher passte ein
  abgelehntes Bild zu keinem Eintrag im Einzel- und im Batch-Editor, und die
  Auswahl blieb leer, obwohl die Datei einen Wert trug. Andere tolerierte
  Bestandswerte (etwa 7 aus einer fremden Datei) erscheinen als eigener,
  sichtbarer Eintrag statt still zu verschwinden.
- Der Installer-Regressionstest vergisst jede Hintergrund-PID, sobald er sie
  eingesammelt hat, und beendet beim Abbruch nur noch Kinder, die wirklich
  noch laufen. Vorher konnte das Aufräumen eine inzwischen neu vergebene
  Prozessnummer — also einen fremden Prozess — treffen.

## [0.22.2] — 2026-08-20

### Behoben

- Eine E-Rechnung wird auch dann gefunden, wenn im PDF ein sehr großer
  Fremdanhang davor liegt. Vorher beendete ein einziger übergroßer Anhang die
  Suche, und die Datei galt als „keine E-Rechnung“, obwohl andere Programme
  die Rechnung anzeigten.
- Eine unkomprimiert eingebettete Rechnung über 256 KiB wird gelesen. Die
  Größenschranke gegen Dekompressionsbomben galt bisher auch für Anhänge, die
  gar nicht komprimiert sind.
- Ein Bild-Rating von −1 („abgelehnt“, so schreiben es Adobe Bridge und
  Lightroom) ist jetzt ein echter Wert und kein Leerwert mehr: Ein
  Wiederherstellen aus dem Backup schreibt es zurück, statt das Tag zu
  löschen. „Kein Rating“ heißt jetzt „das Feld fehlt“. Ältere Backups
  (Schema 1) werden weiterhin gelesen und dabei richtig umgedeutet.
- `tagx exif show` zeigt jedes vorhandene Rating an, auch ein negatives. Die
  Textausgabe verschwieg es, während `--json` es ausgab.
- Tags mit Anführungszeichen im Wert (`Der "Bär" aus der Straße`) werden
  wieder vollständig richtig gedeutet; das Anführungszeichen galt fälschlich
  auch außerhalb von JSON als Feldgrenze.
- Umlaute neben typografischen Zeichen bleiben erhalten: „Café – Bar“ wurde
  wegen des Gedankenstrichs komplett falsch gedeutet („CafÈ ñ Bar“). Die App
  wählt die Kodierung jetzt nach dem plausibleren Gesamtbild des Feldes und
  kennt Windows-1252, die in Musikdateien übliche Kodierung.
- Beim Beenden springt ein Fenster nur noch nach vorn, wenn dort auch
  wirklich eine Frage oder ein Dialog erscheint.
- Bleibt ein angefordertes Fenster aus, wird auch beim zweiten und jedem
  weiteren Mal nachgefasst. Nach dem ersten Fehlversuch war das Nachfassen
  vorher für den Rest der Sitzung abgeschaltet.

### Geändert

- Die drei GUI-Selbsttests teilen sich einen gemeinsamen Unterbau
  (`scripts/lib/gui-testkit.swift`) und heißen jetzt alle `.sh`. Sie beenden
  nur noch Instanzen, die sie selbst gestartet haben — auch dann, wenn während
  des Laufs eine weitere Tag Explosion dazukommt. `scripts/dev-uitest.sh`
  startet eine eigene Instanz, statt in die gerade geöffnete Datei des
  Nutzers zu schreiben.

## [0.22.1] — 2026-08-18

### Behoben

- Beim Beenden gehen keine Änderungen mehr verloren, die erst während der
  Rückfragen entstehen: Solange ein Fenster fragt, bleiben die übrigen
  bedienbar. Die App fragt jetzt in Runden gegen den aktuellen Stand und
  beendet sich erst, wenn wirklich kein Fenster mehr etwas zu verlieren hat —
  auch ein Fenster, das während der Runde dazukommt, wird gefragt.
- Bleibt ein angefordertes Fenster aus (etwa weil der Neustart des Programms
  scheitert), blockiert das nicht mehr jede weitere Anforderung bis zum
  nächsten Programmstart: Die Anforderung wird nach kurzer Frist einmal
  wiederholt und danach wieder freigegeben.
- Ein gesichertes negatives Bild-Rating (etwa −2 aus einer fremden Datei)
  wird beim Wiederherstellen exakt zurückgeschrieben. Vorher löschte der
  Import das Rating-Tag und meldete anschließend einen Fehler — nachdem die
  Datei bereits verändert war. „Kein Rating“ bleibt allein die −1.
- Umlaute innerhalb desselben Feldes werden einheitlich gedeutet: Aus dem
  MacRoman-Tag „Bäckereistraße“ wurde vorher „Bäckereistra§e“, weil die
  Kodierung je Byte-Folge statt je Feld entschieden wurde.
- Der Menüpunkt „Neues Fenster“ heißt bei englischer Systemsprache jetzt
  „New Window“.

### Geändert

- Bei präparierten PDFs endet die Anhangs-Suche nach 64 MiB entpackter
  Gesamtmenge; verworfene Anhänge zählen dabei mit. Dieselbe
  Dekompressionsbombe kann so nicht mehr beliebig oft entpackt werden.

## [0.22.0] — 2026-08-17

### Hinzugefügt

- „Neues Fenster“ (⌘N) im Ablage-Menü. Jedes Fenster hat seine eigene
  Dateiliste und Auswahl; Speichern und Verwerfen wirken immer auf das
  Fenster, in dem gerade gearbeitet wird.
- Der Fenstertitel vertritt jetzt die geöffnete Datei: mit Datei-Icon und
  dem gewohnten Pfadmenü bei Command-Klick auf den Titel. Weicht der
  Tag-Titel vom Dateinamen ab, steht der Dateiname daneben im Untertitel.

### Behoben

- Nach dem Schließen des letzten Fensters war die App eine Sackgasse: Es ließ
  sich kein Fenster mehr öffnen, und eine im Finder geöffnete Datei
  verschwand kommentarlos. Dateien landen jetzt im vordersten Fenster — und
  wenn keines offen ist, legt das Öffnen eines an.
- Die E-Rechnungs-Ansicht nutzt die Fensterbreite: Die Spalte mit den
  EN-16931-Bezeichnungen wächst mit der verfügbaren Breite, statt fest
  380 Punkte zu belegen. Damit brechen Elementnamen und Werte schon bei
  Standard-Fenstergröße nicht mehr mitten im Wort um.

### Geändert

- Die Seitenleiste mit der Dateiliste ist bei einer einzelnen Datei
  standardmäßig eingeklappt und öffnet sich ab der zweiten Datei. So steht
  dem Editor die volle Fensterbreite zur Verfügung.

## [0.21.25] — 2026-08-16

### Behoben

- Präparierte Rechnungs-PDFs können die App nicht mehr ausbremsen: Anhänge
  werden vor dem Entpacken an ihrer deklarierten Größe geprüft (Filterketten
  und angekündigte Riesen-Anhänge werden übersprungen), und die Suche im
  Namensbaum hat neben der Tiefen- jetzt auch eine Knoten-Obergrenze gegen
  sich selbst referenzierende Bäume.
- Eine gültige Factur-X-/ZUGFeRD-Rechnung im AF-Array wird auch dann
  gefunden, wenn viele fremde XML-Anhänge im Namensbaum davorstehen: Das
  AF-Array wird zuerst gelesen, und die in XMP deklarierte Rechnungsdatei
  hat einen reservierten Platz im Anhangs-Budget.
- Die Profil-Erkennung (BT-24) akzeptiert bekannte URN-Stämme nur noch am
  Anfang einer #-Komponente. Eine fremde Kennung, die einen echten Stamm
  lediglich enthält, erscheint jetzt ehrlich als „EN 16931-basiert?“.
- Das Auto-Backup vor einem Batch-Speichern scheitert nicht mehr an
  fachfremden Bestandswerten (etwa von exiftool gelesenes Rating 6 oder
  GPS 91/181): Der Export sichert den Bestand, und erst der Import prüft je
  Eintrag gegen den Zielzustand — vor der Papierkorb-Sicherung und im
  Dry-run genauso wie im echten Lauf.
- EPUB-Backups sind wieder vollständig wiederherstellbar: Ein Serienindex
  ohne Serie (calibre:series_index) und GIF-/WebP-Cover — beides in fremden
  EPUBs verbreitet — können jetzt auch geschrieben werden, nicht nur
  exportiert. Für mobi/azw3/fb2 gelten unverändert JPEG/PNG und die Regel
  „Index braucht Serie“.
- Ein einzelnes fremd kodiertes Byte in einem MediaInfo-Bericht verstümmelt
  keine gültigen UTF-8-Tags (etwa Emoji) mehr, und als Surrogate-Escape
  gelieferte MacRoman-Bytes (z.B. „ä“) werden korrekt gedeutet statt als
  Steuerzeichen zu enden.
- Wird während eines reinen Feld-Speicherns das unveränderte Originalcover
  erneut ausgewählt, gilt der Eintrag nach dem Speichern wieder als sauber,
  statt beim nächsten Speichern die Datei ohne Inhaltsänderung
  auszutauschen.
- Die Installer-Sperre entsteht jetzt atomar mitsamt Besitzerangabe
  (Symlink statt Verzeichnis + Datei), und die Übernahme einer verwaisten
  Sperre prüft den Besitzer im gegenseitigen Ausschluss erneut — zwei
  Wettläufe, in denen parallele Installationen dieselbe App gleichzeitig
  verändern konnten, sind damit geschlossen.
- Der GUI-Selbsttest `scripts/dev-screenshot.sh` beendet die Test-App auch
  in allen Fehlerpfaden zuverlässig (warten, notfalls hart beenden), statt
  sie sichtbar weiterlaufen zu lassen.

## [0.21.24] — 2026-08-15

### Geprüft

- Die CodeQA-Kampagne ist mit allen 14 Bereichen und vier
  Querschnittsthemen abgeschlossen. Zwölf Bereiche wurden verbessert; zwei
  Bereiche waren nach vollständiger Prüfung bereits sauber.
- Der Abschlusslauf bestand mit 138 Core-/CLI-Tests in 13 Suites, 30
  App-Tests in vier Suites und einem App-Release-Build ohne Swift-Warnung.
- Die Schichtentrennung zwischen portablem Core, CLI und App bleibt passend.
  Als belegte spätere Teilungsgrenze bleibt `AppModel.swift`, das Laden,
  Speichern, Konflikte, Archivimporte und App-Lebenszyklus bündelt.

## [0.21.23] — 2026-08-15

### Behoben

- Die beiden Icon-Generatoren verwenden je Lauf einen eigenen Tempordner und
  können parallel ausgeführt werden, ohne sich gegenseitig das Iconset zu
  löschen.
- Ein nicht anlegbarer Ausgabeordner oder ein fehlgeschlagener `iconutil`-
  Aufruf liefert jetzt einen Fehlercode, statt trotz „FEHLER“-Text erfolgreich
  zu enden. Ein headless Regressionstest läuft auch in der macOS-CI.
- Der Screenshot-Selbsttest meldet nur noch Erfolg, wenn App-Aktivierung,
  Fensterermittlung, `screencapture`, eine nichtleere PNG-Datei und die
  abschließende App-Terminierung tatsächlich erfolgreich waren.

## [0.21.22] — 2026-08-15

### Behoben

- Cover-Drop: Bei mehreren abgelegten Dateien werden die Provider jetzt in
  Reihenfolge bis zum ersten gültigen und für den Editor erlaubten Bild
  geprüft. Eine kaputte erste Datei oder ein für E-Books unzulässiges GIF
  verdeckt kein folgendes JPEG oder PNG mehr.
- Das gemeinsame asynchrone Drop-Handling erfüllt die Swift-6-
  Nebenläufigkeitsregeln; der App-Release-Build ist dadurch frei von
  Swift-Warnungen.
- Der Cover-Export verwendet für BMP-Daten `.bmp` und für unbekannte Daten
  `.bin`, statt beide fälschlich als JPEG zu benennen.

## [0.21.21] — 2026-08-15

### Geprüft

- CodeQA: App-Szene, Finder- und Datei-Drop-Öffnen, Fenster- und
  App-Terminierung, Konfliktdialoggrenzen, Einstellungen sowie das
  Homebrew-Installationsangebot wurden vollständig geprüft. Die App-Suite,
  der Release-Build und der große Fehlerausgabe-Test des Installers bestanden
  ohne Bereichsabweichung.

## [0.21.20] — 2026-08-15

### Behoben

- E-Rechnungen: Die Profilauflösung verlangt jetzt die bekannten
  XRechnung-, Peppol-, Factur-X- oder ZUGFeRD-URN-Stämme. Ähnlich benannte
  fremde Kennungen werden nicht mehr als bekannter Standard ausgegeben.
- Bei mehreren Rechnungs-XMLs in einem PDF gewinnt der in XMP deklarierte
  Dateiname. Ohne Deklaration bleibt die PDF-Anhangsreihenfolge erhalten,
  statt unbekannte Dateinamen alphabetisch umzudeuten.
- Nur veröffentlichte Factur-X-/ZUGFeRD-XMP-Namensräume dürfen die
  Rechnungsdeklaration und damit die Anhangsauswahl bestimmen.
- CII-Datumswerte im Format 102 erhalten nur dann eine ISO-Lesehilfe, wenn
  Jahr, Monat und Tag einen wirklichen Kalendertag bilden. Der Rohwert bleibt
  bei ungültigen Angaben unverändert sichtbar.

## [0.21.19] — 2026-08-15

### Behoben

- MediaInfo: Jeder Track und sein verschachtelter Zusatzblock behalten jetzt
  ihre eigene Feldreihenfolge. Zuvor übernahm jeder weitere Track unbemerkt
  die Reihenfolge des ersten.
- Kaputtes oder strukturell falsches MediaInfo-JSON wird als Fehler gemeldet,
  statt wie ein erfolgreicher Bericht ohne Tracks auszusehen.
- Großgeschriebene Surrogate-Escapes und MacRoman-Rohbytes aus alten Tags
  werden repariert, ohne dabei häufige Latin-1-Zeichen falsch umzudeuten.
- Ein langsamer alter MediaInfo-Aufruf kann nach einem Dateiwechsel nicht mehr
  den Bericht der nun ausgewählten Datei im SwiftUI-Tab überschreiben.

## [0.21.18] — 2026-08-15

### Geprüft

- CodeQA: TagLib-Ladepfad- und Auslieferungstests wurden nach dem gemeinsamen
  Tempordner-Helfer erneut geprüft. Ein echter Release-/Property-List-Build,
  Installer-Rollback, Mindestversionen und die drei Testtreiber bestanden auch
  mit einem gesetzten, nicht vorhandenen `TMPDIR`.

## [0.21.17] — 2026-08-15

### Behoben

- Tests: TagLib-, Installer- und Mindestversions-Regressionen wählen ihren
  Arbeitsordner über einen gemeinsamen Helfer. Ein gesetztes, aber nicht mehr
  vorhandenes oder nicht beschreibbares `TMPDIR` fällt kontrolliert auf
  `/tmp` zurück, statt die Suite vor dem eigentlichen Test abzubrechen.
- Ein eigener Shell-Test hält sowohl ein gültiges benutzerdefiniertes
  `TMPDIR` als auch den Rückfall bei einem fehlenden Elternordner fest und
  läuft in der macOS-CI mit.

## [0.21.16] — 2026-08-15

### Geprüft

- CodeQA: Medienerkennung und Ordnerfilterung wurden nach der neuen
  XML-Streaming-Erkennung erneut geprüft. Vier gezielte Tests bestätigen
  lange XML-Vorspänne, fremde Namensräume, reguläre Dateien und unveränderte
  kanonische Deduplizierung.

## [0.21.15] — 2026-08-15

### Behoben

- E-Rechnungen: Die schnelle XML-Erkennung liest als Stream bis zum ersten
  Start-Element und prüft dort Wurzelname und aufgelösten Namensraum. Gültige
  Rechnungen mit mehr als 8 KiB Prolog oder Kommentaren werden nicht mehr
  übersehen; gleichnamige Fremd-XMLs gelten nicht mehr als Rechnung.
- Medienerkennung, direkte XML-Prüfung und PDF-Anhangssuche verwenden damit
  dieselbe parserbasierte Regel, ohne große XML-Dateien für einen Ordner-Scan
  vollständig in den Speicher zu laden.

## [0.21.14] — 2026-08-15

### Geprüft

- CodeQA: Die zentrale Medienerkennung wurde vollständig auf Formatzuordnung,
  reguläre Dateien, rekursive Ordnerauflösung, Symlink-Deduplizierung und
  stabile Sortierung geprüft. Die abweichende XML-Rechnungserkennung ist als
  eigener priorisierter Querschnittsfund festgehalten.

## [0.21.13] — 2026-08-15

### Geprüft

- CodeQA: Archiv-/Kollisions- und CLI-Tagregressionen wurden nach der
  Konsolidierung ihrer Prozessausgabe erneut an den Aufrufgrenzen geprüft.
  Drei beziehungsweise sieben gezielte Tests sowie die vollständige Suite mit
  130 Tests bestätigen den unveränderten Fachvertrag.

## [0.21.12] — 2026-08-15

### Behoben

- Tests: Drei CLI-Prozesshelfer sind in einer gemeinsamen Implementierung
  zusammengeführt, die Standard- und Fehlerausgabe gleichzeitig leert. Große
  Ausgaben können das Kind dadurch nicht mehr an einer vollen zweiten Pipe
  blockieren; eine Regression prüft je 1 MiB auf beiden Kanälen.

## [0.21.11] — 2026-08-15

### Behoben

- CLI: `tagx set` lehnt leere Tag-Schlüssel sowie leere Quellen oder Ziele
  beim Kopieren vor jeder Dateiänderung ab. TagLib hatte einen leeren Schlüssel
  zuvor tatsächlich gespeichert.
- CLI: `tagx cover set` prüft die Bildsignatur, bevor eine Sicherung oder
  Änderung beginnt; beliebige Nicht-Bilddaten werden nicht mehr eingebettet.
- CLI: Der Cover-Export überschreibt keine vorhandenen Dateien mehr. Alle
  Zielkollisionen werden vorab geprüft und die Ausgaben zusätzlich exklusiv
  angelegt.
- CLI: BMP-Cover erhalten `.bmp`; unbekannte Typen werden als `.bin` statt
  fälschlich als JPEG exportiert.

## [0.21.10] — 2026-08-15

### Geprüft

- CodeQA: Die gemeinsame Bildfeldvalidierung wurde an ihren Grenzen in
  App-Speicherung, Archivimport und Bild-Schreibweg erneut geprüft. Die
  gezielten Regressionen sowie die vollständigen Suiten mit 125 Core-/CLI-
  und 27 App-Tests bestätigen, dass alle drei Bereiche aktuell bleiben.

## [0.21.9] — 2026-08-15

### Behoben

- Bildmetadaten: Eine gemeinsame Core-Regel lehnt Bewertungen außerhalb
  von -1…5, unvollständige GPS-Paare, nichtnumerische Koordinaten sowie Breiten
  außerhalb -90…90° und Längen außerhalb -180…180° ab. Core, CLI, App und
  Archivimport wenden sie vor Werkzeuglauf, Sicherung oder Batch-Mutation an.
- Bereits vorhandene fachfremde Werte blockieren das Bearbeiten anderer Felder
  nicht; erst eine Änderung des betroffenen Felds wird geprüft.

## [0.21.8] — 2026-08-15

### Geprüft

- CodeQA: Der Bild-Metadatenweg über exiftool wurde vollständig auf
  Feldabbildung, Prozessargumente, atomaren Austausch, Dateistempel und
  CLI-Sicherung geprüft. Die bereichsübergreifend uneinheitliche Prüfung von
  Bewertung und GPS ist als eigenes priorisiertes Querschnittsthema erfasst.

## [0.21.7] — 2026-08-15

### Behoben

- EPUB: Eine Änderung des dargestellten Haupttitels erhält weitere Titel wie
  Untertitel samt ihren OPF-Verfeinerungen. Beim ausdrücklichen Löschen werden
  Zielknoten und Verfeinerungen dagegen gemeinsam entfernt.
- EPUB: Ersetzte Schlagwörter hinterlassen keine `refines`-Verweise auf
  entfernte XML-IDs mehr.
- EPUB: Prozentkodierte Manifest-URLs werden vor dem Zugriff auf den
  zugehörigen ZIP-Eintrag dekodiert; Coverdateien mit Leerzeichen im Namen
  lassen sich dadurch lesen und ersetzen.

## [0.21.6] — 2026-08-15

### Behoben

- Build: Ein per `SPARKLE_FEED_URL` gesetzter Testfeed wird mit `plutil`
  statt als unkodierter XML-Text in die `Info.plist` geschrieben. Gültige
  URLs mit Query-Parametern erzeugen dadurch kein unlesbares App-Bundle mehr.
- Der macOS-CI-Test baut ein echtes lokales App-Bundle mit einer solchen URL
  und prüft sowohl die Property List als auch den unveränderten Feedwert.

## [0.21.5] — 2026-08-15

### Behoben

- TagLib-Shim: Der Versionsstring wird einmalig als unveränderlicher
  C++-`static` initialisiert. Parallele Abfragen schreiben nicht mehr
  unkoordiniert in dasselbe Zeichenarray.

## [0.21.4] — 2026-08-15

### Behoben

- Archivimport: Audio-PropertyMaps mit vorhandenen, aber leeren Wertlisten
  werden als unerreichbarer Soll-Zustand vor der ersten Batch-Mutation
  abgelehnt. Zuvor änderte der Import bereits frühere Dateien und meldete den
  unrepräsentierbaren Eintrag bei jedem weiteren Lauf erneut als geändert.

## [0.21.3] — 2026-08-15

### Behoben

- App: Solange die Entscheidung über eine extern geänderte Datei offen ist,
  werden konkurrierende destruktive Aktionen wie App-Terminierung, Import
  oder Entfernen abgewiesen. Dadurch können nicht mehr zwei Konfliktdialoge
  gleichzeitig denselben Editor-Puffer behandeln.

## [0.21.2] — 2026-08-15

### Geprüft

- CodeQA: Der vollständige Dateisicherheitskern (atomarer Austausch,
  Dateistempel, Papierkorb-Sicherung und Platzprüfung) wurde samt direkten
  Grenzen und Integritätstests korrektheitsorientiert geprüft. Es bestand
  kein Änderungsbedarf.

## [0.21.1] — 2026-08-15

Einundzwanzig Funde des Code-Reviews vom 2026-08-15 behoben.

### Behoben

- E-Rechnung: Attribute mit eigener EN-16931-Zuordnung werden jetzt als
  solche ausgewiesen — `unitCode` an Mengen (BT-130/BT-150) und das
  `name`-Attribut am UBL-Zahlungsart-Code (BT-82) erscheinen in App, CLI und
  JSON (`attributeTerms`) mit BT-Nummer und Namen.
- E-Rechnung: `ChargeIndicator` akzeptiert die XML-Schema-Booleans `1`/`0`;
  unbekannte Werte bekommen bewusst keine Nachlass-/Zuschlag-Zuordnung mehr
  (vorher wurde ein Zuschlag mit Wert `1` als Nachlass beschriftet).
- E-Rechnung (UBL): Eine `AdditionalDocumentReference` mit Typcode 130
  (Rechnungsgegenstand, BT-18) wird nicht mehr fälschlich als
  rechnungsbegründende Unterlage (BG-24) gruppiert.
- E-Rechnung: Der Inhalts-Schnelltest prüft jetzt das erste Start-Element
  statt beliebiger Teilstrings (ein Kommentar macht Fremd-XML nicht mehr zur
  Rechnung) und versteht UTF-16.
- E-Rechnung (PDF): Die XMP-Deklaration wird über den aufgelösten
  Attribut-Namensraum erkannt statt über konventionelle Präfixe; die
  Extraktion eingebetteter Dateien filtert Nicht-XML-Anhänge vor dem
  Entpacken und begrenzt Anzahl und Gesamtgröße.
- App: Ein Rechnungs-PDF öffnet auch ohne exiftool (als reine
  Rechnungs-Anzeige); der E-Book-Editor extrahiert und parst ein
  Rechnungs-PDF nur noch einmal statt doppelt.
- App: Eine Cover-Auswahl während eines laufenden Speicherns geht nicht mehr
  verloren; ein Serienindex ohne Serie wird vor der Papierkorb-Sicherung
  abgelehnt statt danach.
- Archiv: `validate` lehnt v1-Archive mit Serienindex-ohne-Serie oder
  Nicht-JPEG/PNG-Covern (z.B. GIF aus bestehenden EPUBs) nicht mehr ab —
  die engeren Regeln gelten erst am tatsächlichen Schreibweg.
- CLI: `tagx invoice --json --terms-only` filtert jetzt auch die
  JSON-Ausgabe; `tagx export` zählt E-Rechnungen nicht mehr als archivierte
  Dateien und lehnt reine Rechnungs-Eingaben ab.
- Installer: Die Sperre schreibt PID **und** Prozessstartzeit (eine
  wiederverwendete PID blockiert Updates nicht mehr), Übernahme verwaister
  Sperren läuft atomar über Umbenennen, das Initialisierungsfenster hat eine
  Wartefrist, und freigegeben wird nur die eigene Sperre. Die Tests warten
  auf die vollständig initialisierte Sperre und decken PID-Wiederverwendung
  und das Initialisierungsfenster ab.
- App-Lokalisierung: Die neuen Oberflächentexte der E-Rechnungs-Anzeige sind
  im String Catalog mit englischen Übersetzungen hinterlegt; die READMEs
  präzisieren, dass die EN-16931-Feldnamen (deutsche Benennungen) in App und
  CLI sprachunabhängig gleich bleiben. Die Drittanbieter-Hinweise nennen die
  Herkunft der Feldnamen jetzt widerspruchsfrei (Benennungen wie in der
  deutschen EN 16931/XRechnung-Spezifikation der KoSIT).
- Test-Attrappe für `install_name_tool` protokolliert Argumente einzeln
  (Argumentgrenzen-Regression war vorher unsichtbar);
  `knowledge/epub-opf-struktur.md` beschreibt Autoren- und Serien-Schreibweg
  jetzt zutreffend getrennt.

## [0.21.0] — 2026-08-14

### Hinzugefügt

- **E-Rechnungen anzeigen** (nur Lesen): ZUGFeRD, Factur-X, XRechnung und
  Peppol BIS in beiden Syntaxen (UN/CEFACT CII und OASIS UBL, Rechnung und
  Gutschrift). Erkannt werden Standard und Profil aus der
  Spezifikationskennung (BT-24, z.B. MINIMUM bis EXTENDED, XRechnung-Version);
  angezeigt wird jedes befüllte Feld mit seiner EN-16931-Feldbezeichnung
  (BT-/BG-Nummer und deutschem Namen). Felder ohne Zuordnung (z.B.
  EXTENDED-Zusatzfelder) bleiben mit Rohpfad sichtbar — es geht nichts
  verloren. Häufige Codes werden entschlüsselt (Rechnungstyp, USt-Kategorie,
  Zahlungsart, Mengeneinheiten, CII-Datumsformat als ISO-Lesehilfe).
- Neues portables Modul `EInvoiceCore` (ohne TagLib-Abhängigkeit) mit
  namensraum-kanonisierendem XML-Baum und den Pfad-Tabellen der
  EN-16931-Syntax-Bindings; PDF-Extraktion (eingebettete Dateien + Factur-X-
  XMP-Deklaration) über CoreGraphics.
- App: `.xml`-Dateien werden angenommen, wenn sie tatsächlich eine
  E-Rechnung enthalten (Inhalts-Schnelltest statt Endungs-Vertrauen); die
  Ansicht ist filterbar (Wert, Element, BT-Nummer, Feldname) und auf
  EN-16931-Felder einschränkbar. PDFs mit eingebetteter Rechnung bekommen im
  E-Book-Editor den zusätzlichen Tab „E-Rechnung“.
- CLI: `tagx invoice` (Text und `--json`, `--terms-only`) für XML- und
  PDF-Rechnungen.
- ZUGFeRD 1.0 (vor EN 16931) wird erkannt und vollständig roh angezeigt,
  bewusst ohne BT-Zuordnung.

## [0.20.2] — 2026-08-11

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-11.

### Geändert

- `tagx ebook show` liest Felder und Cover unter einem gemeinsamen Dateistempel
  und meldet einen Cover-Lesefehler als Fehler, statt ihn als „kein Cover"
  auszugeben. `tagx exif show --all` sichert Kernfelder und Metadatengruppen
  ebenso gemeinsam ab.
- Ein Serienindex ohne Serienname wird abgelehnt, statt einen Schreibvorgang
  auszulösen, bei dem der Index nirgends landet. Coverdaten müssen an ihrer
  Dateisignatur als JPEG oder PNG erkennbar sein — CLI, App und Archivimport
  prüfen das vor der Sicherungskopie.
- Dasselbe Cover in der App erneut auszuwählen ist keine Änderung mehr: Die
  Datei behält Identität und Änderungszeit, es entsteht keine Sicherung. Dafür
  hält die App das gelesene Cover jetzt im Modell — der Editor braucht keinen
  eigenen Dateizugriff mehr.

### Behoben

- `tagx cover set` und `tagx cover remove` reichen den gelesenen Dateistempel
  bis in den atomaren Austausch weiter. Eine zwischen Sicherung und Schreiben
  untergeschobene Datei wird nicht mehr überschrieben.
- Der Archivimport der App gibt die geprüfte Zielliste auch dann verbindlich
  mit, wenn kein Ziel außerhalb des Archivordners liegt. Ein während des
  Save/Discard-Dialogs umgebogener Symlink kann dadurch keine nie angezeigte
  Datei mehr ändern und keinen fremden Editor-Puffer verwerfen.
- Eine geänderte oder gelöschte ISBN lässt den `unique-identifier` des EPUB
  nicht mehr ins Leere zeigen (siehe
  [knowledge/epub-opf-struktur.md](knowledge/epub-opf-struktur.md)).
- `tagx exif set --copy` findet die Roh-Tags einer über eine Verknüpfung
  angegebenen Datei wieder; vorher blieb der Kopierwunsch wirkungslos und der
  Befehl meldete „No changes".
- Die Mindestversionsprüfung des Release-Builds schlägt jetzt geschlossen fehl:
  Ein Fehler von `vtool`, eine fehlende Angabe oder ein zu neuer zweiter
  Architektur-Slice werden nicht mehr übersprungen.
- Der Release-Build erkennt TagLib-Ladepfade auch in Build-Verzeichnissen mit
  Leerzeichen und prüft nach dem Umbiegen, dass jede TagLib-Referenz ins Bundle
  zeigt. Vorher konnte ein formal erfolgreicher Release auf fremden Macs nicht
  starten.
- Zwei gleichzeitige Installationen auf dasselbe Ziel werden über eine Sperre
  serialisiert; der zweite Lauf bricht ab, ohne etwas zu verändern. Während des
  Rollbacks werden Abbruchsignale ignoriert statt zugelassen.
- Die Shell-Tests der Auslieferungsskripte laufen in der CI. Neu dabei:
  Regressionen für die Mindestversionsprüfung und für die TagLib-Ladepfade.

## [0.20.1] — 2026-08-10

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-09.

### Geändert

- Audio-, Bild- und E-Book-Leser verwenden denselben Schnappschussvertrag:
  Inhalt und Datei-Stempel werden vor und nach allen zusammengehörigen Reads
  geprüft. Bei E-Books gehören Felder und Cover zu einem gemeinsamen Stand;
  auch ein vermeintlicher No-op wird vor der Erfolgsmeldung erneut geprüft.
- Die Dokumentation beschreibt jetzt korrekt, dass auch exiftool ausschließlich
  eine Geschwisterkopie innerhalb von `AtomicFileRewrite` verändert. Ein
  zweiter Hardlink bleibt beim atomaren Austausch bewusst auf der alten
  Fassung; behoben wurde die zuvor unerkannte Ersetzung am selben Pfad.

### Behoben

- Der verteilbare macOS-Build bündelt eine gepinnte, prüfsummenverifizierte
  TagLib mit Mindestziel macOS 14 und prüft alle Mach-O-Dateien im App-Bundle.
  Ein Build auf einem neueren macOS kann dadurch nicht mehr unbemerkt eine nur
  dort lauffähige Homebrew-Bibliothek in die als macOS 14+ ausgewiesene App
  übernehmen.
- Archivimporte erfassen Zielpfad, Dateiidentität und Stempel gemeinsam in der
  Vorprüfung und tragen genau diesen Stand bis zum Read, No-op oder atomaren
  Austausch. Eine neue Inode gilt niemals allein wegen desselben Pfads als die
  zuvor geprüfte Datei.
- `tagx exif set` und `tagx ebook set` reichen den gelesenen Stempel bis in den
  atomaren Schreibweg weiter. Fremde Änderungen nach dem Lesen werden weder
  überschrieben noch fälschlich als „No changes" bestätigt.
- E-Book-Backups können Felder und Cover nicht mehr aus zwei nacheinander am
  selben Pfad gesehenen Dateifassungen mischen.
- EPUB-Cover-IDs werden gegen alle IDs des OPF-Dokuments gewählt, nicht nur
  gegen Manifest-IDs.
- Der Installer entfernt ein bei der Endprüfung abgelehntes Bundle auch bei
  einer Erstinstallation. Bei Updates bleibt die gute alte Fassung erhalten,
  falls schon das Zurückholen fehlschlägt.

## [0.20.0] — 2026-08-07

Alle Punkte dieser Version stammen aus dem Code-Review vom 2026-08-06.

### Geändert

- Bild-Metadaten schreibt exiftool nicht mehr direkt in die Originaldatei,
  sondern in eine Geschwisterkopie; erst nach der Prüfung ersetzt sie das
  Original in einem atomaren Schritt, und der Datei-Stempel wird unmittelbar
  davor noch einmal verglichen. Eine fremde Änderung während des
  exiftool-Laufs kann so nicht mehr still verworfen werden. Nebenwirkung wie
  schon bei Audio: Die Datei bekommt eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- `tagx set` bricht mit einer Fehlermeldung ab, wenn ein anderes Programm die
  Datei zwischen Lesen und Schreiben verändert hat — auch dann, wenn sich aus
  Sicht des gelesenen Standes gar nichts ändern müsste. Vorher meldete der
  Befehl in diesem Fall „0 field(s) changed" und Erfolg, obwohl der gewünschte
  Wert nicht in der Datei stand.

### Behoben

- Die Rückfrage „Datei wurde außerhalb geändert" führt genau die angeklickte
  Entscheidung aus. Vorher räumte das Schließen des Dialogs die bestätigte
  Datei aus der Warteschlange: Sie wurde nicht gespeichert, und die Bestätigung
  traf stattdessen die nächste Datei ohne deren eigene Rückfrage.
- Archiv-Import: Jedes Ziel wird unmittelbar vor seiner Änderung erneut auf
  Dateiidentität geprüft. Wird eine noch nicht bearbeitete Datei während des
  laufenden Imports durch eine Verknüpfung auf eine andere Datei ersetzt,
  bleibt diese unangetastet; der Eintrag erscheint als fehlgeschlagen. Der beim
  Lesen erhobene Stempel wandert außerdem bis in den Schreibvorgang.
- Tag-Export und Tag-Sicherung erzeugen kein Archiv mehr, das der eigene Import
  später ablehnen würde (etwa eine Bildbewertung außerhalb von -1 bis 5). Eine
  solche Sicherung ließe sich nicht wiederherstellen.
- EPUB: Die id einer neu geschriebenen Serie weicht allen im OPF vergebenen ids
  aus, nicht nur denen der `<meta>`-Elemente. Vorher konnte eine doppelte
  XML-ID entstehen und die zugehörigen `refines`-Verweise mehrdeutig machen.
- E-Book-Schreibweg: Innerhalb der Geschwisterkopie entsteht keine zweite
  Vollkopie mehr, und Fehlermeldungen nennen die gewählte Datei statt des
  versteckten Zwischenpfads.
- Eine Videodatei, die zwischen Auswahl und Lesen verschwindet, landet nicht
  mehr als schreibgeschützter Platzhalter in der Liste.
- `install.sh` stellt die bisherige Installation wieder her, wenn der Austausch
  abgebrochen wird oder die abschließende Prüfung des installierten Bundles
  fehlschlägt. Vorher konnte `/Applications/TagExplosion.app` ganz verschwinden
  oder ein abgelehntes Bundle stehen bleiben.
- `build.sh --debug` behält seine Debug-Symbole; gestrippt wird nur noch der
  Release-Build.
- Die CLI-Tests erzeugen ihre Audio-Fixture selbst. Ein gefilterter Testlauf
  auf einem frischen Checkout scheiterte vorher am fehlenden `sample.mp3`.

## [0.19.0] — 2026-08-03

### Behoben

- Dateisicherheit: Der beim Lesen erhobene Datei-Stempel wird jetzt bis
  unmittelbar vor den atomaren Austausch mitgeführt und dort erneut geprüft.
  Ändert ein anderes Programm die Datei währenddessen, bricht das Speichern ab,
  statt die fremde Änderung zu verwerfen. Der Stempel enthält zusätzlich die
  Dateikennung, damit auch eine gleich große Ersetzung mit erhaltener
  Änderungszeit auffällt.
- Die App liest Inhalt und Stempel als einen zusammengehörigen Schnappschuss.
  Vorher konnten alte Daten mit dem Stempel einer neueren, fremden Dateiversion
  zusammenkommen — das nächste Speichern hätte diese Version ungefragt
  überschrieben.
- Beim Speichern mehrerer Dateien bekommt jede Datei mit fremder Änderung ihre
  eigene Rückfrage. Vorher überschrieb ein zweiter Konflikt den ersten: Der
  Dialog gehörte dann zur falschen Datei.
- EPUB: Eine Autorenänderung löscht keine Mitwirkenden mit anderer Rolle
  (Herausgeber, Übersetzer) mehr, und eine Serienänderung lässt unabhängige
  Sammlungen des Buchs stehen. Platzmangel wird wieder als solcher gemeldet.
- Archiv-Import: Wird ein freigegebenes Ziel nach der Anzeige durch eine
  Verknüpfung auf eine andere Datei ersetzt, bricht der Import ab.
  Bildbewertungen außerhalb von -1 bis 5 und Serienangaben für PDF werden vor
  jeder Änderung abgelehnt. Zwei Sicherungen desselben Ordners innerhalb einer
  Sekunde überschreiben sich nicht mehr.
- Papierkorb-Sicherung: parallele Sicherungen laufen serialisiert, ein
  gemerkter Stand gilt nur solange seine Kopie wirklich existiert, und ein
  Stapel wird vor der ersten Kopie im Ganzen gegen den freien Platz geprüft.
  Auf Nicht-APFS-Datenträgern schlägt die Platzprüfung nicht mehr grundlos fehl.
- `tagx set` schreibt nur noch, wenn sich wirklich etwas ändert, und meldet die
  echte Zahl geänderter Felder.
- `./install.sh` beendet eine laufende App nur noch regulär und bricht ab, wenn
  sie nicht beendet wird; ungesicherte Änderungen gehen dadurch nicht mehr
  verloren. Das neue Bundle wird erst vollständig geprüft und dann eingesetzt —
  eine fehlgeschlagene Aktualisierung lässt die alte Installation stehen.

### Geändert

- Die in-place arbeitenden Backend-Methoden von `TagFile` und `EbookTool` sind
  nicht mehr Teil der öffentlichen Core-Schnittstelle. Schreiben läuft von außen
  ausschließlich über den abgesicherten Transaktionsweg.
- `THIRD-PARTY-NOTICES.md` und die READMEs beschreiben jetzt genau, was beim
  Bündeln an TagLib und Sparkle verändert wird (Install-Namen, entfernter
  `XPCServices`-Ordner, Neusignierung) statt sie pauschal „unverändert" zu
  nennen.

## [0.18.0] — 2026-07-29

### Hinzugefügt

- Fehlen `mediainfo` oder `exiftool`, bietet die App bei jedem Start an, die
  fehlenden Formeln über Homebrew zu installieren (mit Fortschrittsanzeige und
  ehrlicher Fehlermeldung); ohne Homebrew verweist sie auf brew.sh. „Später"
  verschiebt auf den nächsten Start, „Nicht mehr fragen" beendet das Angebot
  dauerhaft. Calibre bleibt bewusst außen vor (optionales Extra, Cask statt
  Formel).

## [0.17.3] — 2026-07-25

### Geändert

- `docs/sparkle-release.md` um die beiden Stolpersteine des ersten echten
  Release-Laufs ergänzt: Die Umgebung `github-pages` muss neben `main` auch
  Tags (`v*`) zum Deployment zulassen, sonst lehnt sie den vom Release
  ausgelösten Lauf ab; und `sign_update --verify` braucht `--account`, um den
  Feed gegen das DMG zu prüfen.

## [0.17.2] — 2026-07-25

### Hinzugefügt

- Social-Preview-Bild für GitHub (`docs/social-preview.png`) samt
  reproduzierbarem Generator `scripts/gen-social-preview.py`.

### Geändert

- `docs/sparkle-release.md`: genaue Befehle für den Export des
  Sparkle-Schlüssels (mit `--account`, ohne ihn je auf stdout zu zeigen), der
  Release-Ablauf verweist jetzt auf `release.sh`, und es steht dort, warum
  dieses Projekt seinen eigenen Schlüssel behält, obwohl Sparkle einen
  Schlüssel für beliebig viele Apps erlaubt: Jede bereits verteilte Fassung
  akzeptiert nur Updates, die zu ihrem eingebauten `SUPublicEDKey` passen.

## [0.17.1] — 2026-07-25

### Behoben

- Die Bildvorschau ließ ein `NSImage` aus einem Hintergrund-Task auf den
  MainActor wandern. Mit älteren Swift-6-Toolchains als der lokalen ist das ein
  Übersetzungsfehler — gefunden vom ersten CI-Lauf auf GitHub. Gelesen werden
  jetzt die Bytes, das Bild entsteht auf dem MainActor.

## [0.17.0] — 2026-07-25

### Hinzugefügt

- `install.sh`: baut die App als Release, signiert sie mit Developer ID und
  Hardened Runtime, notarisiert sie bei Apple, heftet das Ticket an und
  installiert sie nach `/Applications` — aber erst, nachdem Stapler,
  Gatekeeper und Signatur die Notarisierung bestätigt haben.
  `--no-notarize` baut ein schnelles Testbundle, das im Projektordner bleibt.
- `release.sh`: erzeugt das verteilbare, notarisierte DMG mit Hintergrundbild
  und Finder-Layout.
- Beide Skripte fragen einmal nach dem lokalen notarytool-Schlüsselbundprofil
  und merken sich nur dessen Namen clone-lokal. Damit laufen sie auf jedem Mac,
  ohne dass etwas Vertrauliches im Repository landet.
- `THIRD-PARTY-NOTICES.md` mit den vollständigen Lizenztexten der
  mitgelieferten und gelinkten Komponenten (TagLib, Sparkle, ZIPFoundation,
  swift-argument-parser) und der Begründung, warum die nur aufgerufenen
  Programme lizenzrechtlich nicht durchgreifen. Ersetzt `THIRD-PARTY.md` und
  liegt auch im App-Bundle.
- READMEs: App-Symbol im Kopf und ein eigener Abschnitt darüber, wie die
  Dateien geschützt werden.

### Behoben

- AVI-Dateien ließen sich nicht öffnen, obwohl sie als „nur Anzeige"
  angekündigt sind: TagLib kann AVI nicht lesen, und der Read-only-Fallback
  griff nur beim Öffnen, nicht beim Neuladen. Er liegt jetzt an einer Stelle
  für alle Lesewege. Eine wirklich kaputte Audiodatei meldet dagegen weiterhin
  einen Fehler, statt einen leeren Editor zu zeigen.

## [0.16.1] — 2026-07-25

### Behoben

- Eine Datei aus dem Finder zu öffnen („Öffnen mit …", Ziehen aufs
  Dock-Symbol, `open -a`) funktionierte nicht, wenn die App dabei startete:
  Sie lief unsichtbar ohne Fenster weiter und lud die Datei nie. Beim Start
  mit einer Datei legt SwiftUI kein Fenster an, und macOS liefert das
  Öffnen-Ereignis nur an ein vorhandenes Fenster aus. Die App sorgt jetzt
  selbst dafür, dass ein Fenster erscheint, und nimmt die Datei über den
  App-Delegate entgegen statt über SwiftUIs `onOpenURL`.

## [0.16.0] — 2026-07-25

### Hinzugefügt

- **Abgesicherter Modus** (Standard an): Vor jeder Änderung wandert eine
  unveränderte Kopie der Datei in den Papierkorb — gesammelt in einem Ordner
  je Sitzung und je Datenträger. Zum Wiederherstellen die Kopie zurückziehen,
  zum Aufräumen den Papierkorb leeren. Auf APFS entsteht die Kopie als Klon
  und belegt zunächst keinen zusätzlichen Platz. Abschaltbar in den
  Einstellungen (⌘,) sowie per `--no-backup` bzw. `TAGX_NO_BACKUP=1` in der
  CLI.
- Warnung, wenn eine geöffnete Datei zwischenzeitlich von einem anderen
  Programm geändert wurde. Gespeichert wird erst nach ausdrücklicher
  Bestätigung; der fremde Stand liegt dann als Kopie im Papierkorb.
- Prüfung des freien Speicherplatzes, bevor eine Datei geschrieben wird.
- GitHub-Actions-Workflow, der Core, CLI und App auf macOS baut und testet.

### Geändert

- Audio- und Video-Tags werden nicht mehr in-place geschrieben: Die Änderung
  entsteht an einer Geschwisterkopie, wird geprüft (Datei wieder lesbar,
  Kanäle, Samplerate und Spielzeit unverändert) und ersetzt das Original erst
  danach in einem atomaren Schritt. Ein Absturz, ein Formatfehler oder ein
  voller Datenträger kann keine halb geschriebene Datei mehr hinterlassen.
  Nebenwirkung: Die Datei bekommt dabei eine neue Inode, zusätzliche Hardlinks
  zeigen danach weiter auf den alten Stand.
- Dateipfade gehen immer absolut an mediainfo, exiftool und `ebook-meta`,
  damit ein Dateiname mit führendem Bindestrich nicht als Option gelesen wird.

### Behoben

- Die Prüfung auf fremde Änderungen war wirkungslos, weil `URL.resourceValues`
  einmal gelesene Werte zwischenspeichert. Sie liest den Dateizustand jetzt
  ungepuffert.

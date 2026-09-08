# Playlists und Cue-Sheets: cue, m3u/m3u8, pls, xspf

**Trigger:** Arbeit an `PlaylistTool`, `PlaylistTextFile`, einem der vier
Backends (`CueSheetFile`, `M3UPlaylistFile`, `PLSPlaylistFile`,
`XSPFPlaylistFile`), `PlaylistExporter`, `CueApply`, `tagx playlist`/`tagx cue`
oder dem Playlist-Editor der App.

## Zeilenweise ändern statt neu aufbauen

Die drei Textformate laufen über `PlaylistTextFile`: jede Zeile behält ihr
Zeilenende (`\n`/`\r\n`), eine BOM bleibt, nur die geänderte Zeile wird
ersetzt, eingefügt oder entfernt. Ein Neuaufbau aus dem Modell hätte
Kommentare, `FLAGS`/`PREGAP`/`REM COMMENT`, EXTINF-Attribute (`tvg-id=…`)
und die Einrückung verloren — genau das, was fremde Werkzeuge (EAC, foobar,
Kodi) in solche Dateien schreiben. Nach jeder Einzeländerung parst das
Cue-Backend die Datei neu; so verschieben Einfügungen keine gemerkten
Zeilennummern. Neue Trackzeilen übernehmen die Einrückung der vorhandenen
Feldzeilen des Tracks, nicht eine feste Vorgabe.

XSPF ist XML und geht wie die Dokument-Backends über `XMLDocument`: Elemente
bleiben, das Dokument wird beim Schreiben neu eingerückt.

## Encoding: Fallback beim Lesen, UTF-8 beim Schreiben

`.m3u` und ältere `.cue` liegen oft in Latin1/MacRoman vor. Gelesen wird
mit derselben Reparatur wie beim mediainfo-JSON
(`MediaInfoReader.decodeLossyPlainText`); `PlaylistContents.usedEncodingFallback`
zeigt das an (CLI: `NOTE=…`, App: orangefarbener Hinweis). Geschrieben wird
immer UTF-8 — auch die unveränderten Zeilen werden dabei umkodiert. Die
gemischte Rückwärts-Kodierung je Lauf lässt sich nicht verlässlich umkehren,
und ein Mischmasch aus zwei Kodierungen in einer Datei wäre schlimmer.

## Was die Formate speichern

| Feld | cue | m3u/m3u8 | pls | xspf |
|------|-----|----------|-----|------|
| Titel der Liste | `TITLE` | `#PLAYLIST:` | — | `title` |
| Interpret der Liste | `PERFORMER` | — | — | `creator` |
| Datum / Genre | `REM DATE` / `REM GENRE` | — | — | — |
| Eintragstitel | `TITLE` im Track | EXTINF-Text | `TitleN` | `track/title` |
| Eintragsinterpret | `PERFORMER` im Track | — | — | `track/creator` |

`PlaylistTool.requireWritable` lehnt geänderte Felder ohne Speicherort VOR
Sicherung und Mutation ab (`TagError.unsupportedDocumentField`, der Text
sagt „document format" — bewusst wiederverwendet statt eines neuen Falls).

- **M3U-Anzeigetext ist EIN Feld.** `#EXTINF:sek,Interpret - Titel` hat
  keine verlässliche Trennregel; ein Titel mit „ - " würde beim Zurücklesen
  anders zerlegt und die Prüfung nach dem Schreiben (Read-back == Sollwerte)
  scheiterte. Deshalb ist der ganze Text der Eintragstitel; der Exporter
  schreibt „Interpret - Titel" nur in diese Richtung.
- **Cue-Werte kennen kein Escape für `"`.** Solche Werte werden abgelehnt.
  `REM`-Werte bekommen Anführungszeichen nur bei Leerraum (EAC-Stil).
- **PLS hat keinen Listentitel**; die Einträge werden nach `N` sortiert, auch
  wenn sie in der Datei durcheinander stehen. Nur Schlüssel innerhalb von
  `[playlist]` zählen; gleichnamige Felder fremder Abschnitte bleiben unangetastet.

## Dauer und Pfade

- CUE-Zeiten prüfen Sekunden (0…59), Frames (0…74) und den Integerbereich;
  fehlerhafte INDEX-Angaben bleiben unbekannt. Millisekunden werden vor dem
  Runden geteilt, damit auch `Int.max` nicht überläuft. Die Summe bekannter
  Dauern bleibt ein `Int` und wird bei Überlauf auf `Int.max` begrenzt.
  Drei CLI-Abstürze durch große CUE-/XSPF-Werte wurden am 2026-09-08
  reproduziert und durch Core- und CLI-Grenzfalltests abgesichert.

- Cue: Dauer eines Tracks = nächster `INDEX 01` derselben Datei minus eigener;
  der letzte Track einer Datei reicht bis zu deren Ende — dafür liest
  `TagFile` die Länge, wenn die Datei existiert. Fehlt sie, bleibt die Dauer
  unbekannt (`unknownDurationCount`), die Gesamtdauer ist dann unvollständig.
- Pfade: relativ zum Ordner der Playlist, `file://`-URIs werden entpackt,
  Rückschrägstriche gelten als Trenner; nur relative XSPF-URIs werden
  prozentdekodiert, `%20` bleibt in M3U/PLS/CUE ein Dateinamenbestandteil; `http(s)` gilt als `isRemote` und wird nicht auf Existenz geprüft.
- **`/private/tmp`-Falle in Tests:** `standardizedFileURL` kürzt `/private/tmp`
  auf `/tmp`, wenn der Pfad existiert — für fehlende Dateien bleibt
  `/private/tmp`. Tests vergleichen deshalb `resolvedPath` mit
  `erwartet.standardizedFileURL.path` oder per `hasSuffix`.

## `cue apply` nur bei einer Datei je Track

Die Gruppierung prüft Geräte- und Inode-Nummer, ersatzweise den aufgelösten
Pfad. Symlinks und Hardlinks auf dieselbe Audiodatei zählen daher als ein
Image; zwei Track-Schreibaufträge darauf werden bereits beim Planen
abgelehnt. Der bestehende Cue-Apply-Test prüft beide Verknüpfungsarten.


Ein Cue-Sheet über EIN Image (typisch: `album.flac` mit vielen Tracks) müsste
die Datei zerschneiden; das tut Tag Explosion nicht. `CueApply.plan` lehnt
geteilte Dateien mit Tracknummern ab (`sharedFile`), fehlende Dateien mit
Pfad. Geschrieben werden TITLE, ARTIST (Track-, sonst Album-Interpret), ALBUM,
ALBUMARTIST, TRACKNUMBER (`n/gesamt`), DATE, GENRE, ISRC — nur belegte Felder,
nur Dateien mit tatsächlicher Änderung, jede über Schnappschuss, Papierkorb
und `TagFile.write`. Die CLI zeigt ohne `--apply` nur den Plan; mit `--json`
kommt ausschließlich JSON auf stdout (Feld `dryRun`).

## Export ist ein Schreibweg

`PlaylistExporter.export` legt die Datei ohne `overwrite` exklusiv an
(`.withoutOverwriting`), wie `tagx cover export`. Die App übergibt
`overwrite: true`, weil das Sichern-Panel das Ersetzen schon bestätigt hat.
Dauer aus TagLib (`AudioInfo`); Dateien ohne lesbare Tags erscheinen mit dem
Dateinamen als Titel und werden in `Summary.untagged` gemeldet.

## App

Playlists sind nicht archivierbar (`MediaFormats.isArchivable`), tragen keine
Muster-Felder (`supportsFilenamePatterns == false`) und haben keinen
Batch-Editor. Der Doppelklick im Editor öffnet die Datei in einem neuen
Fenster: `WindowSessions.queueForNextWindow(urls:)` merkt die Dateien vor,
`openWindow(id:)` legt das Fenster an, `register` liefert sie über den
gewohnten `AppModel.open` aus. Die Tabelle steht in Zellen-Funktionen —
als ein Ausdruck war sie dem Typprüfer zu groß.


## Viele Titel in Text-Playlists ändern

M3U und PLS parsen die Liste einmal für alle Eintragsänderungen.
`PlaylistTextFile.apply` führt die geplanten Zeileneingriffe von unten aus;
bei gleicher Position wird erst die vorhandene Zeile geändert und danach
eingefügt. So bleiben auch unsortierte PLS-Schlüssel korrekt zugeordnet.

Messung am 2026-09-08 mit je 1.000 CLI-Titeländerungen, gemischtem Einfügen,
Ersetzen und Leeren, BOM/CRLF und Kommentaren: M3U 2,284 → 0,274 Sekunden,
PLS 8,163 → 0,329 Sekunden. Beide Ausgaben waren bytegleich mit dem
vorherigen Ergebnis. Der bestehende PLS-Roundtrip prüft zusätzlich das
Einfügen und Ersetzen an derselben ursprünglichen Zeilenposition.


Exportierte relative Namen mit führender Raute oder einem Doppelpunkt im
ersten Segment erhalten `./`, damit sie weder Kommentar noch URI-Schema
werden. Textformate können Zeilenumbrüche, echte Rückschrägstriche und
äußeren Leerraum im Pfad nicht eindeutig wiedergeben. Der Export lehnt
solche Pfade vor jeder Sicherung oder Mutation ab; XSPF kodiert sie als URI.
Die Regressionen prüfen vorhandene Zieldateien auf unveränderte Bytes und
lesen alle darstellbaren Dateinamen wieder auf ihre Originalpfade zurück.

Beim Überschreiben eines Playlist-Exports wird der Dateistempel vor der
Papierkorb-Sicherung aufgenommen und an `AtomicFileRewrite` weitergereicht.
Eine fremde Änderung während der Sicherung wird so nicht zum neuen,
ungesehenen Ausgangsstand des atomaren Schreibens.


Die CUE-Dauerberechnung merkt sich bei einem Rückwärtsdurchlauf den nächsten
Track je Dateipfad. Sie durchsucht dadurch nicht mehr für jeden Track den
Rest der Liste. Bei 10.000 Einträgen sank `playlist show --json` am
2026-09-08 von 6,191 auf 0,177 Sekunden; die JSON-Ausgabe blieb bytegleich.
Ein zusätzlicher Verhaltenstest prüft verschachtelte Dateifolgen A–B–A–B.

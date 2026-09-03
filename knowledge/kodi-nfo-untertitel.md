# Kodi-NFO und Untertitel-Sidecars: Fallen (Stand 2026-09-02)

Konsultieren bei Arbeit an `KodiNFOFile`, `SubtitleFile`, `SidecarTool`,
`tagx nfo`/`tagx subtitle`, dem Sidecar-Editor oder dem NFO-Abschnitt im
Video-Editor.

## NFO

- **Foundation-XML kennt den Leerraum zwischen Elementen nach dem Parsen
  nicht mehr.** Auch mit `.nodePreserveWhitespace` tauchen die Einrückungs-
  Textknoten nicht unter `children` auf; `xmlData(options: .nodePrettyPrint)`
  (wie in XMLTools) rückt alles nach eigenem Muster neu ein. Deshalb
  serialisiert `NFOWriter` das Wurzelelement selbst und liest vorher aus dem
  Rohtext ab: Einrückungsstufe (erste eingerückte Zeile), Zeilenende (CRLF,
  wenn eines vorkommt) und die Form leerer Elemente (`<a></a>`, `<a/>`,
  `<a />`). Alles vor dem `<` des Wurzelelements (Deklaration, Kommentare)
  und alles dahinter (Zeilenumbruch, URL-Zeilen) wird wörtlich übernommen.
  Für eine normal eingerückte NFO ist ein Roundtrip byteweise die Eingabe;
  ein Test hält das fest.
- **Was der eigene Serialisierer normalisiert:** Zeichenreferenzen (`&#xE4;`
  wird zum Zeichen), Attributreihenfolge und -anführungszeichen (immer `"`),
  Leerraum innerhalb gemischter Inhalte. Text-Escapes sind `&amp;`, `&lt;`,
  `&gt;` wie bei tinyxml2 (Kodi). CDATA bleibt CDATA.
- **`.nfo` heißt nicht NFO.** Szene-Release-Textdateien tragen dieselbe
  Endung. `MediaFormats.kind(of:)` prüft deshalb den Inhalt
  (`KodiNFOFile.sniff`): bekanntes Wurzelelement (`movie`, `episodedetails`,
  `tvshow`, `musicvideo`, `album`, `artist`) oder Nur-URL. Alles andere ist
  keine Mediendatei und fällt beim Ordner-Drop weg.
- **Nur-URL-NFO** (jede nicht-leere Zeile eine http(s)-Adresse) wird
  angezeigt, nie beschrieben (`TagError.urlOnlyNFO`), nicht archiviert.
  Kodi erlaubt außerdem XML mit URL-Zeilen hinter dem Wurzelelement; die
  bleiben im Nachspann erhalten.
- **Bewertung hat zwei Speicherorte:** flaches `<rating>` (alt) oder
  `<ratings><rating default="true"><value>` (Kodi ab v17). Gelesen wird
  flach vor dem Standard-Eintrag des Blocks; geschrieben wird dort, wo der
  Wert herkam, sonst flach neu.
- **`premiered` (Film) und `aired` (Episode)** landen im selben Feld. Beim
  Schreiben behält die Datei ihr vorhandenes Element; ohne beides entscheidet
  das Wurzelelement.
- **Mehrwertige Elemente (genre, tag, director)** werden als Gruppe an der
  Stelle des ersten vorhandenen Elements ersetzt, damit sie nicht ans Ende
  wandern. Neue Elemente kommen ans Ende des Wurzelelements.
- **Kopplung ans Video:** `MediaFormats.nfoURL(forVideo:)` findet
  `<name>.nfo` neben mkv/mp4/m4v/mov/avi/webm/… (`nfoVideo`), umgekehrt
  `videoURL(forNFO:)` das erste Video zum Namen. Ordner-Drops verstecken die
  NFO eines gelisteten Videos (`hidingSidecars`, wie `.xmp`). Der Abschnitt
  im Video-Editor (`NFOSidecarSection`) hat seit 0.40.0 keinen eigenen
  Speichern-Knopf mehr: Der NFO-Puffer liegt im `FileEntry`
  (`videoNFOFields`/`videoNFOOriginal`, Lesestand in
  `audioSidecars.nfo` mit eigenem Stempel), zählt zu `isDirty` und wird
  über `AppModel.write` mit dem Eintrag gespeichert — nur die NFO, wenn
  `AudioSnapshot.mediaChanged` false ist. Damit greift die
  Schließen-/Beenden-Rückfrage auch für NFO-Eingaben (Review 2026-09-02).
  Beim Umbenennen des Videos wandert die NFO mit (`FileRenamer.companionSidecar`),
  der Eintrag bekommt den neuen NFO-Pfad über `init(relocating:sidecar:)`.
- **Prüfung:** `rating`/`userrating` nur als endliche Zahl 0…10, `premiered`
  nur als existierender Kalendertag (`ISODate.isCalendarDay`); ein schon
  vorher ungültiger, unveränderter Altwert blockiert andere Änderungen nicht.
  `SubtitleFile.shiftMilliseconds(seconds:)` begrenzt die Verschiebung auf
  1000 Stunden — `Int(1e16 * 1000)` wäre sonst ein Laufzeitabbruch.
- **Zeichensatz:** UTF-8 (BOM bleibt erhalten); bei Deklaration
  `iso-8859-1`/`windows-1252` wird in diesem Zeichensatz zurückgeschrieben,
  andere Angaben fallen auf UTF-8 zurück.

## Untertitel

- **Zeitverschiebung ändert nur Zeilen mit `-->`.** Alle anderen Zeilen,
  Zeichensatz, BOM und Zeilenende bleiben byteweise erhalten; +x und −x
  ergeben die Ausgangsdatei (Test). Negative Zeiten werden abgelehnt, bevor
  etwas geschrieben wird. Ohne Stundenanteil (VTT `MM:SS.mmm`) erscheint er
  erst, wenn eine Zeit eine Stunde erreicht.
- **`--seconds=-1.5`:** ArgumentParser liest `--seconds -1.5` als Option
  plus unbekanntes Flag; negative Werte brauchen die `=`-Form.
- **Zeichensatz-Erkennung:** UTF-8-BOM → UTF-16-BOM → UTF-8 → Latin-1 als
  Rückfall (Latin-1 scheitert nie). UTF-16 wird nur gelesen, nicht
  geschrieben (Foundation setzt beim Kodieren eine eigene BOM).
- **Swift zählt `\r\n` als EIN Zeichen.** `lines(keepingTerminators:)`
  nutzt das: `Character.isNewline` trifft das ganze Zeilenende, und
  `dropLast()` entfernt es vollständig.
- **Sprache aus dem Dateinamen:** hinterste Komponenten vor der Endung —
  erst Flags (`forced`, `sdh`, `hi`, `cc`, `default`), dann ein Kürzel aus
  2–3 Buchstaben mit optionaler Region (`pt-BR`). `film.2019.srt` hat keine
  Sprache, `de.srt` auch nicht (kein Basisname). Umbenennen läuft über das
  Muster `%{base}.%{lang}` (Felder `BASE`, `LANG`, `FLAGS`, bei VTT `TITLE`).
- **VTT-Kopf:** Titel = Text hinter `WEBVTT` in Zeile 1, `Language:` eine
  Kopfzeile bis zur ersten Leerzeile. Ein leerer Wert entfernt Titel bzw.
  Zeile; eine neue Language-Zeile entsteht am Ende des Kopfblocks. SRT hat
  keinen Kopf: Titel/Sprache werden mit `unsupportedDocumentField` abgelehnt.

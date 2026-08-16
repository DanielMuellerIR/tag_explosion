# mediainfo/exiftool-Wrapper: Fallen (Stand 2026-07-17)

## mediainfo (26.05)

- **JSON kann kaputtes UTF-8 enthalten:** Latin1-/MacRoman-Bytes aus
  ID3v1/v2.3-Tags werden als Lone-Surrogates escaped (`\udcfc` = Byte 0xFC,
  à la Python surrogateescape). JSON-Parser verlieren/verweigern das →
  `MediaInfoReader.repairSurrogateEscapes` stellt unabhängig von der
  Großschreibung der Hexziffern das ROHE Byte wieder her; erst `decodeLossy`
  entscheidet die Kodierung. Eine vorschnelle Latin1-Deutung machte aus
  `\udc8a` (MacRoman „ä") das Steuerzeichen U+008A.
- **Kodierungs-Fallback segmentweise, nie global:** Scheitert die strikte
  UTF-8-Dekodierung, bleiben gültige UTF-8-Sequenzen erhalten; nur die
  tatsächlich ungültigen Bytes werden dekodiert (C1-Bytes UNTER den
  ungültigen sprechen für MacRoman, sonst hat das häufigere Latin1 Vorrang —
  eine Entscheidung pro Bericht). Ein globaler Umschalter würde wegen eines
  einzigen Fremd-Bytes auch korrekte UTF-8-Tags zerlegen: Die
  Fortsetzungsbytes von Emoji (z.B. `F0 9F 98 80`) liegen selbst im
  C1-Bereich und sind KEIN MacRoman-Signal.
- JSON-Objekt-Reihenfolge geht durch `JSONSerialization` verloren → Original-
  Reihenfolge je Track und verschachteltem `extra`-Objekt mit dem kleinen
  strukturtreuen Lexer aus dem JSON-Text rekonstruieren. Eine globale Suche
  übernimmt ab dem zweiten Track fälschlich die Reihenfolge des ersten.
- Kaputtes oder strukturell falsches MediaInfo-JSON ist ein Fehler, kein
  erfolgreicher Bericht mit null Tracks. stdout und stderr externer Werkzeuge
  immer gleichzeitig leeren, damit keine volle Pipe den Prozess blockiert.
- `mediainfo <datei>` (Textform) ist die beste Roh-Ansicht für Menschen —
  beides einsammeln (JSON strukturiert + Text zum Kopieren).
- `MediaInfoTab` liest in einem abgetrennten Hintergrund-Task. Nach dessen
  Ergebnis muss der SwiftUI-Task erneut auf Abbruch geprüft werden; sonst kann
  ein alter langsamer Report nach einem Dateiwechsel den neuen Tab ersetzen.

## exiftool (13.55)

- **MWG-Tags brauchen `-use MWG`** in JEDEM Aufruf (lesen und schreiben),
  sonst „MWG:Title doesn't exist or isn't writable".
- **MWG hat KEIN Title-Tag!** Writable: City, Copyright, Country, CreateDate,
  Creator, DateTimeOriginal, Description, Keywords, Location, ModifyDate,
  Orientation, Rating, State. Titel → `XMP-dc:Title` (so auch Apple Fotos).
- Listen ersetzen: `-MWG:Keywords=` (löschen) gefolgt von `-MWG:Keywords+=wert`
  pro Eintrag.
- GPS bequem: `-GPSLatitude*=50.9` (mit Stern) setzt Wert UND Ref-Tag aus dem
  Vorzeichen. Löschen: alle vier Tags (`GPSLatitude/Longitude` + `…Ref`) leeren.
- exiftool prüft die fachlichen Wertebereiche nicht: Es speichert etwa Breite
  91°, Länge 181° und Bewertung 99 mit Exit-Code 0. Deshalb validiert
  `ExifTool.requireValidCoreFields` Bewertung und GPS zentral; CLI, App und
  Archivimport rufen dieselbe Regel vor Sicherung oder Batch-Mutation auf.
- `-overwrite_original` verhindert `_original`-Duplikate; `-n` für numerische
  Werte (GPS dezimal), sonst kommen formatierte Strings.

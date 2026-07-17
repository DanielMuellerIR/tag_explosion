# mediainfo/exiftool-Wrapper: Fallen (Stand 2026-07-17)

## mediainfo (26.05)

- **JSON kann kaputtes UTF-8 enthalten:** Latin1-Bytes aus ID3v1/v2.3-Tags
  werden als Lone-Surrogates escaped (`\udcfc` = Byte 0xFC = „ü", à la Python
  surrogateescape). JSON-Parser verlieren/verweigern das →
  `MediaInfoReader.repairSurrogateEscapes` ersetzt die Escapes im Bytestrom
  durch die Latin1-Deutung, danach normal parsen.
- JSON-Objekt-Reihenfolge geht durch `JSONSerialization` verloren → Original-
  Reihenfolge der Keys aus dem JSON-Text rekonstruieren (Anzeige-Stabilität).
- `mediainfo <datei>` (Textform) ist die beste Roh-Ansicht für Menschen —
  beides einsammeln (JSON strukturiert + Text zum Kopieren).

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
- `-overwrite_original` verhindert `_original`-Duplikate; `-n` für numerische
  Werte (GPS dezimal), sonst kommen formatierte Strings.

# mediainfo/exiftool-Wrapper: Fallen (Stand 2026-08-20)

## mediainfo (26.05)

- **JSON kann kaputtes UTF-8 enthalten:** Latin1-/MacRoman-Bytes aus
  ID3v1/v2.3-Tags werden als Lone-Surrogates escaped (`\udcfc` = Byte 0xFC,
  à la Python surrogateescape). JSON-Parser verlieren/verweigern das →
  `MediaInfoReader.repairSurrogateEscapes` stellt unabhängig von der
  Großschreibung der Hexziffern das ROHE Byte wieder her; erst `decodeLossy`
  entscheidet die Kodierung. Eine vorschnelle Latin1-Deutung machte aus
  `\udc8a` (MacRoman „ä") das Steuerzeichen U+008A.
- **Kodierungs-Fallback je Textfeld, nie global:** Scheitert die strikte
  UTF-8-Dekodierung, bleiben gültige UTF-8-Sequenzen erhalten; nur die
  tatsächlich ungültigen Bytes werden dekodiert. Ein globaler Umschalter würde
  wegen eines einzigen Fremd-Bytes auch korrekte UTF-8-Tags zerlegen: Die
  Fortsetzungsbytes von Emoji (z.B. `F0 9F 98 80`) liegen selbst im
  C1-Bereich und sind KEIN MacRoman-Signal.
  - **Entscheidungseinheit ist das TEXTFELD**, nicht der Bericht und nicht der
    einzelne Byte-Lauf. Eine Entscheidung pro Bericht ließ ein C1-Byte alle
    anderen Felder verfälschen (Review-Fund 2026-08-17); eine pro Lauf mischte
    innerhalb eines Feldes zwei Kodierungen und machte aus „Bäckereistraße"
    ein „Bäckereistra§e" (Review-Fund 2026-08-18).
  - **Feldgrenze:** immer der Zeilenumbruch; NUR bei JSON zusätzlich das
    unmaskierte Anführungszeichen. Beginnt die Ausgabe nach Weißraum mit `{`
    oder `[`, gilt sie als JSON. Galt das Anführungszeichen überall als
    Grenze, zerteilte es in einer Klartextzeile den Wert selbst
    (`Titel: Der "Bär" aus der Straße`) und nahm dem zweiten Teil sein
    MacRoman-Signal (Review-Fund 2026-08-20).
  - **Zur Wahl stehen MacRoman und Windows-1252**, nicht MacRoman und reines
    Latin-1: cp1252 ist in ID3v2.3 die real verbreitete Kodierung und belegt
    0x80–0x9F mit sichtbaren Zeichen (Gedankenstrich 0x96, typografischer
    Apostroph 0x92, Auslassungspunkte 0x85); ab 0xA0 sind beide gleich. Die
    Tabelle für 0x80–0x9F steht ausgeschrieben in `MediaInfoReader`, weil
    `String.Encoding.windowsCP1252` nicht auf jeder Plattform verfügbar ist.
  - **Gewählt wird über eine Plausibilitätswertung des ganzen Feldes**, nicht
    mehr allein am Vorkommen eines C1-Bytes: Ein Buchstabe zählt mehr als ein
    Symbol, und ein Großbuchstabe direkt hinter einem Buchstaben („BŠckerei")
    zählt stark dagegen. Bei Gleichstand entscheidet weiterhin das C1-Byte für
    MacRoman — dann fehlt schlicht der Zusammenhang, etwa bei einem Feld aus
    einem einzigen Byte. Die reine C1-Regel zog sonst ein „Café – Bar" (é plus
    Gedankenstrich) komplett auf MacRoman und machte „CafÈ ñ Bar" daraus
    (Review-Fund 2026-08-20).
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
  91°, Länge 181° und Bewertung 99 mit Exit-Code 0. Die Prüfung ist deshalb
  bewusst ZWEIGETEILT (Review-Fund 2026-08-17, siehe
  [archiv-restore-vertrag.md](archiv-restore-vertrag.md)):
  - `ExifTool.requireValidCoreFields` prüft die Wertebereiche der Oberfläche
    (Bewertung −1…5, GPS-Grenzen). Sie gilt für eine vom Nutzer gewünschte
    Änderung — CLI (`Sources/tagx/ExifCommand.swift`) und App
    (`AppModel.swift`).
  - `ExifTool.requireWritableCoreFields` prüft nur die technische
    Schreibbarkeit (GPS vollständig und endlich). Sie gilt für den
    Archivimport (`TagArchive.swift`): Ein Bestandswert wie Bewertung 6 lag
    vor dem Backup wirklich in der Datei und muss dorthin zurückkönnen.
- **Bewertung ist ein Optional:** `ImageCoreFields.rating` ist `Int?`; nil
  heißt „die Datei trägt gar kein Rating-Tag", jeder Wert ist ein echter Wert.
  −1 ist Adobes dokumentiertes „abgelehnt" und wird von Bridge und Lightroom
  wirklich geschrieben — als Leerwert missverstanden löschte ein Restore genau
  dieses Tag, und der Read-back konnte es nicht merken (Review-Fund
  2026-08-20). Im Archivschema 1 stand −1 noch für beides; `TagArchiveIO`
  rechnet solche Archive beim Lesen um.
- `-overwrite_original` verhindert `_original`-Duplikate; `-n` für numerische
  Werte (GPS dezimal), sonst kommen formatierte Strings.

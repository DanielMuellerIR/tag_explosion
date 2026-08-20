# Archiv-/Backup-Vertrag: Export sichert Bestand, Import prüft Änderungen

Trigger: Arbeit an `TagArchive`/`TagArchiveIO`, an Wertebereichs-Prüfungen
(`requireValidCoreFields`, `requireStorableSeries`, `requireSupportedCover`)
oder wenn ein Export/Auto-Backup unerwartet scheitert.

## Der Vertrag (seit 2026-08-16)

- **Export/`validate` prüft nur strukturell** (Schema, Pflichtfelder,
  erkennbare Cover-Signatur). Fachliche Wertebereiche gehören dort NICHT hin:
  exiftool liest auch unmögliche Bestandswerte (Rating 6, GPS 91/181), und
  fremde EPUBs tragen `calibre:series_index` ohne Serie oder GIF-Cover. Ein
  Backup muss genau diesen Bestand sichern können — eine Wertebereichs-
  Prüfung im Export ließ `AppModel.backupIfNeeded` und damit JEDEN
  Batch-Save solcher Dateien scheitern, obwohl ganz andere Felder geändert
  wurden.
- **Der Import prüft je Eintrag zielbezogen**, in `applyEntry` VOR der
  Dry-run-Antwort und VOR `TrashBackup`: Ein Wert, den dieser Import nicht
  ändert (`original:` = frisch gelesener Zielstand), ist erlaubt; nur eine
  echte Änderung auf einen ungültigen/unspeicherbaren Wert scheitert — im
  Dry-run und im echten Lauf identisch, ohne vorher eine Papierkorb-
  Sicherung anzulegen.
- **Schreibfähigkeit ist Backend-Sache:** Was der Export sichern darf, muss
  das jeweilige Ziel-Backend auch wieder SETZEN können, sonst widersprechen
  sich Export- und Import-Vertrag (nicht wiederherstellbares Backup).
  Deshalb backendbezogen: EPUB speichert Serienindex ohne Serie
  (`calibre:series_index`) und Cover in JPEG/PNG/GIF/WebP
  (EPUB-Kernformate); ebook-meta-Formate bleiben bei JPEG/PNG und lehnen
  den nackten Index ab.

## Bewertung: „kein Tag" ist kein Wert (seit 2026-08-20)

- `ImageCoreFields.rating` ist `Int?`. nil heißt „die Datei trägt gar kein
  Rating-Tag"; JEDER Wert ist ein echter Wert und wird wörtlich
  zurückgeschrieben. Solange −1 zugleich der Leerwert war, löschte ein Restore
  genau das Tag, das Adobe Bridge und Lightroom für „abgelehnt" schreiben — und
  der Read-back konnte den Fehler nicht sehen, weil er das gelöschte Tag wieder
  als −1 las (Review-Fund 2026-08-20).
- Das Archivschema steht deshalb auf **2**. Schema 1 kannte nur `Int` und
  schrieb −1 für beides; `TagArchiveIO.normalizingLegacyValues` rechnet solche
  Archive beim Import auf nil um. Ohne diese Umrechnung schriebe ein alter
  Bestand plötzlich ein −1-Tag in Dateien, die vorher keines hatten. Beide
  Schemata bleiben importierbar.

## Restlücke (bewusst)

- Ein BMP-Cover in einem (spec-widrigen) fremden EPUB ist archivierbar und
  als No-op wiederherstellbar; hat sich das Ziel-Cover geändert, scheitert
  genau dieser Eintrag sauber in Dry-run UND Import (BMP ist kein
  EPUB-Kernformat und wird bewusst nicht geschrieben).

## Tests

- `TagArchiveTests`: „Bestand mit fachfremden Bildwerten…“, „Änderung AUF
  ungültige Bildwerte…“, „EPUB: Serienindex ohne Serie…“, „EPUB: GIF-Cover…“.
- `EbookToolTests`: „Serienindex ohne Serie: EPUB speichert ihn…“,
  GIF-Abschnitt in „Cover ohne gültige Bildsignatur wird abgelehnt“.

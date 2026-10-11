# Code-Review-Korrekturen 2026-10-11

Version 0.47.6 behebt vier bestätigte Fehler des Stands 0.47.5.

| Fehler | Korrektur und Nachweis |
| --- | --- |
| EPUB lädt lokale Dateien über externe XML-Entities. | Container-XML und OPF verwenden den gemeinsamen strengen XML-Parser. Zwei Regressionen lehnen externe SYSTEM-Entities beim Lesen und Schreiben ab; das EPUB bleibt bytegleich. Beide Fälle schlugen vor der Korrektur fehl. |
| Online-Cover ersetzt das erste eingebettete Bild. | Die App ersetzt das Frontcover anhand seines Typs oder ergänzt es. App-Tests prüfen Booklet vor Frontcover und fehlendes Frontcover, einschließlich Speichern und erneutem Lesen. |
| XMP-Ziele verschieben die Zuordnung zu offenen Editoren. | Die Quellenzuordnung nach Archivpfad wird getrennt von allen Zugriffs-URLs weitergegeben. Ein echter App-Import mit Bild, XMP und nachfolgender Audiodatei zeigt den neuen Audiotitel auch im offenen Editor. |
| Lesbare Kapitel-/Lyrics-Bestände blockieren Export und Auto-Backup. | Strukturelle Prüfung erlaubt überlappende Bestandskapitel und leere SYLT-Frames mit Sprache. Wiederherstellung erhält diese Werte; normale Kapiteländerungen bleiben streng geprüft und normales Leeren entfernt SYLT weiterhin. Unabhängig erzeugte ID3-Frames prüfen Kapitel, SYLT und die Kombination. Ein App-Batch-Test prüft Auto-Backup und gespeicherte Titel. |

## Ausgeführte Prüfungen

- Core: `swift test --filter
  'TagArchiveTests|ChapterTests|FixedFieldsTests|EbookToolTests'`:
  133 Tests in vier Suiten bestanden. Abgedeckt sind beide EPUB-Entity-Fälle,
  vorhandene EPUB-Roundtrips, drei Audio-Bestandsvarianten,
  Archiv-Wiederherstellung, No-op, Dry-run und bisherige Zielschutztests.
- App: `swift test --filter
  'AppModelSaveTests|OnlineLookupApplyTests|LyricsEntryTests|BatchSaveTests'`:
  46 Tests in fünf Suiten bestanden. Der Cover-Test vergleicht den gespeicherten Bestand direkt mit den
  erwarteten Bildern; auch seine zusätzliche Einzelprüfung ist bestanden.
- `git diff --check`: bestanden.

Die Tests liefen unter macOS mit Swift 6.4 und System-TagLib 2.3.1. Bestehende
Build-Warnungen betreffen unter anderem das Deployment-Ziel der lokalen
TagLib-Bibliothek. Kein Linux-Lauf, visueller GUI-Test oder notarisierter
Installations-/Release-Lauf; die App-Abläufe wurden headless über den
produktiven Daten- und Speicherweg geprüft. Das Layout wurde nicht verändert.

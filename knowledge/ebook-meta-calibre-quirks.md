# Calibre `ebook-meta`: azw3-Serie geht verloren, Datums-Zeitzone

**Trigger:** Arbeit am E-Book-Backend für mobi/azw3/fb2 (EbookTool → ebook-meta),
oder Nutzer wundert sich, dass eine Serie bei azw3 nach dem Speichern weg ist.

## Serie wird bei azw3 nicht persistiert

`ebook-meta datei.azw3 --series X --index 7` meldet Erfolg, aber ein erneutes
`ebook-meta datei.azw3` zeigt keine Serie (verifiziert 2026-07-17, Calibre 7.7.0).
Bei EPUB funktioniert dasselbe Kommando. Auch `ebook-convert` epub→azw3 nimmt
die Serie nicht mit. Konsequenz im Code:

- `EbookToolTests` prüft die Serie beim azw3-Roundtrip bewusst nicht.
- Kein Workaround eingebaut; die App zeigt nach Speichern+Neuladen den echten
  Dateizustand — die Serie verschwindet dann sichtbar (ehrlich statt still).

## Datum: reines Datum rutscht einen Tag zurück

`--date 2023-11-05` interpretiert Calibre in der lokalen Zeitzone, die Ausgabe
(`Published`) ist aber UTC → `2023-11-04T22:00:00+00:00`. Deshalb schreibt
`EbookTool.writeCalibre` reine Datumsangaben immer als `T00:00:00+00:00`
(UTC-Mitternacht); gelesen wird nur das Datums-Präfix.

## Ausgabe-Parsing

Labels von `ebook-meta` sind lokalisiert → immer mit `LC_ALL=C` aufrufen
(`EbookTool.runCalibre` erledigt das via `/usr/bin/env`).

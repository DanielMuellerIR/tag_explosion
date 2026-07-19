# Calibre `ebook-meta`: azw3-Serie, leere Felder und Cover-Grenze

**Trigger:** Arbeit am E-Book-Backend für mobi/azw3/fb2 (EbookTool → ebook-meta),
oder Nutzer wundert sich, dass eine Serie bei azw3 nach dem Speichern weg ist,
ein leeres Feld anders dargestellt wird oder ein Cover nicht entfernt werden kann.

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

Ein **leeres** `--date ""` speichert bei Calibre 7.7 kein echtes Nullfeld,
sondern den in der CLI-Ausgabe beobachtbaren Undefined-Date-Sentinel
`0101-01-01T00:00:00+00:00`. `EbookTool.readCoreFields` bildet genau diesen
Sentinel auf `date == ""` ab. Der Roundtrip-Test kontrolliert zusätzlich die
direkte `ebook-meta`-Ausgabe, damit ein alter realer Datumswert nicht nur im
eigenen Parser verschwindet.

## Serienindex: kein indexloser Serienzustand

`ebook-meta --index ""` bricht mit einem `ValueError` ab; Werte wie `nan`
können Metadaten beschädigen und sind keine Alternative. Wenn eine Serie
erhalten bleibt und ihr Index im Bearbeitungspuffer geleert wird, schreibt
Tag Explosion deshalb den sicheren Calibre-Default `--index 1`. Das entfernt
einen alten Index (zum Beispiel `#7`), stellt aber **keinen** Nullzustand dar;
der anschließende Read-back lautet wahrheitsgemäß `#1`.

## Cover: mit ebook-meta nicht sicher löschbar

Die öffentliche `ebook-meta`-CLI dokumentiert `--cover <datei>` zum Setzen,
aber keine Löschoperation. Auch ein existierender Pfad wie `/dev/null` meldet
Erfolg, lässt ein vorhandenes Cover bei Proben jedoch unverändert. Ein
Archiv-Eintrag mit `artworks: []` verlangt ausdrücklich das Entfernen und wird
für Calibre-E-Books daher **vor allen Archivschreibvorgängen** abgelehnt.
`artworks: null` bedeutet dagegen weiterhin „nicht archiviert“ und bleibt
unverändert anwendbar. Keine interne `calibre-debug`-API als Workaround nutzen:
deren Verhalten ist nicht Teil der stabilen Calibre-CLI-Schnittstelle.

## Ausgabe-Parsing

Labels von `ebook-meta` sind lokalisiert → immer mit `LC_ALL=C` aufrufen
(`EbookTool.runCalibre` erledigt das via `/usr/bin/env`).

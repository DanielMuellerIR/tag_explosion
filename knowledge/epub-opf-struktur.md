# EPUB-OPF: Der Paket-Identifier hängt an der ISBN

**Trigger:** Änderungen an `EpubFile` (Schreiben von Identifiern, Serien,
Creator), oder ein geschriebenes EPUB wird von einem Reader/epubcheck
abgelehnt, obwohl die Felder beim Zurücklesen richtig aussehen.

## Die Falle

Ein OPF-Paket nennt im Wurzelelement die id des Identifiers, der das Buch
eindeutig macht:

```xml
<package … unique-identifier="uid">
  <metadata …>
    <dc:identifier id="uid" opf:scheme="ISBN">9783161484100</dc:identifier>
```

In der Praxis — und in beiden Test-Fixtures (`book2.epub`, `book3.epub`) — ist
das genau der **ISBN**-Knoten. Wer die ISBN ändert oder löscht, entfernt damit
das Ziel des Paketverweises. Das Ergebnis ist ein OPF mit einem
`unique-identifier`, der auf nichts mehr zeigt: strukturell ungültig, auch wenn
`readCoreFields` die neue ISBN anschließend brav zurückliest. Ein reiner
Feld-Roundtrip-Test bemerkt den Schaden deshalb nicht.

## Regel im Code

`EpubFile.writeIsbn` bekommt das `package`-Element mit und:

- übernimmt beim **Ersetzen** die id des Paket-Identifiers auf den neuen Knoten
  (vorhandene `refines`-Verfeinerungen wie `identifier-type: ISBN` bleiben damit
  richtig);
- setzt beim **Löschen** einen neutralen `urn:uuid:…`-Identifier unter derselben
  id ein und entfernt dessen alte Verfeinerungen (sie beschrieben die ISBN);
- entfernt die Verfeinerungen aller übrigen gelöschten Identifier, damit keine
  verwaisten `refines`-Verweise zurückbleiben.

Dieselbe Regel gilt sinngemäß für jeden Knoten, auf den aus dem OPF heraus
verwiesen wird — deshalb tragen auch `replaceAuthors` und `writeSeries` ihre
Verfeinerungen mit (`detachRefinements`) und vergeben neue XML-IDs eindeutig
über das **ganze** Dokument (`allIds`), nicht nur unter den Geschwistern.

## Prüfung

`EbookToolTests` enthält für beide Fixtures je einen Test für Änderung und
Löschung, der den Verweis auflöst statt nur das Feld zurückzulesen
(`packageIdentifierValue`). Wer hier etwas umbaut, prüft am besten zusätzlich
mit `epubcheck`, falls installiert.

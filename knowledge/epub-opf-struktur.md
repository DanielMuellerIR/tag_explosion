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

Dieselbe Sorgfalt gilt für jeden Knoten, auf den aus dem OPF heraus verwiesen
wird — die weiteren Schreibwege verhalten sich dabei aber unterschiedlich:

- `replaceAuthors` **entfernt** die Verfeinerungen der gelöschten
  Autoren-Knoten (`detachRefinements`) und legt die neuen Creator **ohne**
  XML-IDs an — es gibt danach nichts, worauf ein `refines` zeigen könnte.
- `writeSeries` entfernt die alten Serien-Verfeinerungen und vergibt für den
  neuen Serien-Knoten eine XML-ID, die über das **ganze** Dokument eindeutig
  ist (`allIds`), nicht nur unter den Geschwistern — auch `dc:creator`,
  `dc:identifier` oder ein Manifest-Eintrag kann die Wunsch-ID schon tragen.
- `setList` entfernt beim Ersetzen mehrwertiger Felder wie `dc:subject` auch
  deren Verfeinerungen. Sonst blieben etwa Normvokabular-Angaben mit
  `refines="#alte-id"` ohne Ziel zurück.

Einwertig dargestellte Felder können im OPF trotzdem mehrfach vorkommen. Eine
Änderung des ersten `dc:title` darf deshalb weitere Titel, etwa einen per
`title-type` markierten Untertitel, nicht löschen. `setSingle` ändert bei einem
nichtleeren neuen Wert nur den ersten Knoten und erhält die übrigen samt ihren
Verfeinerungen. Wird das dargestellte Feld ausdrücklich geleert, entfernt es
alle zugehörigen Knoten und ihre Verfeinerungen gemeinsam.

## Prüfung

`EbookToolTests` enthält für beide Fixtures je einen Test für Änderung und
Löschung, der den Verweis auflöst statt nur das Feld zurückzulesen
(`packageIdentifierValue`). Wer hier etwas umbaut, prüft am besten zusätzlich
mit `epubcheck`, falls installiert.

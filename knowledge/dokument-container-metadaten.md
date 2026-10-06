# Dokument-Metadaten: OOXML, OpenDocument, ComicInfo, Markdown-Frontmatter

**Trigger:** Arbeit an `DocumentTool`, `ZipContainer`, einem der vier Backends
(`OfficeDocumentFile`, `OpenDocumentFile`, `ComicArchiveFile`,
`MarkdownDocumentFile`), an `tagx doc` oder dem Dokument-Editor — oder ein
geschriebenes Dokument wird von Word/LibreOffice/einem Comic-Reader abgelehnt.

## Container: neu aufbauen statt anhängen

`ZipContainer.rewrite` schreibt das ZIP komplett neu — Reihenfolge,
Kompressionsart, Änderungszeit und Rechte jedes Eintrags bleiben, nur die
genannten Einträge bekommen neuen Inhalt; neue Pfade kommen ans Ende.
Grund: OpenDocument verlangt `mimetype` **unkomprimiert an erster Stelle**.
Der EPUB-Weg (`EpubFile`: Eintrag entfernen, neu anhängen) hätte einen
ersetzten `mimetype` ans Ende geschoben. EpubFile bleibt bewusst bei seinem
getesteten Schreibweg; für das Lesen nutzt es ebenfalls den gemeinsamen
CRC-geprüften Leser aus `ZipContainer`.

Unveränderte Dateieinträge über 1 MiB laufen blockweise durch eine Datei im
privaten Arbeitsordner; kleine Einträge bleiben im Speicher. `readChunk`
begrenzt unter macOS zusätzlich die Lebensdauer temporärer Foundation-Puffer.
Ohne diesen Autorelease-Pool sammelt selbst blockweises Lesen den gesamten
Inhalt bis zum Ende des CLI-Befehls im Speicher.

Messung 2026-09-08 (macOS arm64, Debug-CLI, `/usr/bin/time -l`): Titeländerung
in einer synthetischen DOCX mit einem unkomprimierten 128-MiB-Eintrag sank
von 283.787.264 auf 15.843.328 Byte Spitzenspeicher. SHA-256 des Eintrags und
ZIP-Prüfsummen blieben korrekt. Die Einzelmessungen belegen den Speichergewinn,
keine verlässliche Beschleunigung.

Grenzen: Erweiterungsfelder der ZIP-Einträge gehen verloren.
Verschlüsselte oder anders als deflate/stored komprimierte Archive scheitern
mit `saveFailed`.

## ZIP-Prüfsummen

`Archive.extract` aus ZIPFoundation liefert die berechnete CRC32 zurück,
vergleicht sie aber nicht mit `Entry.checksum`. `ZipContainer.extract` übernimmt
diesen Vergleich für Dokumente und EPUB. Ein abweichender Wert bricht den
Lese- oder Schreibvorgang ab; besonders beim ZIP-Neuaufbau dürfen beschädigte
Nutzdaten nicht mit einer neuen gültigen Prüfsumme als unversehrt erscheinen.
`ZipIntegrityTests` verändert gezielt die gespeicherte CRC, während Inhalt und
ZIP-Struktur lesbar bleiben, und prüft kleine sowie große Nutzdateneinträge.

## OOXML (docx/xlsx/pptx)

- `docProps/core.xml` ist kein Pflichtteil. Fehlt es, legt `mutate` es an
  **und** registriert es in `[Content_Types].xml` (Override) und
  `_rels/.rels` (Relationship) — ohne beides ignoriert Word die Datei.
- `dcterms:created`/`dcterms:modified` brauchen `xsi:type="dcterms:W3CDTF"`
  und einen W3CDTF-Wert; anderes meldet Word als beschädigten Inhalt. Der
  Core lehnt Werte außerhalb von `DocumentTool.isW3CDateTime` vorab ab.
- Mehrere Autoren stehen in `dc:creator` als `A; B`; `cp:keywords` ist ein
  String (`a, b` oder `a; b`). Werte mit dem jeweiligen Trennzeichen werden
  abgelehnt, weil das Zurücklesen sonst mehr Werte liefert als geschrieben.
- Kein Speicherort für `publisher`.

## OpenDocument (odt/ods/odp)

- Semantikfalle: `dc:creator` ist die Person der **letzten Änderung**,
  `meta:initial-creator` die ursprüngliche Autorin. Die Zuordnung
  `authors ↔ dc:creator` wurde trotzdem gewählt, damit OOXML und ODF gleich
  abgebildet sind; `initial-creator` ist als Zusatzfeld editierbar.
- `meta:keyword` ist mehrwertig (ein Element je Schlagwort).
- Kein Speicherort für `publisher` und `category`.
- Fehlt `meta.xml`, wird es angelegt und in `META-INF/manifest.xml`
  eingetragen.

## ComicInfo.xml (cbz)

- Das Schema ist eine `xs:sequence`; neue Elemente werden an der
  schemagerechten Stelle eingefügt (`schemaOrder`), nicht angehängt.
- Datum = `Year`/`Month`/`Day` als Ganzzahlen; `created` akzeptiert
  `YYYY`, `YYYY-MM`, `YYYY-MM-DD`. `Writer` ist kommagetrennt.
- Cover = erste Bildseite in **natürlicher** Sortierung
  (`localizedStandardCompare`: `page-2` vor `page-10`), ohne `__MACOSX/`.
  Reine Anzeige: Seitenbilder werden nie verändert, das Archiv sichert das
  Cover nicht.
- cbr (RAR) bewusst nicht: ohne fremde Bibliothek nicht lesbar, ohne
  RAR-Programm nicht schreibbar.

## Markdown-Frontmatter

- Eigener Mini-Parser für das flache Subset (Skalar, `[a, b]`, `- a`).
  Alles andere (verschachtelte Maps, `|`/`>`-Blockskalare, Anker, Fließmaps)
  bleibt als **komplexer** Eintrag erhalten und wird beim Schreiben
  unverändert durchgereicht; ein Schreibversuch auf so einen Schlüssel
  scheitert mit `invalidDocumentValue`.
- Nur geänderte Einträge werden neu erzeugt, unveränderte kommen aus ihren
  Rohzeilen; Reihenfolge bleibt, neue Schlüssel ans Ende. Der Body nach dem
  schließenden `---` wird byte-identisch übernommen (Zeilen werden auf
  Byte-Ebene getrennt — Swift-Strings fassen `\r\n` sonst als EIN Zeichen).
  Zeilenende (`\n`/`\r\n`) und BOM bleiben erhalten.
- Eine Zeile ohne `key:`-Form (z.B. `http://x: y`) gilt als Fortsetzung des
  vorigen Eintrags und macht ihn komplex — nichts geht verloren.
- Beim Schreiben werden Werte quotiert, die YAML sonst umdeutet (Zahlen,
  `true`/`no`, führendes `#`/`-`/`[`, `: ` im Text); ISO-Daten bleiben
  unquotiert.
- `authors` (Liste) gewinnt beim Lesen gegen `author`; geschrieben wird in
  den vorhandenen Schlüssel, sonst `author` für eine Person, `authors` für
  mehrere.

## Gemeinsame Regel

Was ein Format nicht speichern kann, lehnt `DocumentTool.requireWritable`
**vor** Sicherung und Schreibweg ab (`unsupportedDocumentField`,
`invalidDocumentValue`); App, CLI und Archiv-Import nutzen dieselbe Prüfung.
Nach dem Schreiben wird die Geschwisterkopie zurückgelesen und muss exakt die
Zielfelder liefern, sonst ersetzt sie das Original nicht.

## Eingabegrenzen und Office-Pfade (2026-10-06, 0.47.4)

ZIP-Metadaten werden höchstens bis 16 MiB, Cover bis 64 MiB entpackt. Die
Prüfung gilt vor dem Entpacken und für jeden gelesenen Block. Große unveränderte
Nutzdaten beim ZIP-Neuaufbau werden weiterhin blockweise kopiert.

XML lädt keine externen Entities. Externe DTD-/Entity-Deklarationen und
Parameter-Entities werden
abgelehnt, damit ein Write sie nicht als leere Feldwerte übernimmt. NFOs behalten
interne Entity-Inhalte und den ursprünglichen Vorspann.

OOXML-Relationship-Ziele sind URI-Referenzen: Punktsegmente werden aufgelöst,
Nicht-ASCII-Zeichen in ZIP-Partnamen prozentkodiert und führende Schrägstriche
entfernt. Bereits kodierte ASCII-Zeichen wie `%20` bleiben im ZIP-Namen kodiert;
Partnamen werden ohne Beachtung der ASCII-Groß-/Kleinschreibung verglichen.
EPUB 2 erhält beim Anlegen von Serie/Cover ausschließlich seine zulässigen
name/content-Metadaten; property/refines und cover-image gelten für EPUB 3.

### Portable XML-Prüfung ab 0.47.4

Vor dem DOM-Aufbau müssen `XMLParser.parse()` und ein leerer `parserError`
wohlgeformtes XML bestätigen; externe Auflösung ist ausdrücklich gesperrt.
Unter Swift 6.0/Linux erzwingt der DOM-Leser sonst Fehlerkorrektur. Sein
`XMLDocument.dtd`-Getter stürzt ohne DTD ab, und `XMLDTDNode.isExternal`
stürzt bei internen Entities ab. Die Prüfung verwendet daher auf Linux die
Dokumentkinder und bei beiden Plattformen ausschließlich die sicheren
XMLDTD-Identifier und deren serialisierte Deklaration. Gewöhnliche interne
Entities bleiben erlaubt; Parameter-Entities werden wegen möglicher weiterer
Deklarationen abgelehnt. Tests prüfen SYSTEM/PUBLIC, kommentierte und zitierte
Schlüsselwörter, interne Entity-Inhalte und verschiedene XML-Kodierungen.

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
getesteten Weg; die Backends hier teilen sich nur `ZipContainer`.

Grenzen: Jeder Eintrag läuft beim Kopieren einmal durch den Speicher
(nacheinander); Erweiterungsfelder der ZIP-Einträge gehen verloren.
Verschlüsselte oder anders als deflate/stored komprimierte Archive scheitern
mit `saveFailed`.

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

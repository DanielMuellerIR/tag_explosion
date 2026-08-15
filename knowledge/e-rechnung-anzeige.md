# E-Rechnungs-Anzeige (ZUGFeRD/Factur-X/XRechnung/Peppol)

Trigger: Arbeit an `Sources/EInvoiceCore/`, an `tagx invoice` oder an der
Rechnungsansicht der App.

## Grundsätze

- **Nur Anzeige.** Kein Validieren, kein Rendern als Rechnung, kein Schreiben.
  Der Wert des Features ist: Profil erkennen + jedes befüllte Feld mit seiner
  EN-16931-Feldbezeichnung (BT-/BG-Nummer) zeigen. Was keine Nummer hat,
  bleibt als Rohpfad sichtbar — nie Felder verschlucken.
- Zwei Syntaxen decken fast alles ab: **CII** (ZUGFeRD 2.x = Factur-X,
  XRechnung-CII) und **UBL** (XRechnung-UBL, Peppol BIS). Gutschriften in UBL
  (`ubl:CreditNote`) werden per Pfad-Normalisierung auf die Invoice-Tabelle
  abgebildet statt eine zweite Tabelle zu pflegen.

## Erkennung

- **Profil = BT-24** (Spezifikationskennung): CII unter
  `ExchangedDocumentContext/GuidelineSpecifiedDocumentContextParameter/ID`,
  UBL in `cbc:CustomizationID`. Die URN nennt Standard + Profil exakt
  (`urn:factur-x.eu:1p0:basic`, `…kosit:xrechnung_3.0`, `…peppol.eu…`).
  Auflösung über Muster, nicht exakte Strings — Versionssuffixe ändern sich.
  Unbekannte URN ehrlich als „EN 16931-basiert?" mit Roh-URN zeigen.
- **Deutsche Praxis-Falle:** Das EN-16931-Profil von Factur-X nutzt als
  Guideline exakt `urn:cen.eu:en16931:2017` — vom XML allein ist „Factur-X
  EN 16931" nicht von „reine EN 16931" unterscheidbar. Die PDF-Herkunft
  sieht man an der XMP-Deklaration (`fx:ConformanceLevel`).
- **Inhalts-Schnelltest** statt Endungs-Vertrauen: `.xml` wird nur als
  Rechnung angenommen, wenn das erste Start-Element einen bekannten lokalen
  Namen **und** den passenden Rechnungs-Namensraum trägt
  (`EInvoiceReader.sniffXML`). Der SAX-Parser liest einen Dateistream nur bis
  zu diesem Element; dadurch bleiben auch mehr als 8 KiB Prolog oder Kommentare
  zulässig, ohne große Fremd-XMLs vollständig in den Speicher zu laden. Sonst
  zöge ein Ordner-Drop beliebige Fremd-XMLs in die App.

## Fallen

- **Namensraum-Präfixe sind frei wählbar.** Der XML-Baum (`XMLTree`)
  kanonisiert Präfixe über die Namensraum-URIs (rsm/ram/udt/qdt bzw.
  ubl/cac/cbc); alle Pfad-Tabellen setzen darauf auf. Nie über
  Dokument-Präfixe mappen.
- **BOM und Großschreibung:** Reale Dateien kommen mit UTF-8-BOM und als
  `.PDF` — Endungsvergleiche immer lowercased, XMLParser schluckt den BOM.
- **`ram:TypeCode = VAT`** (Umsatzsteuerart) hat in EN 16931 wirklich keine
  BT-Nummer — das ist kein Mapping-Loch.
- **Ambige Elemente brauchen Kontext:** Nachlass vs. Zuschlag entscheidet der
  `ChargeIndicator` im selben Container (BG-20/21 bzw. BG-27/28 mit je
  eigenen BT-Nummern); USt-IdNr. vs. Steuernummer das `schemeID`-Attribut
  (VA/FC) bzw. das `TaxScheme` — und die BT-Nummer hängt zusätzlich an der
  Partei (Verkäufer/Käufer/Steuerbevollmächtigter). BT-110 vs. BT-111
  entscheidet die Währung gegen BT-5.
- **PDF-Extraktion über CGPDF** (Catalog → Names → EmbeddedFiles, plus
  `AF`-Array): einziger Apple-only-Teil von EInvoiceCore, gekapselt in
  `PDFEmbeddedInvoice.swift` (`#if canImport(CoreGraphics)`).
  `CGPDFStreamCopyData` dekomprimiert Flate selbst. Bevorzugte eingebettete
  Dateinamen: `factur-x.xml`, `zugferd-invoice.xml`, `ZUGFeRD-invoice.xml`,
  `xrechnung.xml` — sonst erstes eingebettetes XML, das der Schnelltest
  als Rechnung erkennt.
- **XMP-Attributform:** Attribut-Namensräume sind mit XMLParser nicht
  auflösbar; die Deklaration akzeptiert Attribute nur mit den
  konventionellen Präfixen (`fx:`, `zf:`, …), Elemente dagegen präzise über
  ihre Namensraum-URI (`…pdfa:CrossIndustryDocument…`).
- **ZUGFeRD 1.0** (`rsm:CrossIndustryDocument`, vor EN 16931) wird erkannt
  und roh angezeigt, aber bewusst ohne BT-Zuordnung — sinngemäßes Mapping
  wäre potenziell falsch.

## Testbasis

- Fixtures sind selbstgeschriebene Minimal-XMLs im Test (absichtlich mit
  exotischen Präfixen) und ein handgebautes Mini-PDF mit Namensbaum,
  AF-Array und XMP — `Tests/TagExplosionCoreTests/EInvoiceTests.swift`.
- Vollständigkeits-Invariante: Zahl der Anzeigefelder == Zahl der
  XML-Elemente. Gegen echte Dateien per
  `tagx invoice --json … | python3` gegengerechnet (2026-08-14: 161/161).

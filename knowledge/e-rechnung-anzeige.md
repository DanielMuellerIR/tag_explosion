# E-Rechnungs-Anzeige (ZUGFeRD/Factur-X/XRechnung/Peppol)

Trigger: Arbeit an `Sources/EInvoiceCore/`, an `tagx invoice` oder an der
Rechnungsansicht der App.

## Grundsätze

- **Nur Anzeige.** Kein Rendern als Rechnung, kein Schreiben. Der Wert des
  Features ist: Profil erkennen + jedes befüllte Feld mit seiner
  EN-16931-Feldbezeichnung (BT-/BG-Nummer) zeigen. Was keine Nummer hat,
  bleibt als Rohpfad sichtbar — nie Felder verschlucken.
- **Grundvalidierung, keine Schematron-Prüfung** (`EInvoiceValidation`):
  Pflichtfelder BT-1/2/3/5/27/44/106/109/112/115 (XRechnung: BT-10) und die
  Summenkette BT-106 = Σ BT-131, BT-109 = BT-106 − BT-107 + BT-108,
  BT-110 = Σ BT-117, BT-112 = BT-109 + BT-110, BT-115 = BT-112 − BT-113 +
  BT-114, Toleranz 0,01. Ergebnis sind Hinweise (`warnings`), nie eine
  Verweigerung der Anzeige; `tagx invoice --strict` liefert Exit 3. Die
  Codes sind die Regelkennungen der Norm (BR-02 … BR-15, BR-CO-10/13/14/15/16)
  und der XRechnung (BR-DE-15), damit man sie in Validatoren wiederfindet.
- Zwei Syntaxen decken fast alles ab: **CII** (ZUGFeRD 2.x = Factur-X,
  XRechnung-CII) und **UBL** (XRechnung-UBL, Peppol BIS). Gutschriften in UBL
  (`ubl:CreditNote`) werden per Pfad-Normalisierung auf die Invoice-Tabelle
  abgebildet statt eine zweite Tabelle zu pflegen. Die **Dokumentart**
  (`documentKind`) kommt aus Wurzel + Typcode: `ubl:CreditNote` oder BT-3 =
  381 → Gutschrift; Order-X-Typcode 231 bzw. `ubl:OrderResponse` →
  Bestellantwort.
- **Bestellungen** (Order-X in CIO-Syntax, Peppol `ubl:Order`/
  `ubl:OrderResponse`) folgen nicht der EN 16931. Ihre Felder tragen
  deshalb eine deutsche Order-X-Bezeichnung in `termName`, aber KEIN
  `term` — die Order-X-Spezifikation nummeriert ihre Terme eigenständig, und
  die Nummern ließen sich nicht verlässlich belegen (ferd-net verteilt die
  Spezifikation nur als Download-Paket). Lieber Bezeichnung ohne Nummer als
  eine falsche Nummer. Anzeige und CLI zeigen `termName` auch ohne `term`;
  `--terms-only` behält beschriftete Felder. Beteiligte werden generisch als
  „Rolle: Feld" beschriftet (`OrderXMapping.parties`/`partyFields`).

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

- **Order-X-Namensraum ohne „standard":** Die CIO-Wurzel heißt
  `rsm:SCRDMCCBDACIOMessageStructure` (offizieller Schemaname) im Namensraum
  `urn:un:unece:uncefact:data:SCRDMCCBDACIOMessageStructure:100` — anders als
  CII fehlt das Segment `standard`; ram/udt/qdt kommen mit Version `:128`.
  Erkennung und Präfix-Kanonisierung prüfen deshalb den Stamm plus den
  Schemanamen, nicht die CII-Form. Währung heißt dort `ram:OrderCurrencyCode`,
  Menge `ram:RequestedQuantity`; das PDF-XMP nutzt denselben
  Factur-X-Namensraumstamm (`urn:factur-x:pdfa:CrossIndustryDocument:1p0#`)
  mit `DocumentType` ORDER/ORDER_RESPONSE/ORDER_CHANGE und Anhang
  `order-x.xml` (Quelle: Mustangproject `OXExporterFromA3`, Order-X-XSD).
- **Summenprüfung nur in Rechnungswährung:** UBL wiederholt `cac:TaxTotal`
  in der Steuerwährung (BT-111); deren `TaxSubtotal/TaxAmount` ist ebenfalls
  BT-117 gemappt. Die Summe der Steuerbeträge lässt Beträge mit `currencyID`
  ≠ BT-5 deshalb aus, sonst zählt die Steuer doppelt. Ein nicht lesbarer
  Betrag (Komma, Tausenderpunkt) lässt die betroffene Regel still aus.
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
- **PDF-Extraktion über CGPDF** (Catalog → AF-Array zuerst, dann Names →
  EmbeddedFiles): einziger Apple-only-Teil von EInvoiceCore, gekapselt in
  `PDFEmbeddedInvoice.swift` (`#if canImport(CoreGraphics)`).
  `CGPDFStreamCopyData` dekomprimiert Flate selbst. Bevorzugte eingebettete
  Dateinamen: zuerst der in XMP deklarierte `DocumentFileName`, danach
  `factur-x.xml`, `zugferd-invoice.xml` und `xrechnung.xml`; sonst das erste
  eingebettete Rechnungs-XML in PDF-Reihenfolge (AF vor Namensbaum). Das
  AF-Array läuft bewusst VOR dem Namensbaum und der deklarierte Dateiname hat
  einen reservierten Platz jenseits des DATEIbudgets — sonst könnten 32
  fremde XML-Anhänge die echte Rechnung aus dem Budget drängen. Die
  Byte-Budgets unten gelten allerdings auch für ihn: Eine deklarierte Rechnung,
  die allein größer als das Anzeigebudget ist, wird nicht angezeigt.
- **Grenzen der Extraktion** (präparierte PDFs): Dateibudget 32 Anhänge,
  Namensbaum zusätzlich mit Knoten-Budget (4096) gegen sich selbst
  referenzierende `/Kids` (Tiefengrenze allein ließe 2^32 Besuche zu). Für die
  Bytes gelten ZWEI getrennte Budgets:
  - **Anzeigebudget 64 MiB** — so groß darf die Summe der BEHALTENEN Anhänge
    werden. Ein einzelner Anhang, der nicht mehr hineinpasst, wird nur
    übersprungen; die Suche läuft weiter.
  - **Arbeitsbudget 256 MiB** (das Vierfache) — so viel darf insgesamt
    entpackt werden, verworfene Anhänge eingeschlossen. Es bremst dieselbe
    Dekompressionsbombe, wenn sie vielfach im Namensbaum steht.
  Ein einziger Zähler für beides war ein Versteck-Primitiv: EIN übergroßer
  Anhang vor der Rechnung sperrte jeden weiteren Kandidaten, und die Datei galt
  als „keine E-Rechnung", während andere Leser dieselbe Rechnung anzeigten
  (Review-Fund 2026-08-20). Verworfene Anhänge kommen außerdem in `seenNames`,
  damit derselbe Stream unter demselben Namen nicht erneut entpackt wird.
- **Restrisiko Dekompressionsbombe:** CGPDF bietet keine inkrementelle
  Dekomprimierung; `CGPDFStreamCopyData` materialisiert immer den ganzen
  Anhang. Vorab begrenzbar ist nur, was physisch in der Datei liegt:
  - GEFILTERTER Stream: deklariertes `/Length` ≤ 256 KiB. Eine EINZELNE
    Entpackung kann damit kurzzeitig rund 258 MiB belegen (256 KiB × 1032).
    Das ist bewusst mehr als das Anzeigebudget: Eine echte Rechnung mit 5000
    Positionen ist komprimiert schon etwa 100 KiB groß, eine streng
    abgeleitete Schranke von 64 KiB (64 MiB / 1032) würde sie unlesbar machen.
  - UNGEFILTERTER Stream: `/Length` ist bereits die entpackte Größe, eine
    Bombe also ausgeschlossen. Hier gilt das Anzeigebudget. Die enge
    256-KiB-Schranke wies sonst eine gültige, unkomprimiert eingebettete
    Rechnung ab — Factur-X schreibt keine Kompression vor (Review-Fund
    2026-08-20).
  - Keine `/Filter`-KETTEN (Kaskade potenziert die Flate-Rate ~1:1032);
    `/Params/Size` über dem Budget wird sofort abgelehnt.
- **Der XMP-Metadatenstrom hat eigene Grenzen** und zählt nicht gegen die
  Anhangs-Budgets: komprimiert ≤ 64 KiB, entpackt ≤ 4 MiB. Er wird genau
  einmal je PDF gelesen, eine Wiederholung gibt es dort nicht.
- **XMP-Attributform:** XMLParser liefert Attribut-Namensräume nicht direkt.
  `XMLTree` sammelt deshalb die Präfixdeklarationen am jeweiligen Element;
  die Auswertung löst das tatsächlich verwendete Präfix darüber zur
  veröffentlichten Factur-X-/ZUGFeRD-URI-Familie auf. Eine bloße
  `pdfa:CrossIndustryDocument`-Teilzeichenfolge genügt nicht, weil fremde
  XMP-Metadaten sonst eine Rechnung deklarieren und deren Anhang lenken
  könnten. Elemente tragen ihre URI direkt.
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

## QA 2026-09-08

`EInvoiceValidation.parseAmount` prüft die vollständige Dezimalschreibweise.
`Decimal(string:)` allein akzeptiert etwa den Anfang von `1.2.3`; auch
Vorzeichen mitten im Wert kamen vorher durch. Fehlende optionale Beträge
dürfen in der Summenformel null sein, unlesbare Beträge dagegen nicht.
Betroffene Summenregeln werden wie dokumentiert ausgelassen; die Rohwerte
bleiben sichtbar. Das ist weiterhin keine vollständige Syntaxvalidierung.
Vier parametrisierte Fälle verhindern erfundene Summenhinweise bei
unlesbarem Nachlass, Zuschlag, Steuerbetrag und Steueraufschlüsselung.

Peppol-Bestellprofile verlangen die vollständigen Komponenten `order:` bzw.
`order_response:`. Ähnliche unbekannte Kennungen wie `order_custom:` bleiben
unbekannt. Die Bestellansicht zeigt Spezifikation und Geschäftsprozess ohne
Rechnungs-Termnummern BT-24/BT-23; Rechnungsköpfe behalten ihre Nummern.

Die CLI-Tests dekodieren JSON in das Dokumentmodell statt Leerzeichen und
Textfragmente zu vergleichen. `--json --strict` ist damit ebenfalls geprüft;
die vier unabhängigen CLI-Tests laufen parallel.

Nachweis: 501 Core-Tests auf macOS, 119 App-Tests und 495 Core-/CLI-Tests
unter Linux (Swift 6.0, zwei CPU-Kerne) bestanden.

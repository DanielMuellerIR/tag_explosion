# Hybride PDF-Rechnungen prüfen

Stand: 2026-10-16, ab 0.52.0. App und `tagx validate-invoice` prüfen XML,
PDF/A und technische Einbettung getrennt. Die eigentlichen XML-Regeln bleiben
in KoSIT; veraPDF 1.30.3 prüft den unveränderten PDF-Schnappschuss mit der bereits
mitgelieferten privaten Temurin-Laufzeit. Es gibt keinen Upload und keine
zusätzliche Installation. Rechnungsdateien werden nicht verändert.

## Technischer Umfang

Unterstützt sind PDF/A-3a, 3b, 3u und 4f als Träger von CII-XRechnung bzw. aktuellen
ZUGFeRD-2.5.2-/Factur-X-1.09.2-Profilen. Maßgeblich für die eigenen Hybridregeln
sind Kapitel 6 und Anhang 3.d des zugehörigen Herstellerpakets.

Die Inspektion prüft genau einen primären CII-Rechnungsanhang, seine Übereinstimmung mit den
validierten XML-Bytes, Katalog-AF und EmbeddedFiles-Namensbaum, Dateiname,
MIME-Typ `text/xml`, AF-Beziehung und die vier XMP-Eigenschaften einschließlich
der eingebetteten Erweiterungsschema-Definitionen. Profilabhängige Empfehlungen
bleiben Warnungen. Zusätzliche Anhänge werden gegen die abschließende Formatliste
aus Kapitel 6.4 geprüft. Eine überschriebene Profilkennung ersetzt keine XML-Regeln.

Das XRechnung-Referenzprofil verlangt nach Kapitel 4 ebenfalls CII. Ein
XRechnung-UBL-Dokument kann als XML gültig sein, erfüllt aber dieses hybride
Referenzprofil nicht. Die nach Kapitel 6.4 zulässige zusätzliche UBL-Darstellung
muss `factur-xubl.xml` heißen. Sie zählt nicht als zweite primäre CII-Rechnung;
ihre eigenen XML-Regeln und Inhaltsgleichheit werden ausdrücklich als ungeprüft
ausgewiesen. Ein anders benannter UBL-Rechnungsanhang bleibt ein Fehler.

Die kanonische XMP-URI lautet gemäß Kapitel 6.3.1 und dessen Beispiel
`urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#`. Der abweichende Schreibfehler
in der Tabelle des Anhangs wird nicht als zweite URI übernommen. Die ausdrücklich
veraltete ZUGFeRD-URI und `zugferd-invoice.xml` bleiben für die fünf Factur-X-
Profile mit Warnung unterstützt; sie gelten nicht für das XRechnung-Referenzprofil.
Nationale Profilbedingungen werden nur bei eindeutig gleichen Verkäufer- und
Käuferländern angewandt. Lieferdatums-/Zeitraumhinweise sind technische Hinweise.

Ein technischer PDF/A-Fehler bleibt als Fehler sichtbar. Die nationale
Sonderbewertung aus BR-FX-DE-03 setzt rechtliche Voraussetzungen voraus, die
hier nicht bestätigt werden. Ein bestandenes XML bleibt deshalb getrennt
ablesbar; die App behauptet bei einem fehlerhaften Träger keinen Gesamterfolg.

## Grenzen und Fehlerzustände

Sichtbarer Rechnungsinhalt und XML werden nicht semantisch verglichen. Echtheit,
Signaturen, steuerliche Gültigkeit und Empfängerannahme werden nicht bestätigt.
Der vollständige Gewährleistungshinweis steht in App und exportiertem Bericht;
zwingende gesetzliche Haftung bleibt unberührt.

Ein fehlendes/manipuliertes Werkzeug, ein unvollständiger Bericht oder Abbruch
liefert keinen Erfolg. Die Auswertung verlangt genau einen vollständig beendeten
veraPDF-Auftrag und konsistente Versionen, Zähler und Exit-Codes. XML-Ergebnisse
bleiben bei einem späteren PDF-Werkzeugfehler erhalten. Bei geänderter Quelle
wird auch ein zuvor positives XML-Ergebnis verworfen.

Die bekannten Eingabe-/Extraktionsgrenzen des [gemeinsamen Kerns](e-invoice-validation-core.md)
gelten weiter. Die Containerinspektion begrenzt Verzeichniseinträge, Rekursion,
Anhänge und XML-/XMP-Daten. Erreichte Grenzen ergeben keine vollständige
Einbettungsbestätigung. Ein einzelner CoreGraphics-Dekompressionsaufruf ist
nicht unterbrechbar; das bereits dokumentierte Restrisiko bleibt bestehen.
veraPDF hat 512 MiB JVM-Heap, 60 Sekunden Prozessfrist und je 8 MiB Ausgabegrenze.
Dies ist keine harte Grenze für den gesamten Prozessspeicher.

## Paket und Nachweise

Das getrennte [PDF-Inventar](../licenses/pdf-validation/components.lock.json)
pinnt Original-JAR, Bibliotheken, Lizenztexte und passende Quellen. Alle 15
gebündelten PDF-Profile stimmen byteweise mit den bevorzugten Originalquellen
überein. Der Build verlangt zusätzlich zum bisherigen Quellenpaket
`TagExplosion-<version>-pdf-validation-sources.zip`. Beide Quellenpakete müssen
bei Weitergabe des Binärstands zugänglich bleiben. [Lizenzumsetzung](validation-licenses.md).

Eigene synthetische PDFs prüfen gültige Träger aller vier PDF/A-Stufen, Legacy-
Metadaten und gezielte Fehler in XMP, Namen, MIME, AF, Namensbaum, PDF/A und
zusätzlichen Anhängen. Laufzeittests benötigen vorbereitete Pakete:

```sh
TAGX_VALIDATION_BUNDLE=<KoSIT-Paket> TAGX_PDF_VALIDATION_BUNDLE=<PDF-Paket> \
  swift test --filter InvoicePDF
```

Die aktuellen Systemnachweise betreffen Apple Silicon. Eine passende deklarierte
Mindestversion bestätigt keinen tatsächlich ausgeführten Intel-/macOS-14-Lauf.

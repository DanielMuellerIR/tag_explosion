# Gemeinsamer Validierungskern

Stand: 2026-10-16, ab Version 0.49.0. Der hier beschriebene Dienst wird von
der CLI und seit 0.50.0 von der [App-Oberfläche](e-invoice-validation-app.md) verwendet.

## Quelldaten und Ergebnisbindung

`EInvoicePayload` in `EInvoiceCore` enthält das unveränderte XML, seine Herkunft
und gegebenenfalls die PDF-XMP-Deklaration. `EInvoiceReader.payload(url:)` und
`payload(fromPDF:)` verwenden dieselbe Anhangsauswahl wie die Anzeige.
`payload.document()` erzeugt das Anzeigemodell aus genau diesen Bytes.
Kodierung, BOM, CDATA, Präfixe und Leerraum werden nicht neu serialisiert.

`InvoiceValidationInput.capture(at:)` im portablen `TagExplosionCore` liest nur
reguläre Dateien, höchstens 16 MiB XML oder 64 MiB Träger-PDF. Der PDF-Parser
erhält den eingefrorenen Dateistand. Die vorhandenen Extraktionsbudgets gelten
zusätzlich; CoreGraphics bleibt die einzige Apple-Abhängigkeit beim PDF-Lesen.
Ein FIFO blockiert das Einlesen nicht. Die Extraktion kann innerhalb eines
CoreGraphics-Aufrufs nicht unterbrochen werden; Abbruch wird davor und danach
geprüft. Das bekannte Dekompressions-Restrisiko ist in
[e-rechnung-anzeige.md](../knowledge/e-rechnung-anzeige.md) beschrieben.

Das Ergebnis enthält SHA-256 von XML und Trägerdatei, URL und Dateistempel.
Die Quelle wird vor und nach der Prüfung erneut abgeglichen; gleiche Größe
und zurückgesetzte Änderungszeit reichen nicht, um geänderte Bytes als aktuell
zu behandeln. Ein Ergebnis ist eine Aussage zum genannten Dateistand. Die App
muss bei späteren Änderungen invalidieren und an der Übergabegrenze nochmals
`result.isCurrent(at:)` prüfen.

## Regeln und Prüfumfang

`InvoiceValidationRuleSet.xrechnung` verbindet XRechnung 3.0.2, Konfiguration
2026-08-31 und KoSIT 1.6.3 mit dem SHA-256 des geprüften Lizenzinventars.
Unterstützte Kombinationen aus exakter Spezifikationskennung, Syntax und
KoSIT-Szenario sind darin als Metadaten hinterlegt:

- XRechnung 3.0: CII, UBL Invoice und UBL CreditNote.
- XRechnung Extension 3.0: CII und UBL Invoice, entsprechend der Konfiguration.

Unbekannte Versionssuffixe, mehrere Spezifikationskennungen oder gleichnamige
Elemente in fremden Namensräumen werden nicht als bekannte Profile geraten.
CVD, UBL ohne unterstützte Spezialisierung und Peppol sind hier noch keine freigegebenen
Prüfprofile. Die Anzeigeerkennung ist absichtlich großzügiger als das Routing
einer verbindlich benannten technischen Prüfung.

Ab 0.51.0 ergänzt `InvoiceValidationRuleSet.facturX` die Profile MINIMUM,
BASIC WL, BASIC, EN 16931 und EXTENDED für CII mit den technischen Regeln
ZUGFeRD 2.5.2 / Factur-X 1.09.2 (2026-08-04, wirksam ab 2026-09-01).
Jedes Profil verwendet sein eigenes D22B-XSD und originales Schematron-XSLT
samt Codelisten. Der allgemeine CII-Fallback wird in der erzeugten Konfiguration
ersetzt, damit die gemeinsame EN-16931-Kennung nicht zwei Szenarien trifft.
XRechnung behält seine spezifischen Szenarien und seine beiden Schematron-Stufen.

Factur-X verlangt XML, XSD und einen vollständigen Profilregel-Schritt.
Nichtfatale Schematron-Warnungen bleiben mit ihrem Schweregrad erhalten; die
eigene Berichtsschicht lässt sie zu. Fehlender SVRL-Output und technische Fehler
bleiben ablehnend. Die eigentlichen Profilregeln werden nicht verändert.
MINIMUM, BASIC WL und BASIC bestätigen keine vollständige EN-16931-Konformität.
Die gemeinsamen Profil-URNs enthalten keine eindeutige Releaseversion. Ein
Ergebnis bestätigt daher den genannten aktuellen Regelstand, keine historische
Dokumentversion. Nicht unterstützte ältere Aliase werden nicht geraten.
Die reine CII-Kennung `urn:cen.eu:en16931:2017` wird gegen das aktuelle Factur-X-
EN16931-Profil geprüft; dies identifiziert den Ersteller oder Markenstandard
nicht eindeutig.

Vor und nach dem KoSIT-Lauf werden JAR, vollständige Regeldateien und Runtime
gegen das vertrauenswürdig gepinnte Inventar geprüft. Ein fehlender oder
veränderter Regelstand liefert keinen Erfolg. Die Lizenz-/Quellenprüfung aus
[EIV1](validation-licenses.md) bleibt zusätzlich für die Auslieferung erforderlich.
JVM-Optionen aus `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS` und
`CLASSPATH` werden nicht übernommen. Es gibt keinen Rückgriff auf System-Java
oder einen Online-Dienst.

Der Prozess hat höchstens 512 MiB JVM-Heap und standardmäßig 60 Sekunden
Laufzeit. stdout und stderr sind jeweils auf 4 MiB begrenzt; Überschreitung
beendet den Prozess. Der XML-Bericht ist auf 16 MiB begrenzt. Abbruch und
Zeitüberschreitung beenden die gesamte Prozessgruppe; private Ein- und
Ausgabedateien werden danach entfernt.
Die CLI übersetzt auch SIGINT/SIGTERM in diesen geregelten Abbruch, damit
der private Java-Prozess nach einem Terminal-Abbruch nicht zurückbleibt.

## Gemeinsame Ausgabe

```sh
.build/debug/tagx validate-xrechnung rechnung.xml \
  --bundle .build/xrechnung-validator-licensed-arm64 --format common --json
.build/debug/tagx validate-xrechnung rechnung.pdf \
  --bundle .build/xrechnung-validator-licensed-arm64 --format common --json
```

Ab 0.51.0 ist `tagx validate-invoice <datei> --bundle <paket> --json` der
allgemeine XML-/PDF-Befehl für XRechnung und die aktuellen Factur-X-Profile.
Er verwendet dieselbe gemeinsame Ausgabe wie `validate-xrechnung --format common`.
Der Standardaufruf `validate-xrechnung` bleibt auf die bisherige XRechnung-
Ausgabe begrenzt und bestätigt Factur-X nicht als XRechnung.

`--format legacy` ist der Standard und erhält die bisherige XML-JSON-Struktur
sowie deren Exit-Codes. PDF-Eingaben benötigen die gemeinsame Ausgabe. Das
gemeinsame Ergebnis trägt `schemaVersion: 1`; Original-XML und PDF-Bytes werden
nicht in JSON eingebettet.

| Status | Exit | Bedeutung |
|---|---:|---|
| `passed` | 0 | Alle erforderlichen XML-/XSD-/Schematron-Schritte bestätigt; Informationen können vorhanden sein. |
| `passedWithWarnings` | 0 | Dieselben Schritte bestanden, Warnungen vorhanden. |
| `failed` | 3 | Syntax oder technische Rechnungsregeln fehlgeschlagen. |
| `unsupported` | 4 | Kein freigegebenes Profil oder kein Rechnungsanhang. |
| `partial` | 5 | Prüfung unvollständig; insbesondere erfolgreich geprüftes XML in einem noch ungeprüften PDF-Container. |
| `stale` | 6 | Quelldatei verändert; Ergebnis nicht auf den aktuellen Stand anwendbar. |
| `timedOut` | 124 | Prozessfrist überschritten. |
| `cancelled` | 130 | Auftrag abgebrochen. |
| `technicalError` | 1 | Eingabegrenze, defektes Prüfpaket, Prozess- oder Berichtsfehler. |

Bei mehreren Dateien gilt die Reihenfolge technischer Fehler, Zeitüberschreitung,
Abbruch, veraltete Quelle, Rechnungsfehler, nicht unterstützt, Teilprüfung.
Aufruffehler behalten ArgumentParsers Exit 64. `xmlStatus` nennt bei ausgeführter
Prüfung das gesonderte XML-Ergebnis. Bei PDF bleiben `pdfa` und `pdf-embedding`
ausdrücklich `notChecked`; sichtbarer PDF-Inhalt und XML werden nicht verglichen.
Meldungen haben typisierte Schweregrade, Regelcodes und Fundstellen. Der
Gewährleistungshinweis aus dem Prototyp steht auch in diesem Ergebnis.

## Verwendung in der App

Eine `InvoiceValidationSession` gehört genau einer Rechnungsansicht. Sie führt
die synchrone Prüfung außerhalb des Main Actors aus und liefert `idle`,
`running` oder `finished`. Die Ergebniszustände stehen im fertigen Ergebnis.

Für dieselbe Quelle in Anzeige und Prüfung zunächst `InvoiceValidationInput`
im Hintergrund erfassen, `input.payload.document()` anzeigen und dann
`session.validate(input:bundle:)` verwenden. `validate(url:bundle:)` liest selbst
einen neuen Stand. Bei Auswahlwechsel, Neuladen oder Schließen `invalidate()`
aufrufen; ein überholter Auftrag liefert `nil` und darf nichts mehr publizieren.
`cancel()` und Swift-Task-Abbruch liefern für den aktuellen Auftrag `cancelled`.
Auch ein unmittelbar vor dem Abbruch berechnetes positives Ergebnis wird bei
der Auslieferung verworfen. Die UI pflegt ihre sichtbaren Zustände auf dem Main
Actor und übernimmt ein Ergebnis nur für die weiterhin ausgewählte Quelle.

## Nachweise

```sh
swift test
python3 scripts/test-invoice-validation.py \
  --bundle .build/xrechnung-validator-licensed-arm64
python3 scripts/test-xrechnung-prototype.py \
  --bundle .build/xrechnung-validator-licensed-arm64
```

Der erste Python-Lauf lädt ausschließlich gepinnte öffentliche KoSIT-Beispiele
für den Test und entfernt sie danach. Er aktiviert die sonst übersprungenen
Tests `InvoiceValidationRuntimeTests`: CII/UBL und PDF-Anhang, Paketbeschädigung,
Zeitüberschreitung, Abbruch, CLI-Kompatibilität, Status-/Exit-Codes und isolierte
JVM-Umgebung. Normale Tests benötigen weder Java noch Netzwerk. Die endgültige
App, Intel und ältere macOS-Versionen brauchen ihre eigenen Abnahmen.
Ein zusätzlicher SIGINT-Lauf beobachtet zuerst das echte Java-Kind und prüft
anschließend `cancelled`, Exit 130 und dessen vollständiges Prozessende.

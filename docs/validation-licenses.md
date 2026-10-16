# Lizenzen der E-Rechnungsvalidierung

Stand: 2026-10-16. Diese Bestandsprüfung betrifft den gepinnten KoSIT-/Temurin-
Paketstand, nicht beliebige zukünftige Versionen. Der eigene Swift-/Python-Code
bleibt unter [MIT](../LICENSE). Fremde Komponenten behalten ihre Lizenzen und
werden als getrennte Programme, Bibliotheken bzw. Regeldateien verpackt.
Dies ist eine dokumentierte technische Umsetzung der Lizenzbedingungen, keine
Zusicherung einer abschließend juristisch geprüften Haftungs- oder Lizenzlage.

## Tatsächlich gebündelter Java-Code

Alle 4.954 Java-Klassen des verpackten JARs wurden anhand ihrer Namen und
SHA-256-Hashes den unveränderten Klassen der folgenden Original-Artefakte
zugeordnet. Keine unbekannte oder veränderte Klasse wurde gefunden.
XML Resolver kommt zusätzlich als Daten-Artefakt ohne eigene Klassen hinzu.

| Komponente | Version | Lizenz |
|---|---|---|
| KoSIT Validator | 1.6.3 | Apache-2.0 |
| Saxon-HE | 12.9 | MPL-2.0 |
| XML Resolver, einschließlich Daten-Artefakt | 5.3.3 | Apache-2.0; originale W3C-Hinweise für enthaltene Ressourcen |
| picocli | 4.7.7 | Apache-2.0 |
| Jansi, ohne native Konsolenbibliotheken | 2.4.3 | Apache-2.0 |
| SLF4J API / Simple | 2.0.18 | MIT |
| Apache Commons Lang | 3.20.0 | Apache-2.0 |
| Apache Commons IO | 2.22.0 | Apache-2.0 |
| JAXB Runtime / Core / TXW2 | 4.0.8 | EDL-1.0, SPDX BSD-3-Clause |
| Istack Commons Runtime | 4.1.2 | EDL-1.0, SPDX BSD-3-Clause |
| Angus Activation | 2.0.3 | EDL-1.0, SPDX BSD-3-Clause |
| Jakarta XML Binding API | 4.0.5 | EDL-1.0, SPDX BSD-3-Clause |
| Jakarta Activation API | 2.1.4 | EDL-1.0, SPDX BSD-3-Clause |

Das sind 17 Maven-Artefakte einschließlich des XML-Resolver-Daten-Artefakts.
Versionen, originale Download-Hashes, Lizenzbelege und Notice-Hashes stehen in
[components.lock.json](../licenses/validation/components.lock.json). Manche
Maven-POMs erben ihre Lizenz aus einem Eltern-POM; dessen konkrete URL ist
ebenfalls festgehalten. Saxons MPL-Quellen behalten auch den Hinweis auf die
Unvereinbarkeit mit Secondary Licenses; sie werden nicht unter MIT umdeklariert.

Die ungenutzten Ressourcen der KoSIT-Daemon-Weboberfläche unter `ui/` werden
nicht ausgeliefert. Das vermeidet die Mitlieferung von Frontend-Abhängigkeiten,
die unsere native App nicht verwendet. Die native Jansi-Konsole wird wie im
Prototyp entfernt. Alle übrigen ZIP-Einträge bleiben inhaltlich bytegleich;
die ursprünglichen KoSIT-Quellen und Änderungsangaben bleiben im Quellenpaket.

## Laufzeit und Regeln

| Bestandteil | Bedingungen und Umsetzung |
|---|---|
| Temurin/OpenJDK JRE 21.0.12.1+1 | GPLv2 mit Classpath Exception; zusätzliche Modul-Lizenzen, Assembly Exception und sämtliche Original-Hinweise unter `runtime/Contents/Home/legal/` erhalten. Passendes OpenJDK-Quellarchiv einschließlich Build-Dateien wird mit bereitgestellt. |
| XRechnung-Konfiguration 2026-08-31 | Apache-2.0; vollständige ursprüngliche LICENSE-/NOTICE-Dateien einschließlich CEN-/DIN-Hinweisen mitliefern. |
| EN-16931-Regeln 1.3.16 | EUPL-1.2; vollständiger Lizenztext und ursprüngliche Schematron-Quellen zum verwendeten Regelstand mitliefern. Keine Umdeklaration zu MIT. |
| XRechnung-Schematron 2.6.0 | Ursprüngliches Paket samt Apache-Lizenz und Regelquellen mitliefern. |
| SchXslt 1.10.1 | MIT; Original-Lizenz mit David-Maus-Copyright und Quellen der erzeugten Templates mitliefern. |
| UBL-2.1-Schemata | Originale OASIS-Copyright-/Permission-Hinweise in den unveränderten XSD-Dateien erhalten. Die Schemata liegen bereits als Quelltext vor. |
| ZUGFeRD 2.5.2 / Factur-X 1.09.2 | Apache-2.0 für technische XSD-/Schematron-/Codelisten-Dateien; 40 unveränderte Originaldateien aus einem fest gepinnten öffentlichen technischen Spiegel. Eigene begrenzte KoSIT-Szenarien und Berichtsschicht unter MIT. FeRD-Nutzungs-/CEN-/DIN-Hinweis im Bundle und zugänglich in der App. Keine Norm-PDFs, Tabellen oder Logos. |
| CII-D16B-Schemata | Originale UN/CEFACT-Copyright-/Permission-Hinweise in den unveränderten XSD-Dateien erhalten. Keine eigenmächtigen Änderungen dieser Schemata. |

Die vollständigen gemeinsamen Lizenztexte liegen unter
[licenses/validation](../licenses/validation); komponentenspezifische Texte und
Copyrights werden zusätzlich aus den jeweiligen originalen JARs übernommen.
Ein allgemeiner Apache- oder MIT-Hinweis ersetzt diese Original-Notices nicht.

## Erzeugung und Auslieferungsprüfung

```sh
python3 scripts/prepare-xrechnung-validator.py
python3 scripts/validation_compliance.py .build/xrechnung-validator-arm64 \
  --sources .build/xrechnung-validator-arm64-sources
```

Das Vorbereitungsskript erzeugt ein Binärpaket und ein separates, dazu passendes
Quellenverzeichnis. Downloads werden vor Verwendung auf die gepinnten Hashes
geprüft; ein vorhandenes Ziel wird nicht überschrieben. Das Quellenverzeichnis
enthält 64 Original-Quell-/Datenartefakte einschließlich OpenJDK und Regelquellen,
deren Lizenzen und Herkunft im Manifest stehen. Binär- und Quellenmanifest sind
über die Hashes des Inventars und des Quellenmanifests miteinander verbunden.

Die Prüfung vergleicht den tatsächlich verpackten JAR, den vollständigen
Runtime-Dateibaum und den Regel-Dateibaum mit dem geprüften Stand. Sie prüft
außerdem jede erforderliche Lizenz-/Notice-Datei und jedes Quellartefakt.
Fehlende, beschädigte oder nicht freigegebene Bestandteile blockieren die
Probe-Verpackung bereits vor Signierung oder Notarisierung. Die Prüfung
benötigt keine Netzwerkverbindung. Original-Downloads liegen nur im lokalen
Cache; sie sind nicht Bestandteil des Git-Repositories.

Die Probe-Verpackung erzeugt neben dem App-ZIP ein
`XRechnungValidator-sources.zip`. Bei öffentlicher Binärdistribution muss das
zugehörige Quellenpaket neben genau diesem Binärstand bereitstehen und für die
Empfänger zugänglich bleiben. Ein bloßer Link auf fremde Upstream-Server ist
nicht der hier gewählte Weg zur Erfüllung der Quellcodepflichten. Die Integration
dieser verbindlichen Prüfung ist seit 0.50.0 für XRechnung und seit 0.51.0 zusätzlich für Factur-X im App-Build
umgesetzt. Die abschließende Distribution-/Updateabnahme sämtlicher Profile
bleibt ein eigener Meilenstein. Es wurde noch kein öffentliches Release veröffentlicht.

Negative und positive Prüfungen:

```sh
python3 Tests/validation-compliance-tests.py \
  --bundle .build/xrechnung-validator-arm64 \
  --sources .build/xrechnung-validator-arm64-sources
```

## Grundlage weiterer Komponenten

- **ZUGFeRD 2.5.2 / Factur-X 1.09.2:** konkret aufgenommen und über jede
  Datei gepinnt. FeRD erlaubt die technischen Artefakte unter Apache-2.0.
  Der öffentliche Spiegel ist `LandrixSoftware/validator-configuration-zugferd`
  bei Commit `8399f5459df34b2af9cae0d613870649b3f17a58`. Verwendet werden
  ausschließlich die originalen Unterverzeichnisse der fünf Profile,
  einschließlich `.sch`, `_codedb.xml` und originalem `_XSLT_*`; die separat
  modifizierten XSLTs, der allgemeine Wrapper-Fallback und Spezifikationstabellen
  des Spiegels werden nicht übernommen. Jede Quelldatei liegt mit im Sources-Paket.
  Kontaktformulare wurden nicht verwendet und keine Kontaktdaten übermittelt.
  [FeRD-Nutzungsrechte](https://www.ferd-net.de/ueber-uns/ressourcen-1/veroeffentlichungen/haftungsausschluss-und-nutzungsrechte),
  [aktuelles Release](https://www.ferd-net.de/publikationen-produkte/publikationen/detailseite/zugferd-252-deutsch).
- **Peppol BIS Billing 3.0:** Die KoSIT-Konfiguration hat Apache-2.0 und eigene
  CEN-/DIN-Hinweise. Das bedeutet nicht, dass die OpenPeppol-Spezifikation frei
  umverpackt werden darf. Die aktuelle BIS-Dokumentation untersagt dies ohne
  Zustimmung; sie wird nicht gebündelt. Für das konkret gewählte technische
  Regelpaket müssen Herkunft und Nutzungsbedingungen vor seiner Aufnahme ins
  Inventar gesondert belegt werden; die Wrapper-Lizenz allein genügt nicht.
  Noch nicht als gebündelte Komponente freigegeben.
  [KoSIT-Konfiguration](https://github.com/itplr-kosit/validator-configuration-bis),
  [OpenPeppol-Copyright](https://docs.peppol.eu/poacc/billing/3.0/bis/).
- **PDF/A-Validator:** veraPDF ist ein geeigneter Kandidat mit Wahl zwischen
  GPLv3+ und MPLv2+. Vorgesehen ist der MPL-Zweig samt passenden Sources; vor
  Bündelung des konkreten CLI-/Bibliothekspakets werden dessen transitive
  Abhängigkeiten und Original-Notices genauso geprüft. Noch keine veraPDF-
  Binärdatei im Paket. [veraPDF-Lizenzangaben](https://github.com/veraPDF/veraPDF-library).

Damit sind die vorhandenen Paketbestandteile konkret erfasst. Neue Profile oder
PDF-Validatoren werden nicht allein wegen einer passenden Projektüberschrift
als lizenzgeklärt behandelt. Der Gewährleistungshinweis ändert die Rechte der
Empfänger an fremdem Code nicht und ersetzt keine dieser Lizenzpflichten.

Primärquellen zur gewählten Umsetzung:
[KoSIT-NOTICE](https://github.com/itplr-kosit/validator/blob/v1.6.3/NOTICE),
[MPL-FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/),
[Adoptium-Lizenzen](https://adoptium.net/about),
[EUPL-1.2](https://interoperable-europe.ec.europa.eu/collection/eupl/eupl-text-eupl-12),
[EN-16931-Lizenz](https://github.com/ConnectingEurope/eInvoicing-EN16931/blob/validation-1.3.16/LICENSE.txt).

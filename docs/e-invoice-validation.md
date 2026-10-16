# XRechnung-Validierung: KoSIT-Prototyp

Stand: 2026-10-16. Die kompatible Prototyp-Ausgabe prüft eigenständige
XRechnung-XML-Dateien über `tagx validate-xrechnung`. Seit 0.49.0 ergänzt
`--format common` den [gemeinsamen Validierungsdienst](e-invoice-validation-core.md)
mit unveränderten PDF-Anhängen, Ergebnisbindung und weiteren Fehlerzuständen.
Die Rechnungsansicht der App behält ihre bisherige Grundvalidierung.
PDF/A-Prüfung und Integration in die Oberfläche folgen getrennt.

## Verwendung

Einmalig auf dem Entwicklungsrechner das Prüfpaket vorbereiten:

```sh
swift build
python3 scripts/prepare-xrechnung-validator.py
```

Das Skript lädt fest gepinnte Artefakte von KoSIT und Eclipse Adoptium,
prüft ihre SHA-256-Summen und legt sie unter `.build/xrechnung-validator-arm64`
bzw. `.build/xrechnung-validator-x86_64` ab. Ein vorhandenes Ziel wird nicht
überschrieben. Die Java-Laufzeit wird vollständig einschließlich ihrer
Lizenzdateien übernommen. Keine Installation nach `/Library/Java` oder
Änderung der Shell-Konfiguration ist erforderlich.
Zusätzlich entsteht unter `<paketpfad>-sources` das passende Quellenpaket.
Lizenztexte, Original-Notices und Quellen werden anhand des geprüften
[Komponenteninventars](validation-licenses.md) zusammengestellt. Alte
Prototyp-Pakete werden nicht nachträglich still überschrieben; für eine neue
Vorbereitung gegebenenfalls einen neuen Pfad mit `--output` wählen.

```sh
.build/debug/tagx validate-xrechnung rechnung.xml \
  --bundle .build/xrechnung-validator-arm64 --json
```

Das Prüfpaket wird ausdrücklich angegeben. Es gibt keinen Rückgriff auf
System-Java, `JAVA_HOME` oder einen Online-Validator. Der Vorgang liest die
Originaldatei einmal in einen privaten temporären Schnappschuss. Prüfbericht
und Schnappschuss werden nach dem Lauf entfernt; neben der Rechnung entsteht
keine Datei. Grenze: 16 MiB XML, 512 MiB JVM-Heap, 60 Sekunden Prozesslaufzeit.
DOCTYPE wird konservativ abgelehnt, auch in UTF-16/32 und in Kommentaren.

## Ergebnis

| Status | Exit-Code | Bedeutung |
|---|---:|---|
| `passed` | 0 | XML, XSD, EN-16931-Schematron und XRechnung-Schematron bestanden; KoSIT empfiehlt die Annahme. Hinweise können trotzdem vorhanden sein. |
| `failed` | 3 | Mindestens eine technische Prüfung ist fehlgeschlagen. |
| `unsupported` | 4 | Kein unterstütztes XRechnung-Szenario; auch eine erfolgreiche reine EN-16931-Prüfung bestätigt keine XRechnung. |
| Fehler | 1 | Prüfpaket, Prozess oder Bericht nicht verwendbar; keine Aussage über die Gültigkeit der Rechnung. |

Diese Tabelle beschreibt das kompatible Standardformat. Die gemeinsame
Ausgabe und ihre zusätzlichen Status-/Exit-Codes sind
[gesondert dokumentiert](e-invoice-validation-core.md).

Fehlende oder widersprüchliche Prüfschritte gelten niemals als Erfolg.
Berichte enthalten Engine, Regelpaket-Release, erkanntes Szenario,
Prüfschritte sowie Meldungen mit Regelcode, Schweregrad und XPath-Fundstelle.
Bei mehreren Dateien hat Exit 3 Vorrang vor Exit 4. Aufruffehler liefern den
üblichen ArgumentParser-Exit 64.

Gepinnter Stand:

- KoSIT Validator 1.6.3.
- XRechnung-Konfiguration 2026-08-31 für XRechnung 3.0.2, mit den von KoSIT
  zusammengestellten EN-16931- und XRechnung-Regeln. Einzelne neuere
  Regeldateien werden nicht in dieses Paket hineingemischt.
- Eclipse Temurin JRE 21.0.12.1+1 für macOS arm64 bzw. x86_64.
- Download-URLs, Prüfsummen, Architektur und Java-Quellcode-URL stehen im
  erzeugten `manifest.json`. Die Binärpakete werden nicht eingecheckt.

Für die macOS-Verpackung entfernt das Vorbereitungsskript ausschließlich
die 15 nativen Jansi-Konsolenbibliotheken und die ungenutzte Daemon-Weboberfläche
aus dem JAR. Die nativen Bibliotheken sind teils
unsigniert und enthalten auch 32-Bit-Code, den Apples Notarisierung ablehnt.
Java-Klassen, Regeln und Lizenzressourcen bleiben bytegleich erhalten;
`jansi.mode=strip` deaktiviert die Konsolenformatierung. Das Manifest nennt
die ausgelassenen Einträge und den Hash des verpackten JARs zusätzlich zum
Hash des unveränderten Downloads.

## Gewährleistung und Grenzen

Die Software steht unter der [MIT-Lizenz](../LICENSE), die bereits einen
Gewährleistungs- und Haftungsausschluss enthält. Jede Text- und JSON-Ausgabe
des Prototyps enthält zusätzlich diesen Hinweis:

> Technische Prüfung ausschließlich gegen das genannte Regelpaket. Keine
> Zusicherung rechtlicher oder steuerlicher Gültigkeit und keine Garantie
> der Annahme durch einen Empfänger. Die Software und ihre Prüfergebnisse
> werden ohne Gewähr für Richtigkeit, Vollständigkeit oder Eignung für einen
> bestimmten Zweck bereitgestellt. Gewährleistung und Haftung sind nach
> Maßgabe der MIT-Lizenz im gesetzlich zulässigen Umfang ausgeschlossen;
> zwingende gesetzliche Haftung bleibt unberührt.

Ein bestandenes Ergebnis belegt nur die ausgeführten technischen Regeln.
Es bestätigt weder die tatsächliche Lieferung oder Leistung noch die
steuerliche Behandlung oder die Annahme durch einen konkreten Empfänger.
Open Source und unentgeltliche Bereitstellung begründen keinen pauschalen
Ausschluss jeder Haftung. Insbesondere lässt sich Haftung wegen Vorsatzes
nicht im Voraus ausschließen ([§ 276 Abs. 3 BGB](https://www.gesetze-im-internet.de/bgb/__276.html));
für vorformulierte Bedingungen können weitere Grenzen gelten
([§ 309 Nr. 7 BGB](https://www.gesetze-im-internet.de/bgb/__309.html)).
Der Hinweis ist keine abschließende juristische Prüfung seiner Wirksamkeit.

## Reproduzierbare Prüfung

```sh
swift test --filter 'XRechnungValidatorTests|InvoiceCommandTests|EInvoiceTests'
python3 scripts/test-xrechnung-prototype.py \
  --bundle .build/xrechnung-validator-arm64
```

Das Integrationsskript lädt zwei öffentliche KoSIT-Beispielrechnungen von
einem gepinnten Commit, prüft ihre SHA-256-Summen und verändert nur temporäre
Kopien. Die Validator-Läufe verwenden einen PATH ohne Homebrew und ein
absichtlich ungültiges `JAVA_HOME`. Der kleine Ergebnisbeleg liegt unter
`.build/kosit-prototype-summary.json`; Rechnungsinhalte werden darin nicht
gespeichert.

## Auslieferung

Das private Prüfpaket kann unverändert in einer App liegen; der Aufrufer
adressiert dessen Java-Executable direkt. Der lokale Paketversuch und seine
Messwerte sind in [xrechnung-kosit-prototyp.md](../knowledge/xrechnung-kosit-prototyp.md)
festgehalten. Der normale App-Build bündelt den Prototyp noch nicht.

Die signierte headless App-Hülle lässt sich separat nachbauen. Sie zeigt
keine Oberfläche und wird nicht installiert. Für `--notarize` sind ein
Developer-ID-Zertifikat und das vorhandene Notary-Profil erforderlich:

```sh
scripts/probe-xrechnung-distribution.sh .build/xrechnung-validator-arm64 \
  .build/kosit-distribution-probe --notarize
python3 scripts/test-xrechnung-prototype.py \
  --bundle .build/xrechnung-validator-arm64 \
  --probe-app .build/kosit-distribution-probe/XRechnungRuntimeProbe.app
```

Vor einer öffentlichen Auslieferung sind zusätzlich nötig:

- App-Oberfläche mit klaren Prüfzuständen, Abbruch und dem Hinweis am Ergebnis.
- Einbindung des Pakets in den regulären Build- und Updateprozess;
  Signaturprüfung und Tests der endgültigen App auf unterstützten Systemen.
- Das erzeugte, zum Binärstand passende Quellenpaket gemeinsam bereitstellen
  und die vorhandene Lizenz-/Quellenprüfung in den regulären Release aufnehmen.
  Die Paketbasis und ihre Original-Notices sind inzwischen umgesetzt;
  neue Komponenten werden vor Bündelung gesondert geprüft. Die MIT-Lizenz
  des eigenen Codes ersetzt keine fremden Lizenzbedingungen.

Die gesamte weitere Produktintegration steht in den
[Validierungsmeilensteinen](e-invoice-validation-roadmap.md).

Quellen: [KoSIT-Validator](https://github.com/itplr-kosit/validator),
[XRechnung-Konfiguration](https://github.com/itplr-kosit/validator-configuration-xrechnung/releases/tag/v2026-08-31),
[Temurin-Archive](https://adoptium.net/installation/archives),
[OpenJDK-Lizenzen](https://adoptium.net/about),
[EN-16931-Artefakte](https://github.com/ConnectingEurope/eInvoicing-EN16931).

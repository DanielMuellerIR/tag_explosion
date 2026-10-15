# XRechnung mit KoSIT und privater Java-Laufzeit

Stand: 2026-10-16. Trigger: Arbeit an `XRechnungValidator`, am KoSIT-Prüfpaket
oder seiner macOS-Verpackung. Bedienung und fachliche Grenzen:
[E-Rechnungsvalidierung](../docs/e-invoice-validation.md).

## Ergebnis des Prototyps

Eine private Temurin-JRE kann KoSIT aus einem verschobenen App-Bundle
ausführen. System-Java, Homebrew, `JAVA_HOME` und ein Netzwerkdienst werden
für die Prüfung nicht benötigt. Der Versuch wurde auf Apple Silicon mit
macOS 26.7.1 durchgeführt. Die Runtime nennt macOS 11.0 als Mindestversion;
dies ersetzt keinen echten Lauf der endgültigen App auf macOS 14.
Intel ist im Vorbereitungsskript gepinnt, aber nicht im echten Lauf geprüft.

Gepinnt: KoSIT 1.6.3, XRechnung-Konfiguration 2026-08-31 für 3.0.2 und
Temurin JRE 21.0.12.1+1. Das vorbereitete arm64-Paket belegt rund 166,7 MiB
auf dem Dateisystem; die signierte App-Hülle als ZIP rund 56,5 MiB.
Die vollständige Runtime macht den größten Anteil aus. Eine Verkleinerung
mit `jlink` wurde nicht untersucht. Die beiden positiven CLI-Einzelläufe
brauchten im Abschlusstest rund 2,0 bzw. 2,3 Sekunden einschließlich JVM-Start
und Regelinitialisierung; das ist keine allgemeine Laufzeitgarantie.

## Notarisierungsfalle: native Jansi-Bibliotheken im JAR

Der unveränderte KoSIT-Standalone-JAR enthält native Konsolenbibliotheken
von Jansi 2.4.3. Apple untersucht auch eingebettete JARs und lehnt dessen
unsignierte bzw. nur ad hoc signierte Mac-Bibliotheken ab, einschließlich
32-Bit-x86. Die gültige Temurin-Herstellersignatur allein reicht deshalb
nicht für die gesamte App-Hülle.

Das Vorbereitungsskript entfernt ausschließlich die 15 nativen
Jansi-Ressourcen für sämtliche Plattformen. Alle übrigen ZIP-Einträge
bleiben inhaltlich bytegleich. Die Prüfregeln und Java-Klassen werden nicht
geändert. Der Aufruf verwendet `-Djansi.mode=strip`; Konsolenformatierung
ist für die maschinenlesbare Auswertung entbehrlich.

Apple hat die so verpackte, mit Developer ID signierte App-Hülle zur
Notarisierung angenommen; Stapling, Ticketprüfung und Gatekeeper bestehen.
Die Runtime behält ihre originale Signatur und
JVM-Entitlements, da sie als eigener Prozess läuft. Kein pauschales
Nachsignieren mit `--deep`; `--deep` dient ausschließlich zur Verifikation.
Reproduzierbarer Bau: `scripts/probe-xrechnung-distribution.sh`.

## Berichtsauswertung

- Bei regulärer Zurückweisung liefert KoSIT 1.6.3 Exit 1; ohne passendes
  Szenario wurde Exit 2 beobachtet. Beide sind von einem Werkzeugfehler
  ohne brauchbaren Bericht zu unterscheiden. Ein Nichtnull-Exit darf auch
  mit vermeintlich positivem Bericht niemals als Erfolg erscheinen.
- `varl:report` enthält die eigentlichen `validationStepResult` und
  `assessment/accept` bzw. `assessment/reject`. Die Texttabelle und die
  eingebettete HTML-Ansicht sind keine verlässliche Auswertungsgrundlage.
- Erfolgsbedingung: XRechnung-Szenario, `val-xml`, `val-xsd`, `val-sch.1`
  und `val-sch.2` erfolgreich, Gesamtbericht gültig und Annahme empfohlen.
  Fehlende, doppelte oder widersprüchliche Schritte bestätigen nichts.
- KoSIT kann Hinweise der Stufe `information` ausgeben und trotzdem die
  Annahme empfehlen. Das gilt auch für die verwendeten positiven Beispiele.
- Das Paket enthält zusätzlich reine EN-16931-Szenarien. Deren Erfolg
  darf nicht als bestandene XRechnung-Prüfung angezeigt werden.
- Regelpakete als zusammengehörigen Stand übernehmen; nicht beliebig die
  jüngsten EN-16931-Dateien in eine ältere KoSIT-Konfiguration mischen.

## Nachweise und offene Arbeit

Vierzehn echte CLI-Fälle bestehen mit dem verpackten JAR: positive UBL/CII,
fehlende Käuferreferenz in beiden Syntaxen, XSD-Fehler, Summenfehler,
unbekanntes Profil, reines EN 16931, kaputtes XML, externe Entity in UTF-8
und UTF-16, die Größenbegrenzung sowie fehlende Laufzeit und defektes Werkzeug.
Die Originaldateien bleiben bytegleich.
Das Testskript lädt öffentliche Beispiele von einem festen Commit und prüft
deren Hashes; es speichert keine Rechnungen im Repository.

Ein zusätzlicher Lauf aus einem verschobenen App-Pfad mit Leerzeichen
bestätigte beide positiven Rechnungen bei per macOS-Prozess-Sandbox
verweigertem Netz-, System-Java- und Homebrew-Zugriff. Diese Sandbox ist
ein Testmittel, keine Behauptung über die Sandbox der normalen App.

`swift test` im Root-Paket und in `App/` bestehen. Zwei optionale
App-Mess-/Renderprüfungen wurden vom vorhandenen Testlauf übersprungen.
Die ergänzte Konsistenzprüfung der Berichte wurde danach gezielt erneut
ausgeführt. Es gibt keine Änderungen an der GUI in diesem Schritt.

Offen für die Produktintegration: Oberfläche, endgültiger App-Build und
Updates, reale Tests auf älteren unterstützten Systemen/Intel, vollständige
Lizenz- und Quellcodezusammenstellung der Fremdpakete. Ein technisches
Prüfergebnis oder der Gewährleistungshinweis ist keine Zusicherung
rechtlicher bzw. steuerlicher Gültigkeit.

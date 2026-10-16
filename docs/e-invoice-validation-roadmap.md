# E-Rechnungsvalidierung: Produktmeilensteine

Stand: 2026-10-16. Grundlage ist der KoSIT-Prototyp aus 0.48.0.
Die folgende Erweiterung betrifft die native App und ihre CLI. Jeder Meilenstein
enthält Detailausarbeitung, Implementierung, passende Tests und Dokumentation.

| Meilenstein | Ergebnis | Status |
|---|---|---|
| EIV1 — Lizenzen und Paketbasis | Inventar der tatsächlichen Bibliotheken, Lizenz-/Notice-Sammlung, passende Quellen und verpflichtende Prüfung der Probe-Verpackung | umgesetzt; Produkt-Releaseintegration folgt in EIV7 |
| EIV2 — Gemeinsamer Validierungskern | Unveränderte XML-/PDF-Quelldaten, versionsgebundene Profile, einheitliche Ergebnisse, Abbruch/Timeout und CLI | umgesetzt in 0.49.0 |
| EIV3 — XRechnung in der App | Prüfaktion und verständliche Zustände, Meldungsstufen/Fundstellen, Bericht und Gewährleistungshinweis für XML und PDF-Tab | implementiert in 0.50.0; native Sichtabnahme ausstehend |
| EIV4 — ZUGFeRD/Factur-X | MINIMUM, BASIC WL, BASIC, EN 16931 und EXTENDED mit zusammengehörigen offiziellen XSD-/Schematron-Ständen | implementiert in 0.51.0; native Sichtabnahme ausstehend |
| EIV5 — Peppol Billing | UBL Invoice/CreditNote mit offizieller Regelkombination; technische Artefakt-Rechte vorher belegen | offen |
| EIV6 — Hybride PDF-Rechnung | PDF/A, XML-Einbettung und XMP-/AF-Metadaten mit eigenem Containerergebnis | offen |
| EIV7 — Distribution und Updates | Laufzeit/Regeln im regulären App-Build, Quellenpaket, Lizenzprüfung, signiertes Bundle/DMG und Updateweg | offen |
| EIV8 — Gesamtabnahme | Reale GUI-/Offline-/Systemtests, korrigierte Restfehler, aktuelle Supportmatrix und Produktdokumentation | offen |

Die Ausführung folgt dieser Reihenfolge. EIV3 benötigt EIV2; EIV4/EIV5 nutzen
denselben Kern und dieselbe Ergebnisansicht. EIV6 ergänzt die Profile aus EIV4.
Vor dem regulären Release müssen sämtliche verwendeten Komponenten im
[Lizenzinventar](validation-licenses.md) freigegeben und überprüfbar sein.

## Zielumfang

- XRechnung in CII und UBL sowie Gutschriften, soweit vom gewählten offiziellen
  Paket unterstützt. Das Ergebnis nennt immer Engine, Profil und Regelstand.
- Aktuelle ZUGFeRD-/Factur-X-Profile: als recherchierte Ausgangsbasis
  ZUGFeRD 2.5.2 / Factur-X 1.09.2; bei Umsetzung den aktuellen Herstellerstand
  erneut prüfen. MINIMUM/BASIC WL dürfen nicht als vollständige EN-16931-
  Konformität ausgegeben werden.
- Peppol BIS Billing mit den dazugehörigen Regeln und Codelisten. Dies bestätigt
  keine Netzübertragung, Zustellung oder Annahme durch einen Access Point.
- Bei PDF getrennte Aussagen über Rechnungs-XML, PDF/A und hybride Einbettung.
  Die Übereinstimmung des sichtbaren Inhalts mit dem XML wird damit nicht
  automatisch geprüft; eine OCR-/Semantikprüfung ist kein Teil dieses Vorhabens.
- Lokal und ohne zusätzliche Nutzerinstallation arbeiten. Es gibt keine
  stillen Rechnungs-Uploads zu einem Online-Validator.

## Ergebnisdarstellung und Abnahme

Die App unterscheidet ungeprüft, laufend, bestanden mit/ohne Hinweise,
fehlgeschlagen, nicht unterstützt, abgebrochen und technischen Fehler.
Ein fehlender Prüfschritt oder ein Werkzeugfehler bestätigt niemals Gültigkeit.
Die vorhandene Grundprüfung bleibt als solche erkennbar; ihr Ergebnis darf
nicht mit vollständiger XSD-/Schematron-Prüfung verwechselt werden.

Meldungen enthalten verständlichen Text, Schweregrad, Regelcode, Feld/Fundstelle
und den tatsächlich verwendeten Regelstand. Die Oberfläche bleibt während der
Prüfung bedienbar; Dateiwechsel oder Änderungen verwerfen veraltete Ergebnisse.
Ein Bericht zum Kopieren/Exportieren enthält denselben Prüfumfang und Hinweis.
Deutsche und englische Beschriftungen folgen dem bestehenden App-Stil.

Der Gewährleistungshinweis steht am Ergebnis und ist vollständig zugänglich.
Es gibt keine rechtliche/steuerliche Gültigkeitszusage und keine garantierte
Empfängerannahme; zwingende gesetzliche Haftung bleibt unberührt.

Für die Abnahme sind positive und gezielt negative XML-/PDF-Beispiele,
Werkzeugfehler, Abbruch und Dateiwechsel sowie echte GUI- und Offline-Läufe
erforderlich. Unterstützte Architekturen und ältere macOS-Versionen werden
durch tatsächliche Läufe belegt. Ein aktueller arm64-Build allein bestätigt
weder Intel noch macOS 14. Normdokumente, Logos und echte Rechnungen werden
nicht automatisch als Testmaterial oder Produktressourcen übernommen.

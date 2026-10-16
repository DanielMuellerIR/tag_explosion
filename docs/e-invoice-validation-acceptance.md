# E-Rechnungsvalidierung: Abnahme und Grenzen

Stand: 2026-10-16, Produktstand 0.53.2. Die Abnahme unterscheidet ausgeführte
Prüfungen, deklarierte Systemanforderungen und offene Arbeit. Das Gesamtvorhaben
ist wegen Peppol-Rechten und verbleibender System-/Updateabnahme noch offen.

| Bereich | Ausgeführter Nachweis |
|---|---|
| XRechnung | KoSIT mit CII, UBL Invoice, UBL CreditNote sowie Extension in CII und UBL; positive und gezielt negative Fälle |
| Factur-X | Alle fünf aktuellen Profile mit eigenen XSD-/Schematron-Regeln; reduzierte Profile und Regelversion ausdrücklich ausgewiesen |
| Hybride PDFs | PDF/A-3a, 3b, 3u und 4f, Legacy-XMP, alle fünf Profile und CII-XRechnung; getrennte XML-/PDF-/Einbettungsergebnisse |
| Containerfehler | XMP, Dateiname, MIME, AF, Namensbaum, PDF/A, doppelte Rechnungen und zusätzliche Formate; XML-Erfolg bleibt getrennt sichtbar |
| Primäre/zusätzliche Syntax | UBL als primäres Referenzdokument abgelehnt; korrekt benannter UBL-Zusatz zugelassen und als selbst ungeprüft gekennzeichnet |
| Abbruch und Dateistand | Auswahlwechsel, externe Änderungen, verspätete Ergebnisse, Timeout; SIGINT nach beobachtetem echten Java-Kind auch in der veraPDF-Phase |
| Bericht und Dateischutz | Vollständiger Hinweis im Textbericht, Quellenprüfsummen, sichere Exporte und Schutz der Rechnung einschließlich Symlink-/Hardlink-Alias |
| Native Oberfläche | DE/EN mit je 17 XR-/Factur-X-Fällen in 0.51.0 sowie je 6 PDF-Fällen in 0.53.1; echte AX-Aktionen und eigene native Fensterbilder |
| Offline und verschobenes Bundle | Elf Fälle aus einem Pfad mit Leerzeichen bei gesperrtem Netzwerk; vier zusätzliche Syntax-/Doppelanhangfälle am installierten 0.53.2-Paket ebenfalls netzgesperrt |
| Lizenzen/Quellen | Beide Inventare, originale Hinweise und passende Sources; 40 Factur-X-Dateien bytegleich zum Herstellerpaket, 15 veraPDF-Profile bytegleich zu den bevorzugten Quellen |
| App/DMG | Notarisiertes App-Bundle/DMG, beide Quellen-ZIPs, vollständige eigene MIT-Lizenz und sechs Auslieferungsprüfungen bestanden |
| Updateweg | Regulärer HTTPS-Feed und angebotene Version geprüft; isolierte Austauschprobe vorbereitet, Installation/Neustart noch offen |

Die Standard-Swift-Läufe melden 65 CLI-, 545 Core- und 162 App-Tests.
Optionale Laufzeitsuiten sind dort deaktiviert; separat aktiviert wurden neun
PDF-Testfunktionen mit echten KoSIT-/veraPDF-Prozessen. Die nativen 46 Fälle
enthalten zwei ausdrücklich synthetische Warnungsdarstellungen als UI-Probe.
Die späteren Korrekturen in 0.53.2 betreffen den Kern; die Ansichtsquellen sind
gegenüber der nativen Abnahme mit 0.53.1 unverändert.

Die Offline-CLI-Prüfungen laden Bibliotheken und Validatoren aus dem App-Bundle.
Die Nutzerauslieferung umfasst App/DMG und beide dazu passenden Quellen-ZIPs.
Es wurde kein neuer öffentlicher Release- oder Appcast-Stand veröffentlicht.

## Tatsächliche Systemmatrix

| Plattform | Nachweis |
|---|---|
| Apple Silicon, macOS 26.7.1 | Core/CLI und echte native App-Läufe ausgeführt |
| macOS 14 | Alle 56 Mach-O-Dateien des Release-Bundles halten die deklarierte Mindestversion; tatsächlicher Systemlauf fehlt |
| Intel | Passende Laufzeit ist gepinnt; tatsächlicher App-Build und Systemlauf fehlen |

## Verbleibende Arbeit und fachliche Grenzen

- Peppol BIS Billing 3.0.21: Für die konkreten technischen OpenPeppol-Regeln
  fehlt der eindeutige Weitergabe-Rechtebeleg. Die Spezifikationsdokumentation
  wird nicht automatisch mit den Technikdateien gleichgesetzt. Kein ungeklärtes
  Peppol-Artefakt wurde ins Produkt aufgenommen.
- Aktuelle Update-Auslieferung einschließlich Menübedienung und Neustart sowie
  echte Intel-/macOS-14-Abnahme bleiben gesondert nachzuweisen.
- Bereits beim Import unlesbare XML-Dateien haben in der App einen Ladefehler
  und noch keinen vollständigen KoSIT-Prüfbericht. Die CLI kann sie direkt prüfen.
- Sichtinhalt/XML-Gleichheit, Echtheit, Signaturen, steuerliche Voraussetzungen
  und Empfängerannahme werden nicht bestätigt. Zusätzliche UBL-Darstellungen
  werden nicht mit eigenen XML-Regeln validiert. [PDF-Prüfumfang](e-invoice-validation-pdf.md).
- Der [Gewährleistungshinweis](e-invoice-validation-app.md#gewährleistung)
  grenzt technische Aussagen ein; zwingende gesetzliche Haftung bleibt unberührt.

Kleine Ergebnis- und Bildbelege werden erhalten. Entbehrliche eigene Testkopien
sind nach Abnahme zur Entfernung innerhalb von 30 Tagen vorgesehen. Zugehörige
Quellenpakete bleiben für weitergegebene Binärstände zugänglich.

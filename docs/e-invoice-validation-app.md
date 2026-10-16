# E-Rechnungen in der App prüfen

Ab Version 0.52.0 steht **E-Rechnung prüfen** sowohl bei eigenständigen
Rechnungs-XMLs als auch im E-Rechnungstab eines PDFs bereit. Die Prüfung läuft
lokal mit den mitgelieferten KoSIT-/veraPDF-Paketen und privatem Java. Nutzer brauchen dafür keine
zusätzliche Installation. Rechnungsdateien werden ausschließlich gelesen.

## Bedienung und Ergebnisse

Die Prüfleiste nennt Prüfumfang und Regelstand. **Abbrechen** beendet einen
laufenden Auftrag, einschließlich seines Java-Prozesses. Beim Dateiwechsel,
Schließen oder Neuladen wird ein überholter Auftrag verworfen. Ein Dateiwächter
verwirft Ergebnisse auch nach externen Änderungen an der ausgewählten Datei.

Die App unterscheidet ungeprüft, laufend, bestanden mit/ohne Warnungen,
fehlgeschlagen, nicht unterstützt, teilweise geprüft, abgebrochen,
Zeitüberschreitung, technischen Fehler und veralteten Dateistand. Informationen
bleiben auch bei bestandener Prüfung sichtbar. Eine Warnung ist kein Fehler;
ein Werkzeugfehler bestätigt keine Rechnungsgültigkeit.

**Prüfbericht …** zeigt Regelpaket, Engine, Zeitpunkt und einzelne Prüfschritte.
Nicht ausgeführte Schritte stehen ausdrücklich als ungeprüft im Bericht.
Meldungen lassen sich nach Fehlern, Warnungen und Informationen filtern. Der
Regelcode und die Original-Fundstelle bleiben erhalten. Eine Feldbezeichnung
wird nur ergänzt, wenn sie sich eindeutig zuordnen lässt. Originale Regeltexte
werden nicht durch eine erfundene Übersetzung ersetzt. Eigene Bedienelemente,
Zustände und Gewährleistungshinweise sind auf Deutsch und Englisch vorhanden.

Berichte lassen sich kopieren oder als Text sichern. Sie enthalten Dateistand,
XML-/Träger-Prüfsummen, Prüfumfang und vollständigen Gewährleistungshinweis.
Vor Kopieren und Sichern wird die Quelle erneut abgeglichen. Rechnung, Symlinks
oder Hardlinks darauf dürfen nicht als Exportziel ersetzt werden. Andere
bestätigte Exportziele laufen über den vorhandenen gesicherten Schreibweg:
geprüfte Kopie, gegebenenfalls Papierkorb-Sicherung, atomarer Austausch.

## XML im PDF

Anzeige und Validierung verwenden bei einer ausdrücklich gestarteten Prüfung
denselben frischen Eingabeschnappschuss. Die XML-Anhangsauswahl folgt weiterhin
XMP-Deklaration und den bevorzugten Dateinamen des Lesers.

Seit 0.52.0 prüft die App zusätzlich PDF/A und die technische hybride Einbettung.
Die Prüfleiste zeigt XML, PDF/A und Einbettung getrennt; der Bericht nennt auch
veraPDF-Version, Trägerprofil und Hybridregelstand. Ein gültiges XML kann in
einem fehlerhaften PDF liegen. Ein Werkzeugfehler erhält das bereits ermittelte
XML-Ergebnis, bestätigt aber keinen vollständigen Gesamterfolg.

Die Übereinstimmung des sichtbaren Inhalts mit dem XML, Echtheit, Signaturen
und steuerliche Voraussetzungen bleiben ungeprüft. Details und bewusst
begrenzte Aussagen: [Hybride PDF-Prüfung](e-invoice-validation-pdf.md).

## Grundprüfung und weitere Profile

Die bisherigen Pflichtfeld-/Summenhinweise bleiben getrennt unter
**Grundprüfung (ohne XSD/Schematron)** zugänglich. Sie sind kein Ersatz für den
vollständigen KoSIT-Lauf. Die eingeklappte Ansicht nennt ihre Meldungsanzahl,
damit sie die Feldliste bei kleinen Fenstern nicht verdrängt.

Aktuell freigegeben sind die in den [Kern-Metadaten](e-invoice-validation-core.md)
genannten XRechnung- und fünf aktuellen ZUGFeRD-/Factur-X-Profile. Die
Prüfleiste und der Bericht nennen den tatsächlich verwendeten Regelstand.
Reduzierte Profile erhalten einen sichtbaren Hinweis auf ihren begrenzten
Umfang; der Bericht zeigt nur ihre eigene Prüfkette. Die Profilkennung allein
bestätigt keine historische Dokumentversion. Peppol wird gelesen, sein eigenes
vollständiges Prüfprofil ist noch nicht eingebaut. Eine passende Anzeigeerkennung
wird nicht als bestandene Validierung ausgegeben.

Bereits beim Öffnen unlesbare XML-Dateien erscheinen als Ladefehler. Für diesen
Importfall erzeugt die App noch keinen KoSIT-Prüfbericht; die CLI kann solche
Dateien direkt prüfen. Ein Ladefehler bestätigt keine Rechnungsgültigkeit.

## Paketbau und Quellen

`build.sh` bündelt die geprüfte private Runtime samt Regeln und Original-
Lizenzdateien. Der Cache liegt unter `.validation-build/`, getrennt vom durch
Release-Builds bereinigten Swift-Ordner. Sein Schlüssel stammt aus dem
Lizenzinventar; ein veränderter oder unvollständiger Cache wird abgewiesen.

Vor dem Bündeln prüft das Skript das vollständige Lizenz-/Quellenpaket. Daneben
entstehen `TagExplosion-<version>-validation-sources.zip` und
`TagExplosion-<version>-pdf-validation-sources.zip`; beide müssen bei einer
Weitergabe zusammen mit genau diesem Binärstand zugänglich sein. Der
Mindestversions-Check erfasst auch die nativen Dateien der privaten Runtime.
Peppol, DMG-/Updatewege und die abschließende Systemabnahme bleiben
eigene [Meilensteine](e-invoice-validation-roadmap.md).

## Gewährleistung

Der kurze Hinweis steht sichtbar an der Prüfleiste. Der vollständige Hinweis
ist dort abrufbar, im Bericht zugänglich und in jedem kopierten/exportierten
Text enthalten. Er sagt ausdrücklich keine rechtliche/steuerliche Gültigkeit
oder Empfängerannahme zu; zwingende gesetzliche Haftung bleibt unberührt.
Die [MIT-Lizenz](../LICENSE) und fremde Lizenzbedingungen bleiben maßgeblich.

## Prüfung

App-Modelltests prüfen Auswahlwechsel, externe Dateiänderungen, Abbruch,
verspätete Rückgaben, technische Berichte und den Schutz des Exportziels.
Die selbstbeendende GUI-Abnahme nutzt die tatsächlichen SwiftUI-Ansichten und
AXPress auf ihren Prüf-/Abbruchbuttons im notarisierten App-Bundle. Sie wird
ausdrücklich mit `--invoice-ui-selftest <fixture-verzeichnis>` gestartet;
normale Starts aktivieren diesen Modus nicht. Der Test zeigt nicht aktivierende
Fenster, schreibt seine Belege nur ins angegebene Testverzeichnis und beendet
sich selbst. Die Warnungsdarstellung wird zusätzlich synthetisch geprüft und
als reiner Oberflächentest gekennzeichnet.

Testdaten vorbereiten:

```sh
python3 scripts/prepare-invoice-ui-fixtures.py /tmp/invoice-ui-fixtures --facturx
scripts/dev-invoice-uitest.sh /Applications/TagExplosion.app /tmp/invoice-ui-fixtures de
```

Der externe Test-Client benötigt freigegebene Bedienungshilfen. Er fragt den
echten SwiftUI-AX-Baum ab und bricht bei einer erkannten Fokusübernahme ab.
Er startet eine eigene Instanz und beendet ausschließlich eigene Prozesse.
Für Englisch ein frisches Fixture-Verzeichnis und `en` verwenden.

Für native Fensterbelege zusätzlich `--allow-focus` verwenden, nachdem der
kurze Fokuszugriff ausdrücklich freigegeben wurde. Dieser Lauf benötigt auch
Bildschirmaufnahme für die eigenen Fenster, ist zeitlich begrenzt und stellt
anschließend das vorherige Vordergrundprogramm wieder her. Modale Berichte
können Tastaturfokus übernehmen, obwohl das Hauptpanel nicht aktiviert wird.
Eingebettete View-Bitmaps bilden native Vibrancy-Hintergründe teilweise nicht
korrekt ab; ihre Geometrie allein bestätigt deshalb keine korrekte Farbgebung.

Die tatsächlichen System-/Architekturgrenzen sind gesondert zu beachten:
Ein bestandener Apple-Silicon-Lauf auf aktuellem macOS bestätigt weder Intel
noch das gesamte Verhalten auf macOS 14.

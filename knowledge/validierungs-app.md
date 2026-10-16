# Rechnungsvalidierung in SwiftUI

Stand: 2026-10-16, Version 0.50.0.

- `InvoiceValidationModel` besitzt Auswahlrevision, Eingabeabbruch und Sitzung.
  Beim Wechsel oder Verschwinden einer Ansicht wird der alte Auftrag verworfen.
  Ein verspätetes Ergebnis darf die neue Auswahl nicht verändern.
- Frische Anzeige und Prüfung verwenden `InvoiceValidationInput`. Dessen
  Größen-/DOCTYPE-Prüfung muss vor dem erneuten Parsen für die Anzeige erfolgen.
  Berichte sind über XML-/Datei-Prüfsummen an diesen Schnappschuss gebunden.
- GCD-Dateiwächter-Handler außerhalb des Main Actors erzeugen. Eine innerhalb
  eines `@MainActor`-Typs erzeugte Swift-6-Closure erbt sonst dessen Isolation
  und löst beim Aufruf auf der Hintergrundqueue einen Executor-Trap aus.
  `InvoiceFileObservation.watch` ist deshalb ausdrücklich `nonisolated`.
- Beim App-Ende auch bereits invalidierte, noch auslaufende Aufgaben abwarten.
  Die gemeinsame Auftragsliste beendet Prüfläufe samt Kindprozessen und lässt
  bestätigte atomare Berichtexporte fertig werden. Nur `isRunning` der gerade
  sichtbaren Ansicht reicht dafür nicht aus.
- Ein Berichtsexport darf weder den Rechnungspfad noch einen Symlink/Hardlink
  auf die Rechnung ersetzen. Für andere bestätigte Ziele gilt `FileExport`.
- `swift package clean` entfernt den gesamten Swift-Bauordner. Freigegebene
  Validator-/Quellenpakete liegen deshalb unter `.validation-build/`;
  länger benötigte Prüfbelege gehören ebenfalls außerhalb von `.build/`.
- Der explizite GUI-Testmodus verwendet die echten XML-/PDF-Ansichten und
  deren AXPress-Aktionen in einem nicht aktivierenden Panel. Eine synthetische
  Warnungsdarstellung ist ausschließlich ein Darstellungsnachweis, kein
  zusätzlicher Nachweis einer vom Validator erzeugten Warnung.
- SwiftUI baut den Bedienungshilfenbaum bei Bedarf auf. Vor einer AXPress-Aktion
  auf das Element warten; eine bereits ausgeführte `.task` belegt dessen
  Verfügbarkeit nicht. Der externe Client in `dev-invoice-uitest.sh` fragt den
  echten Baum an. Fehlerbelege enthalten View-Bitmap und AX-Baum statt nur
  einer erfolglosen Button-Suche.
- SwiftUIs `AccessibilityNode` deklariert auf dem geprüften System keine
  formale `NSAccessibilityProtocol`-Konformität und liefert intern auch keine
  brauchbaren älteren Attribute. Solche Traversierungen überspringen echte
  Buttons. Der externe Client fragt deshalb den tatsächlichen AX-Baum ab und
  führt angebotene AXPress-Aktionen aus. Der Selbsttest fordert konkrete
  Buttonaktionen mit einer Auftragskennung an und prüft ihre tatsächliche
  Zustandsänderung; er ruft keine Modellaktion als Ersatz für einen Button auf.

Bedienung und Prüfumfang: [App-Dokumentation](../docs/e-invoice-validation-app.md).

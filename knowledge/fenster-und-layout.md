# Fensterverwaltung und SwiftUI-Layout der App (Stand 2026-08-17)

Trifft zu bei Arbeit an `TagExplosionApp.swift`, `WindowSessions.swift`,
`WindowBridge.swift`, `ContentView.swift` oder an den Detailansichten.

## Ein Modell pro Fenster

- `AppModel` entsteht in `MainWindow` (im Rumpf der `WindowGroup`), nicht in
  der `App`-Struktur. Ein `@State` in der `App` gehört der ganzen App: Alle
  Fenster teilten sich dann eine Dateiliste und dieselbe Auswahl.
- Menübefehle dürfen deshalb kein festes Modell benutzen. Sie holen sich über
  `@FocusedValue(\.appModel)` das Modell des vordersten Fensters
  (`focusedSceneValue` in `MainWindow`).
- `WindowSessions` kennt alle Fenster. Angemeldet wird **in der Fensterbrücke**,
  sobald das Fenster wirklich da ist — nicht in `onAppear`. Nur so gehören
  Anmeldung und `hostWindow` zusammen; sonst gäbe es kurz ein angemeldetes
  Modell ohne Fenster, das Dateien verschluckt.
- Abgemeldet wird in `windowWillClose`, **nicht** im `deinit` des Coordinators:
  SwiftUI kann den Coordinator austauschen, während das Fenster bleibt — eine
  Abmeldung im `deinit` löschte dann ein lebendes Fenster aus der Registry.
  Als Sicherheitsnetz wirft `pruneClosedWindows()` Modelle heraus, deren
  schwacher `hostWindow`-Zeiger leer ist.

## Ohne Fenster gibt es kein `openWindow`

- SwiftUIs `openWindow` lebt in der View-Umgebung. Ist das letzte Fenster zu,
  gibt es keine View — der `AppDelegate` kann damit also kein Fenster anlegen.
- Der funktionierende Weg ist ein Reopen auf das eigene Bundle
  (`NSWorkspace.shared.open(Bundle.main.bundleURL)`): Das wirkt wie ein Klick
  aufs Dock-Symbol, und SwiftUI legt ein Fenster der `WindowGroup` an.
  Genau diesen Weg geht `WindowSessions.requestWindow()`; ein Merker
  verhindert, dass zwei kurz aufeinanderfolgende Anforderungen (Öffnen-Ereignis
  plus `showWindowIfHidden` beim Start) zwei Fenster erzeugen.
- Aus dem Menü heraus geht dagegen `openWindow(id:)` — die Menüleiste bleibt
  auch ohne Fenster bestehen, ihre `Commands` haben eine Umgebung.
- **Falle:** `CommandGroup(replacing: .newItem)` entfernt SwiftUIs eigenen
  Eintrag „Neues Fenster“ mitsamt ⌘N. Wer `.newItem` ersetzt, muss den Eintrag
  selbst wieder anbieten, sonst ist die App nach dem Schließen des letzten
  Fensters eine Sackgasse (Befund 2026-08-17).

## Dateiname, Datei-Icon und Pfadmenü

- `NSWindow.representedURL` ist der native Vertrag für Dokumentfenster: AppKit
  zeigt daraus das Datei-Icon und baut bei Command-Klick auf den Titel das
  hierarchische Pfadmenü. Gesetzt wird es in `WindowBridge`.
- Der Titel bleibt der Tag-Titel; der Dateiname steht daneben im Untertitel
  (`WindowChrome`), aber nur, wenn er nicht ohnehin der Titel ist.
- Prüfbar ohne Klicken: Die Accessibility-API spiegelt `representedURL` als
  `kAXDocumentAttribute` des Fensters — `scripts/dev-windowtest.swift` prüft
  genau das.

## SwiftUI-Layout: zwei Fallen, die ganze Ansichten zerlegen

- **`GeometryReader` als Inhalt ist gierig.** Als letztes Element eines
  `VStack` nimmt er sich die ganze Höhe; Kopfbereich, Tab-Umschalter und
  Filterzeile der Rechnungsansicht wurden dadurch aus dem Fenster geschoben.
  Zum reinen Messen gehört er in den `.background(…)` (siehe `WidthReader`
  in `InvoiceView.swift`), nie in den Inhalt.
- **`fixedSize(horizontal: false, vertical: true)` in einer `Grid`-Zelle**
  hat denselben Effekt: Der Profilkopf wuchs über die Fensterhöhe hinaus und
  schob alles darunter weg. Lange Werte dort lieber abschneiden lassen.
- Feste Reservierungen skalieren nicht: Die BT-/BG-Spalte hatte fest 380 pt;
  bei Standard-Fenstergröße blieben dem Inhalt gut 200 pt, und Werte brachen
  mitten im Wort um. Jetzt rechnet `InvoiceFieldLayout.termColumnWidth` die
  Spalte aus der verfügbaren Breite (Anteil, gedeckelt, mit Untergrenze) —
  einmal für die ganze Liste, damit die Terms eine echte Spalte bilden.

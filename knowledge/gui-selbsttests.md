# GUI-Selbsttests der App (Stand 2026-08-20)

Auto-beendende Selbsttests (Fenster blitzt kurz, App beendet sich selbst)
laufen ohne Freigabe — siehe globale Testregeln.

- **Funktioniert:** CGEvent-Mausklicks (auch Shift-Klick für Mehrfachauswahl),
  AX-API (`AXUIElementSetAttributeValue` auf `kAXValue` von SwiftUI-TextFields,
  `kAXPress` auf Menüpunkte). SwiftUI-Bindings übernehmen AX-gesetzte Werte.
- **Funktioniert NICHT:** synthetische Tastatur-Events (CGEvent unicode typing,
  keyCode-Kombis) erreichen SwiftUI-TextFields nicht zuverlässig — nicht
  weiter versuchen, direkt AX nehmen.
- `kCGWindowOwnerName` ist der **CFBundleName** („Tag Explosion", mit
  Leerzeichen), nicht der Executable-Name.
- Fenster-Screenshot: Region-Capture (`screencapture -R x,y,w,h`) mit Bounds
  aus `CGWindowListCopyWindowInfo`; Bounds enthalten die Titelleiste.
- Skripte und Aufrufform:
  - `scripts/dev-screenshot.sh <ausgabe.png> [datei-oder-ordner ...]` — nur
    Belegbild. `TAGX_APP=<bundle>` zeigt auf ein anderes Bundle als das im
    Projekt gebaute; die beiden anderen Skripte nehmen den Pfad als erstes
    Argument.
  - `scripts/dev-uitest.sh <app> <ausgabeordner> <datei> [neuer-titel]` — Feld
    setzen, über das Menü speichern, verifizierbar. Die Datei wird BESCHRIEBEN
    und gespeichert; sie muss eine Wegwerfkopie sein.
  - `scripts/dev-windowtest.sh <app> <ausgabeordner> <datei1> [datei2]` —
    Fenster öffnen/schließen/wieder öffnen, Seitenleiste, Datei-Icon im Titel.
    Bricht ab, wenn schon eine Tag Explosion läuft.
- **Besitzmodell (verbindlich):** Alle drei Skripte teilen sich
  `scripts/lib/gui-testkit.swift` und starten eine EIGENE Instanz
  (`NSWorkspace.open(..., createsNewApplicationInstance: true)`). Beendet wird
  hart (`terminate`, nach 5 s `forceTerminate`), deshalb entscheidet die
  Besitzfrage über fremde ungespeicherte Änderungen. Zwei Regeln, in dieser
  Reihenfolge:
  1. Hat der Start eine PID zurückgemeldet, gilt **ausschließlich** sie.
  2. Nur solange nichts zurückgemeldet wurde, greift die Ersatzregel:
     unbekannte PID plus `launchDate` nach unserem Start. Ohne sie bliebe eine
     Instanz, die erst nach Ablauf der 30-s-Startfrist auftaucht, sichtbar
     stehen (Review-Fund 2026-08-18).
  Nur die Momentaufnahme der PIDs vom Programmstart genügte nicht: Zwischen ihr
  und dem Beenden liegen bis zu einer Minute Fristen, und eine in dieser Zeit
  vom Nutzer gestartete App galt darin als „unsere" (Review-Fund 2026-08-20).
  **Restrisiko (bewusst):** Scheitert unser eigener Start UND startet der Nutzer
  genau in diesem Fenster die App, trifft es seine Instanz. Beide Regeln
  gleichzeitig zu verlangen ginge nicht — dann bliebe die verspätete Instanz
  stehen. Die Skripte behandeln außerdem SIGINT/SIGTERM/SIGHUP und räumen im
  Startfenster noch einige Sekunden nach.
- **Echter Lauf 2026-08-20** gegen die notarisierte Installation
  `/Applications/TagExplosion.app` 0.22.2: alle drei Skripte grün (Fenstertest
  11 Prüfungen, Belegbilder frisch, `dev-uitest` schrieb den Titel und
  `mediainfo` las ihn zurück), keine Instanz blieb stehen. Gegenprobe zur
  Besitzregel: eine mitten im Lauf per `open -n` gestartete zweite Instanz hat
  den Testlauf überlebt.
- **Notarisiert testen, nicht ad-hoc:** TCC-Rechte (Bedienungshilfen,
  Bildschirmaufnahme) hängen an der Code-Signatur. Ein `./build.sh`-Bundle ist
  nur ad-hoc signiert und bekommt sie nicht verlässlich; deshalb vorher
  `./install.sh` und die Skripte auf `/Applications/TagExplosion.app` zeigen
  lassen. Der steuernde Prozess (Terminal beziehungsweise Agent) braucht die
  Rechte ebenfalls — `AXIsProcessTrusted()` und
  `CGPreflightScreenCaptureAccess()` sagen es in zwei Zeilen Swift.
- `kAXDocumentAttribute` eines Fensters spiegelt `NSWindow.representedURL`.
  Damit lässt sich ohne Klicken prüfen, ob Datei-Icon und Command-Klick-
  Pfadmenü im Fenstertitel vorhanden sind.
- Menüpunkte prüfen: `kAXMenuItemCmdCharAttribute` liefert das Tastenkürzel in
  GROSSBUCHSTABEN („N“ für ⌘N) — beim Vergleich nicht auf Kleinschreibung
  bestehen.
- App für Tests immer als **.app-Bundle** starten, nie das nackte
  swift-build-Binary (keine Fensterpräsenz). NICHT über `open -a`: Das trifft
  eine bereits laufende Instanz, und der Test beendete danach die falsche
  (Review-Fund 2026-08-17). Der Testkit nimmt deshalb
  `NSWorkspace.open(..., createsNewApplicationInstance: true)`.
- Die Bundle-ID kommt aus dem übergebenen Bundle, nie aus einer verdrahteten
  Zeichenkette: Ein Bundle mit abweichender ID wurde sonst nie beendet, und der
  Test meldete trotzdem `OK` (Review-Fund 2026-08-20).
- **Falle (2026-07-25):** Beim Start mit einer Datei (`open -a App datei.mp3`)
  legt SwiftUI kein Fenster der `WindowGroup` an — `NSApp.windows` bleibt leer,
  die App läuft unsichtbar, und macOS liefert das Öffnen-Ereignis nie aus.
  `AppDelegate.showWindowIfHidden` fängt das ab (Reopen aufs eigene Bundle).
  Der Testlauf mit Datei prüft diesen Weg mit; er ist der Weg, den ein Nutzer
  aus dem Finder geht.
- Der echte Lauf von `scripts/dev-uitest.sh` prüft jeden AX-Schritt
  (Fokus, Wert, Auslösen), den Menüpunkt **Speichern**, Fenstergeometrie und
  Screenshot-Datei sowie den Exit-Status des Screenshot-Prozesses. Nach dem
  Beenden der App wird deren Prozessstatus mit einer Frist geprüft; `OK` wird
  ausschließlich nach vollständig erfolgreichem Ablauf ausgegeben, sonst endet
  das Skript mit einem Fehlercode.
- **NSOpenPanel:** ⌘⇧G kommt zuverlässig erst nach explizitem Fokus und
  `raise` beim Panel an. Ohne diesen Schritt landet die Tastenkombination unter
  Umständen im vorherigen App-Fenster.

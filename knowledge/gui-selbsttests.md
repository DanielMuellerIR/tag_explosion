# GUI-Selbsttests der App (Stand 2026-07-19)

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
- Skripte: `scripts/dev-screenshot.sh` (nur Screenshot),
  `scripts/dev-uitest.swift` (Feld setzen + Speichern + verifizierbar).
- App für Tests immer als **.app-Bundle** starten (`open -a`), nie das nackte
  swift-build-Binary (keine Fensterpräsenz).
- Der echte Lauf von `scripts/dev-uitest.swift` prüft jeden AX-Schritt
  (Fokus, Wert, Auslösen), den Menüpunkt **Speichern**, Fenstergeometrie und
  Screenshot-Datei sowie den Exit-Status des Screenshot-Prozesses. Nach dem
  Beenden der App wird deren Prozessstatus mit einer Frist geprüft; `OK` wird
  ausschließlich nach vollständig erfolgreichem Ablauf ausgegeben, sonst endet
  das Skript mit einem Fehlercode.
- **NSOpenPanel:** ⌘⇧G kommt zuverlässig erst nach explizitem Fokus und
  `raise` beim Panel an. Ohne diesen Schritt landet die Tastenkombination unter
  Umständen im vorherigen App-Fenster.

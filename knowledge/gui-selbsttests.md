# GUI-Selbsttests der App (Stand 2026-07-17)

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

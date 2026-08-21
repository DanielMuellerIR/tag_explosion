#!/bin/sh
# Auto-beendender GUI-End-to-End-Test über die Accessibility-API: setzt das
# Titel-Feld, speichert über das Menü, prüft Belegbilder und beendet die App.
#
# Aufruf: scripts/dev-uitest.sh <app> <ausgabeordner> <datei> [neuer-titel]
#
# Die Datei wird beschrieben und gespeichert — sie MUSS eine Wegwerfkopie sein.
# Der Test startet dafür eine EIGENE Instanz und beendet ausschließlich diese.
# Vorher griff er die erste laufende App mit dieser Bundle-ID: Er schrieb damit
# in die gerade geöffnete Datei des Nutzers, speicherte sie und beendete
# anschließend dessen Instanz
# (Review-Fund 2026-08-20). Start, Besitzverfolgung, Signalbehandlung und
# Beenden liegen in scripts/lib/gui-testkit.swift.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 3 ] || {
    echo "Aufruf: dev-uitest.sh <app> <ausgabeordner> <datei> [neuer-titel]" >&2
    exit 2
}

{
    cat "$here/scripts/lib/gui-testkit.swift"
    cat <<'SW'

// ---- Rumpf: Titel setzen, speichern ------------------------------------------

let document = URL(fileURLWithPath: testArguments[0])
let newTitle = testArguments.count > 1 ? testArguments[1] : "GUI Test Titel"

func fail(_ message: String) -> Never {
    let stopped = shutDownOwnedInstances()
    FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
    if !stopped {
        FileHandle.standardError.write(
            Data("FEHLER: Test-App ließ sich nicht beenden — bitte von Hand schließen.\n".utf8))
    }
    exit(1)
}

func requireAX(_ result: AXError, operation: String) {
    guard result == .success else {
        fail("AX-Aktion fehlgeschlagen (\(operation)): \(result.rawValue)")
    }
}

guard AXIsProcessTrusted() else { kitFail("Accessibility nicht freigegeben") }
guard FileManager.default.fileExists(atPath: document.path) else {
    kitFail("Testdatei fehlt: \(document.path)")
}

guard let app = launchTestInstance(documents: [document]) else {
    shutDownOwnedInstances(followUpFor: 8)
    kitFail("Test-Instanz startete nicht.")
}
// Fenster brauchen einen Moment, bis sie auf dem Bildschirm sind.
Thread.sleep(forTimeInterval: 3.0)
guard app.activate() else { fail("App konnte nicht aktiviert werden") }
Thread.sleep(forTimeInterval: 1.0)

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// ---- AX-Helfer ---------------------------------------------------------------

func optionalAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return result == .success ? value : nil
}

func requiredAttribute(_ element: AXUIElement, _ name: String, operation: String) -> AnyObject {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    requireAX(result, operation: operation)
    guard let value else { fail("AX-Attribut fehlt: \(operation)") }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (optionalAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String {
    (optionalAttribute(element, kAXRoleAttribute) as? String) ?? ""
}

/// Tiefensuche nach Elementen einer Rolle. Fehlende optionale Kindlisten sind
/// für Blätter normal; alle später wirklich benötigten Elemente werden dagegen
/// mit `requiredAttribute` beziehungsweise `guard` geprüft.
func findAll(_ element: AXUIElement, role wanted: String, depth: Int = 0,
             into result: inout [AXUIElement]) {
    if depth > 30 { return }
    if role(element) == wanted { result.append(element) }
    for child in children(element) {
        findAll(child, role: wanted, depth: depth + 1, into: &result)
    }
}

func firstWindow() -> AXUIElement {
    let windows = requiredAttribute(axApp, kAXWindowsAttribute,
                                    operation: "Fensterliste lesen") as? [AXUIElement]
    guard let window = windows?.first else { fail("Kein Fenster") }
    return window
}

func screenshot(_ name: String) {
    if let problem = captureWindow(of: app.processIdentifier,
                                   to: outDir.appendingPathComponent(name)) {
        fail(problem)
    }
}

// ---- 1) Titel-Feld setzen ------------------------------------------------------

let window = firstWindow()
var textFields: [AXUIElement] = []
findAll(window, role: kAXTextFieldRole, into: &textFields)
print("Textfelder gefunden: \(textFields.count)")
guard let titleField = textFields.first else { fail("Kein Textfeld gefunden") }

// Fokuswechsel committet das SwiftUI-Binding. Jede erforderliche AX-Änderung
// wird geprüft, damit eine fehlende Bedienberechtigung nicht still weiterläuft.
requireAX(AXUIElementSetAttributeValue(titleField, kAXFocusedAttribute as CFString,
                                       kCFBooleanTrue), operation: "Titel-Feld fokussieren")
Thread.sleep(forTimeInterval: 0.3)
requireAX(AXUIElementSetAttributeValue(titleField, kAXValueAttribute as CFString,
                                       newTitle as CFString), operation: "Titel setzen")
Thread.sleep(forTimeInterval: 0.3)
if textFields.count > 1 {
    requireAX(AXUIElementSetAttributeValue(textFields[1], kAXFocusedAttribute as CFString,
                                           kCFBooleanTrue), operation: "Titeländerung committen")
    Thread.sleep(forTimeInterval: 0.3)
}
screenshot("ui-edited.png")

// ---- 2) Speichern über Menüleiste ----------------------------------------------

let menuBar = requiredAttribute(axApp, kAXMenuBarAttribute,
                                operation: "Menüleiste lesen")
guard CFGetTypeID(menuBar) == AXUIElementGetTypeID() else {
    fail("Menüleiste ist kein AXUIElement")
}
let menuBarElement = menuBar as! AXUIElement
var menuItems: [AXUIElement] = []
findAll(menuBarElement, role: kAXMenuItemRole, into: &menuItems)
guard let saveItem = menuItems.first(where: {
    (optionalAttribute($0, kAXTitleAttribute) as? String) == "Speichern"
}) else {
    fail("Menüpunkt Speichern nicht gefunden")
}
requireAX(AXUIElementPerformAction(saveItem, kAXPressAction as CFString),
          operation: "Menüpunkt Speichern drücken")
Thread.sleep(forTimeInterval: 1.0)
screenshot("ui-saved.png")

// ---- 3) App beenden — Signal "fertig mit dem Bildschirm" ----------------------

guard shutDownOwnedInstances() else {
    FileHandle.standardError.write(
        Data("FEHLER: App beendete sich auch nach forceTerminate nicht.\n".utf8))
    exit(1)
}
print("OK")
SW
} | swift - "$@"

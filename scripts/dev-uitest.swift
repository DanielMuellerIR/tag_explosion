// Auto-beendender GUI-End-to-End-Test über die Accessibility-API:
// setzt das Titel-Feld, speichert über das Menü, prüft Screenshots und beendet
// die App. Aufruf: swift scripts/dev-uitest.swift <screenshot-verzeichnis> [neuer-titel]
import AppKit
import ApplicationServices
import Foundation

let shotDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
let newTitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "GUI Test Titel"
let bundleID = "io.github.danielmuellerir.tagexplosion"

func fail(_ message: String) -> Never {
    print("FEHLER: \(message)")
    exit(1)
}

func requireAX(_ result: AXError, operation: String) {
    guard result == .success else {
        fail("AX-Aktion fehlgeschlagen (\(operation)): \(result.rawValue)")
    }
}

guard AXIsProcessTrusted() else { fail("Accessibility nicht freigegeben") }

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
else { fail("App läuft nicht") }
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
    let directory = URL(fileURLWithPath: shotDir, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    } catch {
        fail("Screenshot-Verzeichnis kann nicht angelegt werden: \(error.localizedDescription)")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        fail("Screenshot-Ziel ist kein Verzeichnis: \(directory.path)")
    }

    let window = firstWindow()
    let positionObject = requiredAttribute(window, kAXPositionAttribute,
                                           operation: "Fensterposition lesen")
    let sizeObject = requiredAttribute(window, kAXSizeAttribute,
                                       operation: "Fenstergröße lesen")
    guard CFGetTypeID(positionObject) == AXValueGetTypeID(),
          CFGetTypeID(sizeObject) == AXValueGetTypeID() else {
        fail("Fenstergeometrie ist keine AXValue")
    }
    let position = positionObject as! AXValue
    let size = sizeObject as! AXValue
    var point = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position, .cgPoint, &point),
          AXValueGetValue(size, .cgSize, &extent),
          point.x.isFinite, point.y.isFinite,
          extent.width.isFinite, extent.height.isFinite,
          extent.width > 1, extent.height > 1 else {
        fail("Fenstergeometrie ist ungültig")
    }

    let target = directory.appendingPathComponent(name)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x",
                      "-R\(point.x),\(point.y),\(extent.width),\(extent.height)",
                      target.path]
    do {
        try task.run()
    } catch {
        fail("screencapture konnte nicht starten: \(error.localizedDescription)")
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        fail("screencapture endete mit \(task.terminationStatus)")
    }
    guard FileManager.default.fileExists(atPath: target.path) else {
        fail("Screenshot fehlt: \(target.path)")
    }
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0 else {
            fail("Screenshot ist leer: \(target.path)")
        }
    } catch {
        fail("Screenshot kann nicht geprüft werden: \(error.localizedDescription)")
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

guard app.terminate() else { fail("App-Terminierung konnte nicht angefordert werden") }
let deadline = Date().addingTimeInterval(5)
while !app.isTerminated, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard app.isTerminated else { fail("App beendete sich nicht innerhalb von 5 Sekunden") }
print("OK")

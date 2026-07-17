// Auto-beendender GUI-End-to-End-Test über die Accessibility-API:
// setzt das Titel-Feld, speichert über das Menü und beendet die App.
// Aufruf: swift scripts/dev-uitest.swift <screenshot-verzeichnis> [neuer-titel]
import AppKit
import ApplicationServices
import Foundation

let shotDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"
let newTitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "GUI Test Titel"
let bundleID = "io.github.danielmuellerir.tagexplosion"
let ownerName = "Tag Explosion"

func fail(_ msg: String) -> Never {
    print("FEHLER: \(msg)")
    exit(1)
}

guard AXIsProcessTrusted() else { fail("Accessibility nicht freigegeben") }

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
else { fail("App läuft nicht") }
app.activate()
Thread.sleep(forTimeInterval: 1.0)

let axApp = AXUIElementCreateApplication(app.processIdentifier)

// ---- AX-Helfer ---------------------------------------------------------------

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return err == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String {
    (attribute(element, kAXRoleAttribute) as? String) ?? ""
}

/// Tiefensuche nach Elementen einer Rolle.
func findAll(_ element: AXUIElement, role wanted: String, depth: Int = 0, into out: inout [AXUIElement]) {
    if depth > 30 { return }
    if role(element) == wanted { out.append(element) }
    for child in children(element) {
        findAll(child, role: wanted, depth: depth + 1, into: &out)
    }
}

func screenshot(_ name: String) {
    guard let win = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first,
          let posValue = attribute(win, kAXPositionAttribute),
          let sizeValue = attribute(win, kAXSizeAttribute)
    else { return }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x", "-R\(pos.x),\(pos.y),\(size.width),\(size.height)", "\(shotDir)/\(name)"]
    try? task.run()
    task.waitUntilExit()
}

// ---- 1) Titel-Feld setzen ------------------------------------------------------

guard let window = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement])?.first
else { fail("Kein Fenster") }

var textFields: [AXUIElement] = []
findAll(window, role: kAXTextFieldRole, into: &textFields)
print("Textfelder gefunden: \(textFields.count)")
guard let titleField = textFields.first else { fail("Kein Textfeld gefunden") }

// Fokus setzen und Wert schreiben (Fokuswechsel committet das SwiftUI-Binding)
AXUIElementSetAttributeValue(titleField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 0.3)
AXUIElementSetAttributeValue(titleField, kAXValueAttribute as CFString, newTitle as CFString)
Thread.sleep(forTimeInterval: 0.3)
if textFields.count > 1 {
    AXUIElementSetAttributeValue(textFields[1], kAXFocusedAttribute as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
}
screenshot("ui-edited.png")

// ---- 2) Speichern über Menüleiste ----------------------------------------------

var menuItems: [AXUIElement] = []
if let menuBar = attribute(axApp, kAXMenuBarAttribute) {
    findAll(menuBar as! AXUIElement, role: kAXMenuItemRole, into: &menuItems)
}
var saved = false
for item in menuItems {
    if let title = attribute(item, kAXTitleAttribute) as? String, title == "Speichern" {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        saved = true
        break
    }
}
print(saved ? "Speichern gedrückt" : "FEHLER: Menüpunkt Speichern nicht gefunden")
Thread.sleep(forTimeInterval: 1.0)
screenshot("ui-saved.png")

// ---- 3) App beenden — Signal "fertig mit dem Bildschirm" ------------------------

app.terminate()
print(saved ? "OK" : "TEILWEISE")

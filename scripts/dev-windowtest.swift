// Auto-beendender GUI-Selbsttest der Fensterverwaltung.
//
// Geprüft wird genau das, was ein Nutzer im Finder tut und was zuvor kaputt
// war (Befund 2026-08-17): Datei öffnen, Fenster schließen, wieder
// öffnen. Dazu Seitenleiste, Dateiname und Datei-Icon im Fensterkopf.
//
// Aufruf: swift scripts/dev-windowtest.swift <app> <ausgabeordner> <datei1> [datei2]
//
// Der Test startet eine EIGENE Instanz (createsNewApplicationInstance) und
// beendet ausschließlich diese — eine produktiv benutzte Tag Explosion bleibt
// unberührt. Läuft bereits eine, bricht der Test ab, statt fremde Fenster zu
// schließen.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let bundleID = "io.github.danielmuellerir.tagexplosion"

guard CommandLine.arguments.count >= 4 else {
    FileHandle.standardError.write(Data(
        "Aufruf: dev-windowtest.swift <app> <ausgabeordner> <datei1> [datei2]\n".utf8))
    exit(2)
}
let appPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let documents = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }

var failures: [String] = []
func log(_ message: String) { print(message) }
func check(_ condition: Bool, _ what: String) {
    log((condition ? "  OK   " : "  FEHL ") + what)
    if !condition { failures.append(what) }
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("FEHLER: Accessibility nicht freigegeben\n".utf8))
    exit(1)
}
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
    FileHandle.standardError.write(Data(
        "FEHLER: Es läuft bereits eine Tag Explosion — der Test würde sie stören.\n".utf8))
    exit(1)
}
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data(
        "FEHLER: Ausgabeordner nicht anlegbar: \(error.localizedDescription)\n".utf8))
    exit(1)
}

/// Startet die App beziehungsweise reicht Dateien an die laufende Instanz.
func open(_ urls: [URL], newInstance: Bool) -> NSRunningApplication? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = newInstance
    configuration.activates = true
    let bundle = URL(fileURLWithPath: appPath)
    var launched: NSRunningApplication?
    let done = DispatchSemaphore(value: 0)
    let handler: (NSRunningApplication?, Error?) -> Void = { application, error in
        launched = application
        if let error { log("   Start-/Öffnen-Fehler: \(error.localizedDescription)") }
        done.signal()
    }
    if urls.isEmpty {
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration,
                                           completionHandler: handler)
    } else {
        NSWorkspace.shared.open(urls, withApplicationAt: bundle,
                                configuration: configuration, completionHandler: handler)
    }
    // Der Handler läuft auf dem Main-Thread; deshalb die RunLoop drehen statt
    // blockierend zu warten.
    let deadline = Date().addingTimeInterval(30)
    while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return launched
}

guard let running = open(Array(documents.prefix(1)), newInstance: true) else {
    FileHandle.standardError.write(Data("FEHLER: Test-Instanz startete nicht.\n".utf8))
    exit(1)
}
let pid = running.processIdentifier

/// Beendet die Test-App — erst höflich, nach der Frist hart.
@discardableResult
func shutDown() -> Bool {
    func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !running.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return running.isTerminated
    }
    _ = running.terminate()
    if waitForExit(5) { return true }
    _ = running.forceTerminate()
    return waitForExit(5)
}

Thread.sleep(forTimeInterval: 3.0)
_ = running.activate()
Thread.sleep(forTimeInterval: 1.0)

// ---- AX-Helfer ---------------------------------------------------------------

let axApp = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func title(_ element: AXUIElement) -> String {
    (attribute(element, kAXTitleAttribute) as? String) ?? ""
}
func describe(_ element: AXUIElement) -> String {
    (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
}
func windows() -> [AXUIElement] {
    (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}
func size(_ element: AXUIElement) -> CGSize {
    var value = CGSize.zero
    if let raw = attribute(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        AXValueGetValue(raw as! AXValue, .cgSize, &value)
    }
    return value
}
/// Die vertretene Datei (NSWindow.representedURL) — Grundlage für Datei-Icon
/// und Command-Klick-Pfadmenü im Fenstertitel.
func documentURL(_ window: AXUIElement) -> String {
    (attribute(window, kAXDocumentAttribute) as? String) ?? ""
}
func allElements(_ element: AXUIElement, depth: Int = 0, into result: inout [AXUIElement]) {
    guard depth < 40 else { return }
    result.append(element)
    for child in children(element) { allElements(child, depth: depth + 1, into: &result) }
}
/// Breite der Seitenleiste im ersten Fenster (0 = ausgeblendet).
func sidebarWidth() -> CGFloat {
    guard let window = windows().first else { return -1 }
    var all: [AXUIElement] = []
    allElements(window, into: &all)
    for element in all where describe(element) == "Seitenleiste" { return size(element).width }
    return 0
}
func report(_ label: String) -> [AXUIElement] {
    let list = windows()
    log("[\(label)] Fenster: \(list.count)")
    for window in list {
        let document = documentURL(window)
        log("   \"\(title(window))\"  Datei: \(document.isEmpty ? "—" : document)")
    }
    return list
}
@discardableResult
func pressMenuItem(_ menuName: String, _ itemName: String) -> Bool {
    guard let menuBar = attribute(axApp, kAXMenuBarAttribute) else { return false }
    // swiftlint:disable:next force_cast
    for item in children(menuBar as! AXUIElement) where title(item) == menuName {
        for submenu in children(item) {
            for entry in children(submenu) where title(entry) == itemName {
                return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
            }
        }
    }
    return false
}
func closeAllWindows() {
    // Begrenzte Runde: Ohne Obergrenze liefe der Test bei einem hängenden
    // Fenster endlos.
    for _ in 0..<6 {
        guard let window = windows().first,
              let closeButton = attribute(window, kAXCloseButtonAttribute) else { return }
        // swiftlint:disable:next force_cast
        AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        Thread.sleep(forTimeInterval: 1.2)
    }
}
func screenshot(_ name: String) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else { return }
    var best: (rect: CGRect, area: CGFloat) = (.zero, 0)
    for entry in list where (entry[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = CGRect(x: bounds["X"] as? CGFloat ?? 0, y: bounds["Y"] as? CGFloat ?? 0,
                          width: bounds["Width"] as? CGFloat ?? 0,
                          height: bounds["Height"] as? CGFloat ?? 0)
        if rect.width * rect.height > best.area { best = (rect, rect.width * rect.height) }
    }
    guard best.area > 0 else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x",
                      "-R\(best.rect.origin.x),\(best.rect.origin.y),\(best.rect.width),\(best.rect.height)",
                      outDir.appendingPathComponent(name).path]
    try? task.run()
    task.waitUntilExit()
}

// ---- Ablauf ------------------------------------------------------------------

let fileName = documents[0].lastPathComponent
var list = report("Start mit einer Datei")
check(list.count == 1, "genau ein Fenster nach dem Start")
check(list.first.map { documentURL($0).contains(fileName) } ?? false,
      "Fenster vertritt die Datei (Datei-Icon und Pfadmenü im Titel)")
check(sidebarWidth() == 0, "Seitenleiste bei einer Datei ausgeblendet")
screenshot("fenster-eine-datei.png")

check(pressMenuItem("Ablage", "Neues Fenster"), "Menüpunkt „Neues Fenster“ vorhanden")
Thread.sleep(forTimeInterval: 2.0)
check(report("nach Neues Fenster").count == 2, "zweites Fenster geöffnet")

closeAllWindows()
check(report("nach Schließen aller Fenster").isEmpty, "alle Fenster geschlossen")

// Der eigentliche Befund: Ohne Fenster war die App eine Sackgasse.
_ = open(Array(documents.prefix(1)), newInstance: false)
Thread.sleep(forTimeInterval: 4.0)
list = report("nach Öffnen ohne Fenster")
check(list.count == 1, "Öffnen ohne offenes Fenster legt ein neues an")
check(list.first.map { documentURL($0).contains(fileName) } ?? false,
      "die geöffnete Datei ist im neuen Fenster zu sehen")

if documents.count > 1 {
    _ = open([documents[1]], newInstance: false)
    Thread.sleep(forTimeInterval: 3.0)
    list = report("nach zweiter Datei")
    check(list.count == 1, "die zweite Datei landet im vorhandenen Fenster")
    check(sidebarWidth() > 100, "Seitenleiste ab zwei Dateien sichtbar")
    screenshot("fenster-zwei-dateien.png")
}

let stopped = shutDown()
if !stopped {
    failures.append("Test-App ließ sich nicht beenden — bitte von Hand schließen")
}
guard failures.isEmpty else {
    FileHandle.standardError.write(Data(
        ("FEHLER: \(failures.count) Prüfung(en) fehlgeschlagen:\n"
            + failures.map { "  - \($0)\n" }.joined()).utf8))
    exit(1)
}
print("OK Fenstertest")

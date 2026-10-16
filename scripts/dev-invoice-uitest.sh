#!/bin/sh
# Startet den expliziten Rechnungs-Selbsttest ohne Fokusübernahme. Der externe
# AX-Client fordert den SwiftUI-Bedienungshilfenbaum tatsächlich an.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
[ "$#" -ge 2 ] || { echo "Aufruf: dev-invoice-uitest.sh <app> <fixture-verzeichnis> [de|en]" >&2; exit 2; }
{
    cat "$here/scripts/lib/gui-testkit.swift"
    cat <<'SW'
guard AXIsProcessTrusted() else { kitFail("Bedienungshilfen für den Test-Client nicht freigegeben") }
guard CGPreflightScreenCaptureAccess() else { kitFail("Bildschirmaufnahme für eigene Fensterbelege nicht freigegeben") }
let language = testArguments.first ?? "de"
let allowFocus = testArguments.dropFirst().contains("--allow-focus")
guard ["de", "en"].contains(language) else { kitFail("Sprache muss de oder en sein") }
let resultURL = outDir.appendingPathComponent("ui-result.json")
guard !FileManager.default.fileExists(atPath: resultURL.path) else { kitFail("Testverzeichnis enthält bereits ein Ergebnis") }
let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
let deadline = Date().addingTimeInterval(allowFocus ? 35 : 70)
guard let app = launchTestInstance(activates: false, arguments: ["--invoice-ui-selftest", outDir.path, "-AppleLanguages", "(\(language))"]) else {
    shutDownOwnedInstances(followUpFor: 8)
    kitFail("Test-App nicht gestartet")
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)
func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
var sawButton = false
func target(_ element: AXUIElement, identifier: String, label: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 30 else { return nil }
    let id = attribute(element, kAXIdentifierAttribute) as? String ?? ""
    let title = attribute(element, kAXTitleAttribute) as? String ?? ""
    let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
    if id == identifier || (!label.isEmpty && (title == label || description == label)) {
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success,
           (actions as? [String])?.contains(kAXPressAction as String) == true { return element }
    }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = target(child, identifier: identifier, label: label, depth: depth + 1) { return found }
    }
    return nil
}
func inspect(_ element: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 30 else { return [] }
    let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
    if identifier == "invoice.validation.start" { sawButton = true }
    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
    let title = attribute(element, kAXTitleAttribute) as? String ?? ""
    var lines = [String(repeating: " ", count: depth) + role + " " + identifier + " " + title]
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { lines += inspect(child, depth: depth + 1) }
    return lines
}
var tree: [String] = []
var handledRequest: String?
var acquiredFocus = false
var reportNumber = 0
var captureFailure: String?
func captureOwnedWindows(_ prefix: String) {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where window[kCGWindowOwnerPID as String] as? Int == Int(app.processIdentifier) {
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        guard (bounds["Width"] as? Double ?? 0) > 100, (bounds["Height"] as? Double ?? 0) > 100,
              let id = window[kCGWindowNumber as String] as? Int else { continue }
        let destination = outDir.appendingPathComponent("\(prefix)-window-\(id).png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(id)", destination.path]
        do {
            try capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus != 0 || !FileManager.default.fileExists(atPath: destination.path) {
                captureFailure = "Fensterbeleg fehlgeschlagen: \(id)"
            }
        } catch { captureFailure = error.localizedDescription }
    }
}
while !app.isTerminated, Date() < deadline {
    if let focused = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
        var focusedPID: pid_t = 0
        if AXUIElementGetPid(focused as! AXUIElement, &focusedPID) == .success,
           focusedPID == app.processIdentifier {
            acquiredFocus = true
            if !allowFocus { app.hide(); break }
        }
    }
    let current = inspect(axApp)
    if current.count > tree.count { tree = current }
    if let data = try? Data(contentsOf: outDir.appendingPathComponent("press-request.json")),
       let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
       let nonce = request["nonce"], nonce != handledRequest,
       let identifier = request["identifier"],
       let button = target(axApp, identifier: identifier, label: request["label"] ?? "") {
        if identifier == "invoice.validation.report" {
            reportNumber += 1
            captureOwnedWindows("native-report-\(reportNumber)-before")
        } else if identifier == "invoice.validation.report.close" {
            captureOwnedWindows("native-report-\(reportNumber)-sheet")
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        let response: [String: Any] = ["nonce": nonce, "success": result == .success, "error": result.rawValue]
        try JSONSerialization.data(withJSONObject: response).write(to: outDir.appendingPathComponent("press-response.json"), options: .atomic)
        handledRequest = nonce
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
try? tree.joined(separator: "\n").write(to: outDir.appendingPathComponent("client-ax.txt"), atomically: true, encoding: .utf8)
let stopped = shutDownOwnedInstances()
guard stopped, app.isTerminated else { kitFail("Eigene Test-App nicht beendet") }
guard allowFocus || !acquiredFocus else { kitFail("Test-App hat Tastaturfokus übernommen und wurde ausgeblendet") }
guard captureFailure == nil else { kitFail(captureFailure!) }
guard sawButton else { kitFail("Prüfbutton wurde extern nicht im AX-Baum beobachtet") }
if allowFocus, let foreground, NSWorkspace.shared.frontmostApplication?.processIdentifier != foreground {
    NSRunningApplication(processIdentifier: foreground)?.activate()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else { kitFail("Fensterfokus wurde verändert") }
let data = try Data(contentsOf: resultURL)
let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
guard result?["status"] as? String == "passed" else { kitFail("GUI-Abnahme fehlgeschlagen; siehe ui-result.json") }
print("GUI-Abnahme \(language): bestanden; eigener Prozess beendet; Fokus \(allowFocus ? "wiederhergestellt" : "unverändert")")
SW
} | xcrun swift - "$@"

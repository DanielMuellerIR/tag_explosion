// Gemeinsamer Unterbau der GUI-Selbsttests: eigene App-Instanz starten, ihren
// Besitz verfolgen, Signale behandeln, Belegbilder machen, sauber beenden.
//
// Diese Datei ist KEIN eigenständiges Programm. Jedes Testskript hängt seinen
// Rumpf per `cat` an diese Datei und schickt beides zusammen an `swift -` —
// `swift datei.swift` kann keine zweite Quelldatei einbinden. Vorher stand der
// Start-, Besitz- und Signalblock fast gleichlautend zweimal im Repo und im
// dritten Skript gar nicht; jede Korrektur war dreimal fällig und wurde es nie
// (Review-Fund 2026-08-20).
//
// Aufrufform aller Skripte: <app-bundle> <ausgabeordner> [weitere Argumente]
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// ---- Aufrufparameter ---------------------------------------------------------

func kitFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 3 else {
    kitFail("Aufruf: <app-bundle> <ausgabeordner> [weitere Argumente]")
}
let appPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
/// Alles nach App und Ausgabeordner — jedes Skript deutet es selbst.
let testArguments = Array(CommandLine.arguments.dropFirst(3))

guard FileManager.default.fileExists(atPath: appPath) else {
    kitFail("App-Bundle fehlt: \(appPath) — erst ./build.sh")
}
// Die Bundle-ID kommt aus dem übergebenen Bundle, nicht aus einer verdrahteten
// Zeichenkette: Ein Bundle mit abweichender ID würde sonst nie beendet, und der
// Test meldete trotzdem Erfolg. Ist sie nicht lesbar, bricht der Test hier ab,
// statt später „erfolgreich nichts zu beenden" (Review-Fund 2026-08-20).
guard let testBundleID = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier else {
    kitFail("Bundle-ID nicht lesbar: \(appPath)/Contents/Info.plist")
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    kitFail("Ausgabeordner nicht anlegbar: \(error.localizedDescription)")
}

// ---- Wem gehört welcher Prozess? --------------------------------------------

/// Zeitpunkt, ab dem eine Instanz uns gehören KANN.
let testStartInstant = Date()
/// Alles, was jetzt schon läuft, gehört einer produktiv benutzten Tag Explosion
/// und wird nie angefasst.
let foreignPIDs: Set<pid_t> = Set(
    NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID)
        .map(\.processIdentifier))
/// Instanzen, die wir selbst gestartet haben. Sie zählen unabhängig davon, ob
/// AppKit ein `launchDate` liefert.
var claimedPIDs: Set<pid_t> = []

func claimOwnership(of app: NSRunningApplication) {
    guard !foreignPIDs.contains(app.processIdentifier) else { return }
    claimedPIDs.insert(app.processIdentifier)
}

/// Alle Instanzen, die zu DIESEM Lauf gehören.
///
/// Sobald der Start eine PID zurückgemeldet hat, gilt AUSSCHLIESSLICH sie.
/// Eine PID-Momentaufnahme vom Programmstart genügt nämlich nicht: Zwischen ihr
/// und dem Beenden liegen bis zu einer Minute Warte- und Startfristen, und eine
/// App, die der Nutzer in dieser Zeit startet, galt darin als „unsere" —
/// `terminate()` samt Rückfragedialog und 5 Sekunden später `forceTerminate()`
/// träfen dann seine ungespeicherten Änderungen (Review-Fund 2026-08-20).
///
/// Nur SOLANGE nichts zurückgemeldet wurde, greift die Ersatzregel: unbekannte
/// PID plus `launchDate` nach unserem Start. Ohne sie bliebe eine Instanz, die
/// erst nach Ablauf der Startfrist auftaucht, sichtbar stehen (Review-Fund
/// 2026-08-18). Restrisiko dieses einen Falls (bewusst): Scheitert unser Start
/// und der Nutzer startet genau in diesem Fenster die App, trifft es seine
/// Instanz. Beide Regeln zugleich zu verlangen ginge nicht — dann bliebe die
/// verspätete Instanz stehen.
func ownedInstances() -> [NSRunningApplication] {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID)
    if !claimedPIDs.isEmpty {
        return running.filter { claimedPIDs.contains($0.processIdentifier) }
    }
    return running.filter { app in
        guard !foreignPIDs.contains(app.processIdentifier) else { return false }
        // Ohne Startzeitpunkt bleibt die Instanz unangetastet: Lieber eine
        // Test-App sichtbar stehen lassen (das meldet der Test) als eine fremde
        // beenden.
        guard let launched = app.launchDate else { return false }
        return launched >= testStartInstant
    }
}

/// Beendet alle eigenen Instanzen — erst höflich, nach der Frist hart.
///
/// `followUpFor` hält danach noch eine Weile Ausschau: Beim Abbruch im
/// Startfenster steht die eigene Instanz oft noch gar nicht in der
/// Prozessliste, und ohne Nachfassen startete sie danach und blieb sichtbar
/// stehen (Review-Fund 2026-08-20).
@discardableResult
func shutDownOwnedInstances(followUpFor grace: TimeInterval = 0) -> Bool {
    func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ownedInstances().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return ownedInstances().isEmpty
    }
    func sweep() {
        for app in ownedInstances() { _ = app.terminate() }
        if waitForExit(5) { return }
        for app in ownedInstances() { _ = app.forceTerminate() }
        _ = waitForExit(5)
    }
    sweep()
    let deadline = Date().addingTimeInterval(grace)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        if !ownedInstances().isEmpty { sweep() }
    }
    return ownedInstances().isEmpty
}

// ---- Signale ----------------------------------------------------------------

// VOR dem Start behandeln: Ein Ctrl-C oder ein Abbruch der übergeordneten Shell
// traf sonst mitten in einen `Thread.sleep`, und die Test-App blieb sichtbar
// zurück. Die Quellen laufen auf einer eigenen Warteschlange und greifen
// deshalb auch bei schlafendem Hauptthread.
let guiTestSignalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        FileHandle.standardError.write(Data(
            "ABBRUCH: Signal \(number) — die Test-App wird beendet.\n".utf8))
        // Nachfassen, weil der Abbruch häufig genau im Startfenster kommt.
        shutDownOwnedInstances(followUpFor: 8)
        exit(128 + number)
    }
    source.resume()
    return source
}

// ---- Starten -----------------------------------------------------------------

/// Startet die App beziehungsweise reicht Dateien an die eigene, laufende
/// Instanz. `newInstance: true` sorgt dafür, dass eine bereits laufende, fremde
/// Tag Explosion unberührt bleibt.
func launchTestInstance(documents: [URL] = [],
                        newInstance: Bool = true) -> NSRunningApplication? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = newInstance
    configuration.activates = true
    let bundle = URL(fileURLWithPath: appPath)
    var launched: NSRunningApplication?
    let done = DispatchSemaphore(value: 0)
    let handler: (NSRunningApplication?, Error?) -> Void = { application, error in
        launched = application
        if let error {
            FileHandle.standardError.write(
                Data("   Start-/Öffnen-Fehler: \(error.localizedDescription)\n".utf8))
        }
        done.signal()
    }
    if documents.isEmpty {
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration,
                                           completionHandler: handler)
    } else {
        NSWorkspace.shared.open(documents, withApplicationAt: bundle,
                                configuration: configuration, completionHandler: handler)
    }
    // Der Handler läuft auf dem Main-Thread; deshalb die RunLoop drehen statt
    // blockierend zu warten.
    let deadline = Date().addingTimeInterval(30)
    while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    // Frist abgelaufen, der Auftrag kann trotzdem noch ankommen. Gesucht wird
    // dabei ausschließlich unter den EIGENEN Instanzen: Eine fremde, in dieser
    // Zeit vom Nutzer gestartete App zu übernehmen hieße, ihre Fenster zu
    // schließen und sie am Ende zu beenden (Review-Fund 2026-08-20). Bei
    // `newInstance: false` entsteht ohnehin kein neuer Prozess.
    if launched == nil, newInstance {
        let grace = Date().addingTimeInterval(10)
        while launched == nil, Date() < grace {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            launched = ownedInstances().first
        }
    }
    if let launched { claimOwnership(of: launched) }
    return launched
}

// ---- Belegbilder -------------------------------------------------------------

/// Fensterrechteck der größten Fläche, die `pid` gerade zeigt.
func largestWindowBounds(of pid: pid_t) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else { return nil }
    var best: (rect: CGRect, area: CGFloat) = (.zero, 0)
    for entry in list where (entry[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let rect = CGRect(x: bounds["X"] as? CGFloat ?? 0, y: bounds["Y"] as? CGFloat ?? 0,
                          width: bounds["Width"] as? CGFloat ?? 0,
                          height: bounds["Height"] as? CGFloat ?? 0)
        if rect.width * rect.height > best.area { best = (rect, rect.width * rect.height) }
    }
    return best.area > 0 ? best.rect : nil
}

/// Belegbild des größten Fensters von `pid`. Rückgabe nil = alles gut, sonst
/// der Grund. JEDER Fehlschlag wird gemeldet: Vorher unterdrückten die Skripte
/// den Startfehler von `screencapture` und prüften die Zieldatei nicht — der
/// Test meldete Erfolg, obwohl das Belegbild fehlte oder aus einem früheren
/// Lauf stammte.
func captureWindow(of pid: pid_t, to target: URL) -> String? {
    // Ein Bild aus einem früheren Lauf darf nicht als frisches durchgehen:
    // `screencapture` kann mit Status 0 enden, ohne zu schreiben (etwa bei
    // verweigerter Bildschirmaufnahme-Berechtigung).
    try? FileManager.default.removeItem(at: target)
    do {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        return "Ausgabeordner nicht anlegbar: \(error.localizedDescription)"
    }
    guard let rect = largestWindowBounds(of: pid) else {
        return "kein Fenster für \(target.lastPathComponent) gefunden"
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-o", "-x",
                      "-R\(rect.origin.x),\(rect.origin.y),\(rect.width),\(rect.height)",
                      target.path]
    do {
        try task.run()
    } catch {
        return "screencapture startete nicht: \(error.localizedDescription)"
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        return "screencapture endete mit Status \(task.terminationStatus)"
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
    let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard bytes > 0 else { return "Belegbild \(target.lastPathComponent) ist leer" }
    return nil
}

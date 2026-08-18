#!/bin/sh
# Auto-beendender GUI-Selbsttest: startet TagExplosion.app mit Testdateien,
# holt das Fenster kurz nach vorn, macht einen Region-Screenshot und beendet
# die App sofort wieder (Fenster blitzt nur kurz auf).
# Aufruf: scripts/dev-screenshot.sh <ausgabe.png> [datei-oder-ordner ...]
#
# Start UND Ende der Test-App liegen bewusst im Swift-Teil unten. Vorher startete
# die Shell die App per `open -a`, wartete drei Sekunden und griff danach die
# ERSTE laufende App mit dieser Bundle-ID: Lief schon eine produktiv benutzte
# Instanz, beendete der Selbsttest die falsche — mitsamt ungesicherter
# Aenderungen. Und ein Signal waehrend des `sleep` oder ein Fehler beim
# Kompilieren erreichte den Aufraeumcode nie (Review-Fund 2026-08-17).
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?Ausgabe-PNG angeben}"; shift

app="$here/TagExplosion.app"
[ -d "$app" ] || { echo "App fehlt — erst ./build.sh" >&2; exit 1; }

# Fenster-Region ermitteln, aktivieren, screenshotten, App beenden
swift - "$app" "$out" "$@" <<'SW'
import AppKit
import CoreGraphics
import Foundation

let appPath = CommandLine.arguments[1]
let out = CommandLine.arguments[2]
let documents = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }

// Wem gehoert welcher Prozess? Alles, was VOR unserem Start schon lief, gehoert
// einer produktiv benutzten Tag Explosion und wird nie angefasst. Alles, was
// danach mit dieser Bundle-ID auftaucht, ist unsere Test-Instanz — auch wenn
// der Startauftrag erst nach der Frist ankommt (Review-Fund 2026-08-18).
// Bewusst dieselbe Logik wie in scripts/dev-windowtest.swift: `swift datei.swift`
// kann keine zweite Quelldatei einbinden, ein gemeinsamer Helfer ginge nur
// ueber eine zusammenkopierte Datei.
let testBundleID = Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
let foreignPIDs: Set<pid_t> = Set((testBundleID.map {
    NSRunningApplication.runningApplications(withBundleIdentifier: $0)
} ?? []).map(\.processIdentifier))

func ownedInstances() -> [NSRunningApplication] {
    guard let testBundleID else { return [] }
    return NSRunningApplication.runningApplications(withBundleIdentifier: testBundleID)
        .filter { !foreignPIDs.contains($0.processIdentifier) }
}

/// Beendet alle eigenen Instanzen — erst hoeflich, dann hart.
@discardableResult
func shutDownOwnedInstances() -> Bool {
    func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ownedInstances().isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return ownedInstances().isEmpty
    }
    for app in ownedInstances() { _ = app.terminate() }
    if waitForExit(5) { return true }
    for app in ownedInstances() { _ = app.forceTerminate() }
    return waitForExit(5)
}

// Signale VOR dem Start behandeln: Ein Ctrl-C oder ein Abbruch der
// uebergeordneten Shell traf sonst mitten in einen `Thread.sleep`, und die
// Test-App blieb sichtbar zurueck. Die Quellen laufen auf einer eigenen
// Warteschlange und greifen deshalb auch bei schlafendem Hauptthread.
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
        FileHandle.standardError.write(Data(
            "ABBRUCH: Signal \(number) — die Test-App wird beendet.\n".utf8))
        shutDownOwnedInstances()
        exit(128 + number)
    }
    source.resume()
    return source
}

// Eine EIGENE Instanz starten und genau sie festhalten. `createsNewApplicationInstance`
// sorgt dafuer, dass eine bereits laufende Tag Explosion unberuehrt bleibt.
func launchTestInstance() -> NSRunningApplication? {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    let bundle = URL(fileURLWithPath: appPath)
    var launched: NSRunningApplication?
    let done = DispatchSemaphore(value: 0)
    let handler: (NSRunningApplication?, Error?) -> Void = { application, error in
        launched = application
        if let error {
            FileHandle.standardError.write(
                Data("FEHLER: App-Start: \(error.localizedDescription)\n".utf8))
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
    // Der Handler laeuft auf dem Main-Thread; deshalb die RunLoop drehen statt
    // blockierend zu warten.
    let deadline = Date().addingTimeInterval(30)
    while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    // Frist abgelaufen, der Auftrag kann trotzdem noch ankommen: Eine JETZT neu
    // auftauchende Instanz ist unsere und darf nicht unbeaufsichtigt bleiben.
    if launched == nil {
        let grace = Date().addingTimeInterval(10)
        while launched == nil, Date() < grace {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            launched = ownedInstances().first
        }
    }
    return launched
}

guard let running = launchTestInstance() else {
    FileHandle.standardError.write(Data("FEHLER: Test-Instanz startete nicht.\n".utf8))
    // Sicherheitsnetz gegen einen verspaeteten Start ohne Rueckmeldung.
    shutDownOwnedInstances()
    exit(1)
}
// Ab hier gilt: Auf JEDEM Weg aus diesem Programm wird genau diese Instanz
// beendet — sie gehoert uns, niemandem sonst.
let testPID = running.processIdentifier

// Beendet die Test-App und wartet auf ihr tatsächliches Ende — erst höflich
// (terminate), nach Ablauf der Frist hart (forceTerminate). Erfolgs- UND
// Fehlerpfad laufen hierüber: Ein bloß angefordertes terminate ohne Warten
// ließe die App nach einem frühen Fehler sichtbar weiterlaufen.
func shutDownApp() -> Bool {
    // Ueber die eigene Instanzliste statt nur ueber `running`: Ein zweiter,
    // verspaetet gestarteter Prozess gehoert genauso zu diesem Lauf.
    shutDownOwnedInstances()
}

func fail(_ message: String) -> Never {
    let stopped = shutDownApp()
    FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
    if !stopped {
        FileHandle.standardError.write(
            Data("FEHLER: Test-App ließ sich nicht beenden — bitte von Hand schließen.\n".utf8))
    }
    exit(1)
}

// Fenster brauchen einen Moment, bis sie auf dem Bildschirm sind.
Thread.sleep(forTimeInterval: 3.0)
guard running.activate() else { fail("App konnte nicht aktiviert werden") }
Thread.sleep(forTimeInterval: 1.0)

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
else { fail("Fensterliste konnte nicht gelesen werden") }

// Fenster ueber die PID zuordnen, nicht ueber den Anzeigenamen: Eine zweite
// Instanz derselben App traegt denselben Namen, aber eine andere PID.
var best: (bounds: CGRect, area: CGFloat) = (.zero, 0)
for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == testPID {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let rect = CGRect(
        x: b["X"] as? CGFloat ?? 0, y: b["Y"] as? CGFloat ?? 0,
        width: b["Width"] as? CGFloat ?? 0, height: b["Height"] as? CGFloat ?? 0)
    if rect.width * rect.height > best.area { best = (rect, rect.width * rect.height) }
}
guard best.area > 0 else { fail("Kein Fenster gefunden") }

let r = best.bounds
let target = URL(fileURLWithPath: out)
do {
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fail("Ausgabeordner kann nicht angelegt werden: \(error.localizedDescription)")
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-o", "-x", "-R\(r.origin.x),\(r.origin.y),\(r.width),\(r.height)", out]
do {
    try task.run()
} catch {
    fail("screencapture konnte nicht starten: \(error.localizedDescription)")
}
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    fail("screencapture endete mit Status \(task.terminationStatus)")
}
do {
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    guard let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0 else {
        fail("Screenshot ist leer: \(target.path)")
    }
} catch {
    fail("Screenshot kann nicht geprüft werden: \(error.localizedDescription)")
}

// Sofort beenden — Signal "fertig mit dem Bildschirm"
guard shutDownApp() else {
    FileHandle.standardError.write(
        Data("FEHLER: App beendete sich auch nach forceTerminate nicht.\n".utf8))
    exit(1)
}
print("OK \(out)")
SW

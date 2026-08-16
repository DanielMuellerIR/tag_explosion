#!/bin/sh
# Auto-beendender GUI-Selbsttest: startet TagExplosion.app mit Testdateien,
# holt das Fenster kurz nach vorn, macht einen Region-Screenshot und beendet
# die App sofort wieder (Fenster blitzt nur kurz auf).
# Aufruf: scripts/dev-screenshot.sh <ausgabe.png> [datei-oder-ordner ...]
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?Ausgabe-PNG angeben}"; shift

app="$here/TagExplosion.app"
[ -d "$app" ] || { echo "App fehlt — erst ./build.sh" >&2; exit 1; }

# App mit optionalen Dateien starten
if [ "$#" -gt 0 ]; then
    open -a "$app" "$@"
else
    open -a "$app"
fi
sleep 3

# Fenster-Region ermitteln, aktivieren, screenshotten, App beenden
swift - "$out" <<'SW'
import AppKit
import CoreGraphics
import Foundation

let out = CommandLine.arguments[1]
let appName = "Tag Explosion" // kCGWindowOwnerName = CFBundleName (mit Leerzeichen)

guard let running = NSRunningApplication
    .runningApplications(withBundleIdentifier: "io.github.danielmuellerir.tagexplosion").first
else { print("App läuft nicht"); exit(1) }

// Beendet die Test-App und wartet auf ihr tatsächliches Ende — erst höflich
// (terminate), nach Ablauf der Frist hart (forceTerminate). Erfolgs- UND
// Fehlerpfad laufen hierüber: Ein bloß angefordertes terminate ohne Warten
// ließe die App nach einem frühen Fehler sichtbar weiterlaufen.
func shutDownApp() -> Bool {
    func waitForExit(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !running.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return running.isTerminated
    }
    _ = running.terminate()
    if waitForExit(seconds: 5) { return true }
    _ = running.forceTerminate()
    return waitForExit(seconds: 5)
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

guard running.activate() else { fail("App konnte nicht aktiviert werden") }
Thread.sleep(forTimeInterval: 1.0)

guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
else { fail("Fensterliste konnte nicht gelesen werden") }

var best: (bounds: CGRect, area: CGFloat) = (.zero, 0)
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "") == appName {
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

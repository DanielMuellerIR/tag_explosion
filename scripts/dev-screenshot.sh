#!/bin/sh
# Auto-beendender GUI-Selbsttest: startet eine EIGENE TagExplosion-Instanz mit
# Testdateien, holt ihr Fenster kurz nach vorn, macht einen Region-Screenshot
# und beendet sie sofort wieder (das Fenster blitzt nur kurz auf).
#
# Aufruf: scripts/dev-screenshot.sh <ausgabe.png> [datei-oder-ordner ...]
#
# Start, Besitzverfolgung, Signalbehandlung und Beenden liegen in
# scripts/lib/gui-testkit.swift und sind für alle drei GUI-Selbsttests
# dieselben. Vorher startete die Shell die App per `open -a`, wartete drei
# Sekunden und griff danach die ERSTE laufende App mit dieser Bundle-ID: Lief
# schon eine produktiv benutzte Instanz, beendete der Selbsttest die falsche —
# mitsamt ungesicherter Aenderungen (Review-Fund 2026-08-17).
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:?Ausgabe-PNG angeben}"; shift

app="$here/TagExplosion.app"
[ -d "$app" ] || { echo "App fehlt — erst ./build.sh" >&2; exit 1; }

# Der Testkit erwartet <app> <ausgabeordner>; das Ziel-PNG kommt als eigenes
# Argument dahinter, damit ein voller Pfad moeglich bleibt.
outdir="$(dirname "$out")"

{
    cat "$here/scripts/lib/gui-testkit.swift"
    cat <<'SW'

// ---- Rumpf: Fenster fotografieren --------------------------------------------

let target = URL(fileURLWithPath: testArguments[0])
let documents = testArguments.dropFirst().map { URL(fileURLWithPath: $0) }

func fail(_ message: String) -> Never {
    let stopped = shutDownOwnedInstances()
    FileHandle.standardError.write(Data("FEHLER: \(message)\n".utf8))
    if !stopped {
        FileHandle.standardError.write(
            Data("FEHLER: Test-App ließ sich nicht beenden — bitte von Hand schließen.\n".utf8))
    }
    exit(1)
}

guard let running = launchTestInstance(documents: documents) else {
    // Sicherheitsnetz gegen einen verspaeteten Start ohne Rueckmeldung.
    shutDownOwnedInstances(followUpFor: 8)
    kitFail("Test-Instanz startete nicht.")
}
// Ab hier gilt: Auf JEDEM Weg aus diesem Programm wird genau diese Instanz
// beendet — sie gehoert uns, niemandem sonst.
let testPID = running.processIdentifier

// Fenster brauchen einen Moment, bis sie auf dem Bildschirm sind.
Thread.sleep(forTimeInterval: 3.0)
guard running.activate() else { fail("App konnte nicht aktiviert werden") }
Thread.sleep(forTimeInterval: 1.0)

if let problem = captureWindow(of: testPID, to: target) { fail(problem) }

// Sofort beenden — Signal "fertig mit dem Bildschirm"
guard shutDownOwnedInstances() else {
    FileHandle.standardError.write(
        Data("FEHLER: App beendete sich auch nach forceTerminate nicht.\n".utf8))
    exit(1)
}
print("OK \(target.path)")
SW
} | swift - "$app" "$outdir" "$out" "$@"

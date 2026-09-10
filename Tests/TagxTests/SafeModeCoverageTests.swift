// CLI-Regression: Jeder Befehl, der eine vorhandene Datei ersetzen kann, muss
// den abgesicherten Modus kennen. `SafeModeOptions.apply()` ist die einzige
// Stelle, die ihn einschaltet — fehlt die Optionsgruppe, bleibt jede Sicherung
// im Schreibweg still wirkungslos, und `--no-backup` fehlt in der Hilfe.
// Genau so lag es beim Playlist- und beim Archiv-Export (Review-Fund
// 2026-09-10). Geprüft wird die Verdrahtung, nicht die Papierkorb-Kopie selbst:
// Tests lassen den Modus bewusst aus, damit sie nichts in den Papierkorb legen.
import Foundation
import TagExplosionTestSupport
import Testing

@Suite("tagx abgesicherter Modus")
struct SafeModeCoverageTests {

    /// Ersetzende Befehle mit ihrem Unterbefehlspfad. `rename` fehlt bewusst:
    /// Es benennt nur um und bricht bei einem schon vorhandenen Ziel als
    /// Konflikt ab, ersetzt also nie einen Inhalt.
    private static let replacingCommands: [[String]] = [
        ["set"], ["exif", "set"], ["ebook", "set"], ["doc", "set"], ["nfo", "set"],
        ["subtitle", "set"], ["chapters", "set"], ["lyrics", "set"], ["layers", "strip"],
        ["playlist", "set"], ["playlist", "export"], ["cue", "apply"],
        ["apply"], ["parse"], ["import"], ["export"],
        ["cover", "set"], ["cover", "from-folder"], ["cover", "to-folder"],
        ["history", "restore"], ["lookup"],
    ]

    @Test("Jeder ersetzende Befehl kennt --no-backup", arguments: replacingCommands)
    func replacingCommandsOfferNoBackup(command: [String]) throws {
        let help = try runTagx(arguments: command + ["--help"])
        #expect(help.status == 0, Comment(rawValue: help.stderr))
        #expect(help.stdout.contains("--no-backup"),
                Comment(rawValue: "tagx \(command.joined(separator: " ")) bietet --no-backup nicht an"))
    }
}

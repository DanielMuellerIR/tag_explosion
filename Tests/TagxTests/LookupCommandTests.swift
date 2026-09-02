// CLI-Regressionen für `tagx lookup` ohne Netz: Verweigerung ohne
// TAGX_ONLINE (Exit 1 mit Hinweis, bevor irgendetwas gelesen wird),
// Datenschutztext, Argumentprüfung.
import Foundation
import Testing

@Suite("tagx lookup", .serialized)
struct LookupCommandTests {

    @Test("Ohne TAGX_ONLINE: Exit 1 mit Hinweis, auch bei nicht existierender Datei")
    func refusesWithoutConsent() throws {
        let result = try runTagx(arguments: ["lookup", "/nirgends/datei.mp3"], environment: ["TAGX_ONLINE": ""])
        #expect(result.status == 1)
        #expect(result.stderr.contains("Online services are disabled"))
        #expect(result.stderr.contains("TAGX_ONLINE=1"))
        #expect(result.stdout.isEmpty)
    }

    @Test("--privacy druckt beide Hinweise ohne Datei und ohne Freigabe")
    func privacyNotice() throws {
        let result = try runTagx(arguments: ["lookup", "--privacy"], environment: ["TAGX_ONLINE": ""])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("musicbrainz.org"))
        #expect(result.stdout.contains("api.acoustid.org"))
        #expect(result.stdout.contains("Beim Nachschlagen"))
    }

    @Test("Argumentfehler: keine Datei, unbekannte Quelle, --choose 0")
    func usageErrors() throws {
        let noFile = try runTagx(arguments: ["lookup"], environment: ["TAGX_ONLINE": "1"])
        #expect(noFile.status == 64 && noFile.stderr.contains("at least one media file"))
        let badSource = try runTagx(arguments: ["lookup", "--source", "spotify", "x.mp3"], environment: ["TAGX_ONLINE": "1"])
        #expect(badSource.status == 64)
        let badChoice = try runTagx(arguments: ["lookup", "--choose", "0", "x.mp3"], environment: ["TAGX_ONLINE": "1"])
        #expect(badChoice.status == 64 && badChoice.stderr.contains("--choose"))
    }

    /// Baut das CLI-Produkt und startet es mit angepasster Umgebung.
    private func runTagx(arguments: [String], environment: [String: String]) throws -> CapturedProcessResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // Über /usr/bin/env laufen die Variablen als Argumente mit — der
        // Kindprozess bekommt genau die gewünschte Umgebung.
        let assignments = environment.map { "\($0.key)=\($0.value)" }
        return try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: assignments + [URL(fileURLWithPath: binaryDirectory).appendingPathComponent("tagx").path] + arguments,
            currentDirectory: root
        )
    }
}

// Test-Mediendateien für die CLI-Tests bereitstellen.
//
// `Tests/TagExplosionCoreTests/Fixtures/generated/sample.mp3` ist bewusst nicht
// versioniert (keine echten Mediendateien im Repo, siehe .gitignore) und
// entsteht erst durch `generate_fixtures.sh`. Bisher verließ sich dieses
// Testziel darauf, dass vorher zufällig ein Test des ANDEREN Testziels den
// Generator angestoßen hat — ein gefilterter Lauf auf einem frischen Checkout
// scheiterte deshalb schon beim Kopieren der Fixture. Hier stößt das
// CLI-Testziel den Generator selbst an (idempotent, gleiches Muster wie in den
// App-Tests).
import Foundation

enum TagxFixtures {

    /// Wurzel des Repos, von dieser Datei aus gerechnet.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TagxTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Repo-Wurzel

    /// Verzeichnis mit den erzeugten Fixtures; `nil`, wenn die Erzeugung nicht
    /// möglich war (typischerweise fehlendes ffmpeg).
    static let directory: URL? = {
        let generated = repoRoot
            .appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated")
        let sample = generated.appendingPathComponent("sample.mp3")
        if !FileManager.default.fileExists(atPath: sample.path) {
            let script = repoRoot.appendingPathComponent(
                "Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return FileManager.default.fileExists(atPath: sample.path) ? generated : nil
    }()

    static var isAvailable: Bool { directory != nil }

    enum FixtureError: Error { case notGenerated }

    /// Pfad einer erzeugten Fixture (die Datei selbst bleibt unangetastet —
    /// Tests kopieren sie sich an ihren eigenen Arbeitsort).
    static func url(_ name: String) throws -> URL {
        guard let directory else { throw FixtureError.notGenerated }
        return directory.appendingPathComponent(name)
    }
}

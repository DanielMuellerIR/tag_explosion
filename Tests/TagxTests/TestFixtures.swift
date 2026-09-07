// Medien-Fixtures für CLI-Tests; gemeinsame Erzeugung im Test-Support-Target.
import Foundation
import TagExplosionTestSupport

enum TagxFixtures {

    /// Wurzel des Repos, von dieser Datei aus gerechnet.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TagxTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Repo-Wurzel

    /// Das kleine Bild ist getrackt und braucht weder die Audio-Fixtures noch
    /// ffmpeg. Bild-CLI-Tests dürfen deshalb direkt darauf zugreifen.
    static let trackedCover = repoRoot
        .appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated/cover.jpg")

    static var trackedCoverIsAvailable: Bool {
        FileManager.default.fileExists(atPath: trackedCover.path)
    }

    /// Verzeichnis mit den erzeugten Fixtures; `nil`, wenn die Erzeugung nicht
    /// möglich war (typischerweise fehlendes ffmpeg).
    static var directory: URL? { MediaTestFixtures.availableDirectory }

    static var isAvailable: Bool { directory != nil }

    enum FixtureError: Error { case notGenerated }

    /// Pfad einer erzeugten Fixture (die Datei selbst bleibt unangetastet —
    /// Tests kopieren sie sich an ihren eigenen Arbeitsort).
    static func url(_ name: String) throws -> URL {
        guard let directory else { throw FixtureError.notGenerated }
        return directory.appendingPathComponent(name)
    }
}

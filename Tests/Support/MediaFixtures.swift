import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Ein Fixture-Aufbau je Testprozess; die Dateisperre koordiniert zusätzlich
/// gleichzeitig gestartete Core-, CLI- und App-Testprozesse.
public enum MediaTestFixtures {
    private static let generated: Result<URL, any Error> = Result {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated")
        return try prepare(directory: folder,
            generator: root.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh"))
    }

    /// Gleicher Einstieg für die Prozess- und Fehlernachweise mit einem kleinen
    /// kontrollierten Generator statt eines zweiten vollständigen Mediensatzes.
    static func prepare(directory folder: URL, generator: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.appendingPathComponent(".generation.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FixtureError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw FixtureError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        let result = try runCapturedProcess(executable: "/bin/sh",
            arguments: [generator.path, folder.path],
            currentDirectory: generator.deletingLastPathComponent(), timeout: 180)
        guard result.status == 0 else {
            throw FixtureError.generationFailed(result.status, result.stderr)
        }
        return folder
    }

    public enum FixtureError: Error {
        case lockUnavailable
        case generationFailed(Int32, String)
    }

    public static func directory() throws -> URL { try generated.get() }
    public static var availableDirectory: URL? { try? directory() }
    public static var isAvailable: Bool { availableDirectory != nil }

    /// Nur die Kopie darf ein Test verändern; ihr Ordner gehört seinem Cleanup.
    public static func workingCopy(_ name: String = "sample.mp3") throws -> URL {
        let source = try directory().appendingPathComponent(name)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

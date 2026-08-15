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

/// Ergebnis eines echten Unterprozesses in den CLI-Regressionen.
struct CapturedProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Thread-sicherer Übergabepuffer zwischen den beiden Pipe-Lesern und dem
/// aufrufenden Testthread.
private final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func store(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func load() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Startet einen Prozess und leert stdout und stderr gleichzeitig.
///
/// Nacheinander gelesene Pipes können sich verklemmen: Das Kind wartet dann
/// auf Platz in stderr, während der Elternprozess noch auf EOF in stdout
/// wartet. Zwei Leser verhindern diesen klassischen Pipe-Deadlock.
func runCapturedProcess(
    executable: String,
    arguments: [String],
    currentDirectory: URL
) throws -> CapturedProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    let outputData = CapturedData()
    let errorData = CapturedData()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        outputData.store(stdout.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        errorData.store(stderr.fileHandleForReading.readDataToEndOfFile())
        readers.leave()
    }

    process.waitUntilExit()
    readers.wait()
    return CapturedProcessResult(
        status: process.terminationStatus,
        stdout: String(decoding: outputData.load(), as: UTF8.self),
        stderr: String(decoding: errorData.load(), as: UTF8.self)
    )
}

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

import Foundation

/// App-Tests müssen auch ohne einen vorherigen Core-Testlauf funktionieren.
/// Der bestehende Generator erzeugt ausschließlich synthetische Medien.
enum AppTestFixtures {
    static let directory: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh").path]
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { preconditionFailure("Fixture-Generator: \(error)") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Fixture-Generator fehlgeschlagen")
        return URL(fileURLWithPath: String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }()
}

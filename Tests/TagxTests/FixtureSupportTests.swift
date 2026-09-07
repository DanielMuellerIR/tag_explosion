import Foundation
import Testing
@testable import TagExplosionTestSupport

@Suite("Gemeinsame Fixture-Erzeugung")
struct FixtureSupportTests {
    @Test("Fehlende Archivvarianten werden ergänzt, vorhandene Fixtures bleiben bytegleich",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/zip"), "zip nicht verfügbar"))
    func repairsMissingVariants() throws {
        let originals = try MediaTestFixtures.directory()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-fixture-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: originals, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let variants = ["doc-nocore.docx", "comic-noinfo.cbz"]
        for name in variants { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        let originalNames = ["doc.docx", "comic.cbz"]
        let before = try originalNames.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let script = originals.deletingLastPathComponent().appendingPathComponent("generate_fixtures.sh")
        let result = try runCapturedProcess(executable: "/bin/sh", arguments: [script.path, root.path],
            currentDirectory: root)
        #expect(result.status == 0, "\(result.stderr)")
        for name in variants {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)).count > 0)
        }
        let after = try originalNames.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        #expect(after == before)
    }

    @Test("Parallele Erzeuger teilen das Ziel ohne überlappende Mutation")
    func concurrentGeneration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-fixture-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("generate.sh")
        try Data("""
        set -eu
        mkdir "$1/running"
        sleep 0.05
        printf 'generated\\n' >> "$1/calls"
        rmdir "$1/running"
        """.utf8).write(to: script)
        let output = root.appendingPathComponent("output")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { _ = try MediaTestFixtures.prepare(directory: output, generator: script) }
            }
            try await group.waitForAll()
        }
        let calls = try String(contentsOf: output.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == String(repeating: "generated\n", count: 3))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("running").path))
    }

    @Test("Generatorfehler behalten Exit-Code und Diagnose")
    func generationFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-fixture-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("generate.sh")
        try Data("printf 'kaputter Generator' >&2; exit 23".utf8).write(to: script)
        do {
            _ = try MediaTestFixtures.prepare(directory: root.appendingPathComponent("output"), generator: script)
            Issue.record("Generatorfehler wurde verschluckt")
        } catch MediaTestFixtures.FixtureError.generationFailed(let status, let message) {
            #expect(status == 23)
            #expect(message == "kaputter Generator")
        }
    }
}

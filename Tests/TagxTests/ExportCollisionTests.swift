// CLI-Regression: Ein Export darf weder die Eingabedatei noch eine andere
// Verknüpfung auf dieselbe Datei öffnen. Die Byte-Prüfung misst dabei das
// sichtbare Ergebnis statt nur die interne Kollisions-Hilfsfunktion.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx export Zielkollision", .serialized)
struct ExportCollisionTests {

    @Test("Kanonischer Pfad, Symlink und Hardlink brechen vor dem Lesen ab")
    func exportRejectsEveryAliasOfInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-export-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.mp3")
        let original = Data("Diese Bytes dürfen nie ein JSON-Archiv werden.".utf8)
        try original.write(to: input)

        // standardisiert denselben Pfad, obwohl der Text anders aussieht.
        try assertRejected(input: input,
                           output: directory.appendingPathComponent("unterordner/../input.mp3"),
                           original: original)

        let symlink = directory.appendingPathComponent("ziel-symlink.json")
        try FileManager.default.createSymbolicLink(atPath: symlink.path,
                                                   withDestinationPath: input.path)
        try assertRejected(input: input, output: symlink, original: original)

        let hardlink = directory.appendingPathComponent("ziel-hardlink.json")
        try FileManager.default.linkItem(at: input, to: hardlink)
        try assertRejected(input: input, output: hardlink, original: original)
    }

    @Test("Ungültige Bewertung wird abgelehnt statt als Löschwunsch behandelt")
    func invalidRatingDoesNotDeleteExistingRating() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-rating-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = directory.appendingPathComponent("image.jpg")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(
                "Tests/TagExplosionCoreTests/Fixtures/generated/cover.jpg"),
            to: image)

        #expect(try runTagx(arguments: ["exif", "set", image.path,
                                        "--rating", "5"]).status == 0)
        let bytesBefore = try Data(contentsOf: image)
        for invalid in ["4x", "-1", "6"] {
            let result = try runTagx(arguments: [
                "exif", "set", image.path, "--rating=\(invalid)",
            ])
            #expect(result.status != 0)
            #expect(result.stderr.contains("integer from 0 to 5"))
            #expect(try Data(contentsOf: image) == bytesBefore)
        }
    }

    @Test("Externe Importziele brauchen den Schalter und werden vollständig ausgegeben")
    func externalImportRequiresFlagAndPrintsAllTargets() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-cli-external-import-\(UUID().uuidString)")
        let base = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent(
            "Tests/TagExplosionCoreTests/Fixtures/generated/sample.mp3")
        let inside = base.appendingPathComponent("inside.mp3")
        let outside = parent.appendingPathComponent("outside.mp3")
        try FileManager.default.copyItem(at: fixture, to: inside)
        try FileManager.default.copyItem(at: fixture, to: outside)

        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "inside.mp3", kind: .audio, properties: [:]),
            .init(path: "../outside.mp3", kind: .audio, properties: [:]),
        ])
        let json = base.appendingPathComponent("tags.json")
        try JSONEncoder().encode(archive).write(to: json)

        let rejected = try runTagx(arguments: ["import", "--dry-run", json.path])
        #expect(rejected.status != 0)
        #expect(rejected.stderr.contains("Explicit approval is required"))

        let allowed = try runTagx(arguments: [
            "import", "--dry-run", "--allow-external-targets", json.path,
        ])
        #expect(allowed.status == 0)
        #expect(allowed.stderr.contains("Resolved import targets:"))
        #expect(allowed.stderr.contains(inside.path))
        #expect(allowed.stderr.contains(outside.path))
    }

    private func assertRejected(input: URL, output: URL, original: Data) throws {
        let result = try runTagx(arguments: ["export", input.path, "--output", output.path])
        #expect(result.status != 0, "Export auf \(output.lastPathComponent) muss fehlschlagen")
        #expect(result.stderr.contains("matches input media file"))
        #expect(try Data(contentsOf: input) == original,
                "Die Eingabedatei wurde trotz abgelehntem Export verändert")
    }

    /// Baut das CLI-Produkt einmal über SwiftPM und startet anschließend genau
    /// das entstandene Binary. Dadurch prüft der Test auch ArgumentParser und
    /// seinen nicht-null Exit-Code statt nur eine Swift-Methode.
    private func runTagx(arguments: [String]) throws -> (status: Int32, stderr: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try runProcess(
            executable: URL(fileURLWithPath: binaryDirectory)
                .appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
        return (result.status, result.stderr)
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL) throws
    -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self))
    }
}

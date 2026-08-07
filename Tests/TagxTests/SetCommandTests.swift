// CLI-Regression: `tagx set` schreibt nur, wenn sich wirklich etwas ändert.
// Ein semantischer No-op (Sollwerte == Dateizustand) darf weder die Datei neu
// aufbauen (neue Inode/mtime, unnötige Sicherung) noch "geänderte" Felder
// melden.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx set No-op", .serialized)
struct SetCommandTests {

    @Test("Unveränderte Sollwerte lassen die Datei byte-gleich und melden 0 Felder",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func noopSetDoesNotRewriteFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-set-noop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)

        // Erster Lauf setzt den Wert wirklich (genau ein geändertes Feld).
        let first = try runTagx(arguments: [
            "set", file.path, "--no-backup", "-t", "TITLE=Gleichbleibend",
        ])
        #expect(first.status == 0)
        #expect(first.stdout.contains("1 field(s) changed"))
        let bytesAfterFirst = try Data(contentsOf: file)
        let stampAfterFirst = try #require(FileStamp.current(of: file))

        // Zweiter, identischer Lauf: nichts ändert sich — Datei bleibt
        // byte-gleich, gleiche Identität, und die Meldung nennt 0 Felder.
        let second = try runTagx(arguments: [
            "set", file.path, "--no-backup", "-t", "TITLE=Gleichbleibend",
        ])
        #expect(second.status == 0)
        #expect(second.stdout.contains("0 field(s) changed"))
        #expect(try Data(contentsOf: file) == bytesAfterFirst)
        #expect(FileStamp.current(of: file) == stampAfterFirst)

        // Mischfall: ein Feld ändert sich wirklich, das andere nicht — die
        // Meldung zählt nur die echte Änderung.
        let mixed = try runTagx(arguments: [
            "set", file.path, "--no-backup",
            "-t", "TITLE=Gleichbleibend", "ARTIST=Neu dazu",
        ])
        #expect(mixed.status == 0)
        #expect(mixed.stdout.contains("1 field(s) changed"))
    }

    /// Baut das CLI-Produkt über SwiftPM und startet genau das entstandene
    /// Binary (gleiches Muster wie in ExportCollisionTests).
    private func runTagx(arguments: [String]) throws
    -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try runProcess(
            executable: URL(fileURLWithPath: binaryDirectory)
                .appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
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

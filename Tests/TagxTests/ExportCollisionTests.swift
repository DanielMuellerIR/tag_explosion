// CLI-Regression: Ein Export darf weder die Eingabedatei noch eine andere
// Verknüpfung auf dieselbe Datei öffnen. Die Byte-Prüfung misst dabei das
// sichtbare Ergebnis statt nur die interne Kollisions-Hilfsfunktion.
import Foundation
import Testing

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

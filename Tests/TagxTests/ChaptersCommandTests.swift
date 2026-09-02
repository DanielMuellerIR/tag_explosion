// Echte CLI-Regressionen für `tagx chapters`: Text- und JSON-Ausgabe, Import
// aus Text/JSON/stdin, No-op ohne Dateiänderung, Entfernen, Exit-Codes bei
// Formaten ohne Kapitel und bei unstimmigen Listen.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx chapters", .serialized)
struct ChaptersCommandTests {

    @Test("set/show/clear im Textformat, JSON-Ausgabe ist wieder importierbar",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func setShowClearRoundtrip() throws {
        let directory = try makeWorkDirectory("tagx-chapters")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("buch.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let list = directory.appendingPathComponent("kapitel.txt")
        try Data("""
        00:00:00.000 Einleitung
        00:00:00.800 Kapitel 1 — Ümläute
        00:00:01.500 Schluss

        """.utf8).write(to: list)

        let set = try runTagx(arguments: ["chapters", "set", file.path, "--from", list.path, "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(set.stdout.contains("3 chapter(s) written"))

        // Textausgabe entspricht der Import-Form (Beginn + Titel je Zeile).
        let show = try runTagx(arguments: ["chapters", "show", file.path])
        #expect(show.status == 0)
        #expect(show.stdout == "00:00:00.000 Einleitung\n00:00:00.800 Kapitel 1 — Ümläute\n00:00:01.500 Schluss\n")

        // JSON: Umhüllung mit file/supported/chapters; Enden aus dem nächsten Beginn.
        let json = try runTagx(arguments: ["chapters", "show", file.path, "--json"])
        #expect(json.status == 0)
        let report = try JSONDecoder().decode(Report.self, from: Data(json.stdout.utf8))
        #expect(report.supported)
        #expect(report.chapters.map(\.title) == ["Einleitung", "Kapitel 1 — Ümläute", "Schluss"])
        #expect(report.chapters.map(\.startMilliseconds) == [0, 800, 1500])
        #expect(report.chapters[0].endMilliseconds == 800)
        #expect(report.chapters[1].endMilliseconds == 1500)

        // Gleiche Liste noch einmal: No-op, Datei bleibt byte-gleich.
        let bytes = try Data(contentsOf: file)
        let again = try runTagx(arguments: ["chapters", "set", file.path, "--from", list.path, "--no-backup"])
        #expect(again.status == 0)
        #expect(again.stdout.contains("chapters unchanged"))
        #expect(try Data(contentsOf: file) == bytes)

        // Die JSON-Ausgabe lässt sich unverändert wieder einspielen (per stdin
        // testen wir den Dateiweg mit .json-Endung).
        let jsonFile = directory.appendingPathComponent("kapitel.json")
        try Data(json.stdout.utf8).write(to: jsonFile)
        let fromJSON = try runTagx(arguments: ["chapters", "set", file.path, "--from", jsonFile.path, "--no-backup"])
        #expect(fromJSON.status == 0)
        #expect(fromJSON.stdout.contains("chapters unchanged"))

        // `tagx show` listet Kapitel mit.
        let plainShow = try runTagx(arguments: ["show", file.path])
        #expect(plainShow.stdout.contains("CHAPTER: 00:00:00.800–00:00:01.500 Kapitel 1 — Ümläute"))

        let clear = try runTagx(arguments: ["chapters", "clear", file.path, "--no-backup"])
        #expect(clear.status == 0)
        #expect(clear.stdout.contains("chapters removed"))
        #expect(try TagFile.read(at: file).chapters.isEmpty)
        let clearAgain = try runTagx(arguments: ["chapters", "clear", file.path, "--no-backup"])
        #expect(clearAgain.status == 0)
        #expect(clearAgain.stdout.contains("no chapters to remove"))
    }

    @Test("Formate ohne Kapitel: show meldet supported=false, set/clear scheitern mit 64",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func unsupportedFormat() throws {
        let directory = try makeWorkDirectory("tagx-chapters-flac")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.flac"), to: file)
        let before = try Data(contentsOf: file)

        let show = try runTagx(arguments: ["chapters", "show", file.path, "--json"])
        #expect(show.status == 0)
        let report = try JSONDecoder().decode(Report.self, from: Data(show.stdout.utf8))
        #expect(!report.supported)
        #expect(report.chapters.isEmpty)

        let list = directory.appendingPathComponent("kapitel.txt")
        try Data("00:00:00.000 X\n".utf8).write(to: list)
        let set = try runTagx(arguments: ["chapters", "set", file.path, "--from", list.path, "--no-backup"])
        #expect(set.status == 64)
        #expect(set.stderr.contains("not supported"))
        let clear = try runTagx(arguments: ["chapters", "clear", file.path, "--no-backup"])
        #expect(clear.status == 64)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Unstimmige Liste wird abgelehnt, bevor die Datei angefasst wird",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func invalidListIsRejected() throws {
        let directory = try makeWorkDirectory("tagx-chapters-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("buch.m4b")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.m4b"), to: file)
        let before = try Data(contentsOf: file)

        let unsorted = directory.appendingPathComponent("unsortiert.txt")
        try Data("00:00:01.000 B\n00:00:00.000 A\n".utf8).write(to: unsorted)
        let result = try runTagx(arguments: ["chapters", "set", file.path, "--from", unsorted.path, "--no-backup"])
        #expect(result.status == 64)
        #expect(result.stderr.contains("Invalid chapter list"))

        let garbage = directory.appendingPathComponent("kaputt.txt")
        try Data("Intro ohne Zeit\n".utf8).write(to: garbage)
        let garbageResult = try runTagx(arguments: ["chapters", "set", file.path, "--from", garbage.path, "--no-backup"])
        #expect(garbageResult.status == 64)
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: - Helfer

    /// Spiegel der CLI-JSON-Ausgabe (`ChapterReport` ist im CLI-Target privat).
    private struct Report: Decodable {
        var file: String
        var supported: Bool
        var chapters: [Chapter]
    }

    private func makeWorkDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Baut das CLI-Produkt und startet genau das entstandene Binary.
    private func runTagx(arguments: [String]) throws -> CapturedProcessResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return try runCapturedProcess(
            executable: URL(fileURLWithPath: binaryDirectory).appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
    }
}

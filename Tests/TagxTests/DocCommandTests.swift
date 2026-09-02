// CLI-Regressionen für `tagx doc`: JSON-Ausgabe, Setzen inklusive
// Zusatzfeld, Ablehnung eines Felds ohne Speicherort VOR jeder Mutation.
import Foundation
import Testing

@Suite("tagx doc CLI", .serialized)
struct DocCommandTests {

    @Test("show --json, set und Ablehnung nicht speicherbarer Felder",
          .enabled(if: TagxFixtures.isAvailable, "Fixtures fehlen (ffmpeg/zip?)"))
    func showSetAndReject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-doc-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("comic.cbz")
        try FileManager.default.copyItem(at: try TagxFixtures.url("comic.cbz"), to: file)

        let set = try runTagx(arguments: [
            "doc", "set", file.path, "--no-backup", "--title", "Per CLI",
            "--authors", "A, B", "--created", "2022-12", "--custom", "Series=Reihe", "Volume=",
        ])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(set.stdout.contains("OK comic.cbz"))

        let show = try runTagx(arguments: ["doc", "show", file.path, "--json"])
        #expect(show.status == 0, Comment(rawValue: show.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any])
        let core = try #require(json["core"] as? [String: Any])
        #expect(core["title"] as? String == "Per CLI")
        #expect(core["authors"] as? [String] == ["A", "B"])
        #expect(core["created"] as? String == "2022-12")
        let custom = try #require(core["custom"] as? [[String: String]])
        #expect(custom.contains { $0["key"] == "Series" && $0["value"] == "Reihe" })
        #expect(!custom.contains { $0["key"] == "Volume" })
        #expect(json["coverMimeType"] as? String == "image/jpeg")
        #expect((json["supportedFields"] as? [String])?.contains("publisher") == true)

        // Keywords haben in ComicInfo keinen Speicherort: Fehler mit Feldname,
        // Exit-Code ungleich 0, Datei unverändert.
        let bytes = try Data(contentsOf: file)
        let rejected = try runTagx(arguments: [
            "doc", "set", file.path, "--no-backup", "--keywords", "x",
        ])
        #expect(rejected.status != 0)
        #expect(rejected.stderr.contains("keywords"))
        #expect(try Data(contentsOf: file) == bytes)

        // Gleiche Werte noch einmal: kein Schreibvorgang.
        let noop = try runTagx(arguments: ["doc", "set", file.path, "--no-backup", "--title", "Per CLI"])
        #expect(noop.status == 0)
        #expect(noop.stdout.contains("No changes"))
    }

    // MARK: - Prozess-Helfer (gleiches Muster wie die übrigen CLI-Tests)

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

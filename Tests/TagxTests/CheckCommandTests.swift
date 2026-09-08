// CLI-Regression: `tagx check` liest nur, gruppiert nach Album, liefert JSON
// und wechselt den Exit-Code (4) erst mit --fail-on.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore

@Suite("tagx check")
struct CheckCommandTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Zwei Titel eines Albums: Track 1/3 mit Cover, Track 3/3 ohne Cover.
    private func makeAlbum(in directory: URL) throws -> (first: URL, second: URL) {
        let first = directory.appendingPathComponent("01 - Eins.mp3")
        let second = directory.appendingPathComponent("drei.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: first)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: second)
        let common = [TagProperty(key: "ARTIST", value: "Duo"), TagProperty(key: "ALBUM", value: "Album"),
                      TagProperty(key: "ALBUMARTIST", value: "Duo"), TagProperty(key: "DATE", value: "2020")]
        let cover = try Data(contentsOf: TagxFixtures.trackedCover)
        try TagFile.write(properties: common + [TagProperty(key: "TITLE", value: "Eins"),
                                               TagProperty(key: "TRACKNUMBER", value: "1/3")],
                          artworks: [Artwork(data: cover, pictureType: "Front Cover")], to: first)
        try TagFile.write(properties: common + [TagProperty(key: "TITLE", value: "Drei"),
                                               TagProperty(key: "TRACKNUMBER", value: "3/3")],
                          artworks: [], to: second)
        return (first, second)
    }

    @Test("Ordnerlauf: Textbericht je Album, Exit 0 trotz Befunden, Dateien bleiben unverändert",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func folderReportKeepsExitZero() throws {
        let directory = try makeDirectory("check")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (first, second) = try makeAlbum(in: directory)
        let bytesBefore = (try Data(contentsOf: first), try Data(contentsOf: second))

        let result = try runTagx(arguments: ["check", directory.path])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("== Album — Duo (2 file(s))"))
        #expect(result.stdout.contains("WARNING track-gap: Gaps in the track numbering — missing 2"))
        #expect(result.stdout.contains("WARNING missing-cover: No cover art\n    drei.mp3"))
        #expect(result.stdout.contains("2 warning(s), 0 hint(s) in 2 file(s)"))
        #expect(try Data(contentsOf: first) == bytesBefore.0)
        #expect(try Data(contentsOf: second) == bytesBefore.1)
    }

    @Test("--json liefert den Bericht mit Zusammenfassung je Regel und Liste je Datei",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func jsonReport() throws {
        let directory = try makeDirectory("check-json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (_, second) = try makeAlbum(in: directory)

        let result = try runTagx(arguments: ["check", "--json", "-p", "%{track:2} - %{title}", directory.path])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let report = try JSONDecoder().decode(LibraryCheck.Report.self, from: Data(result.stdout.utf8))
        #expect(report.checkedFiles == 2)
        #expect(Set(report.findings.map(\.code)) == [.trackGap, .missingCover, .filenameMismatch])
        #expect(report.summary.map(\.code) == [.missingCover, .trackGap, .filenameMismatch])
        #expect(report.files.first { $0.file == second.path }?.codes
                == [.trackGap, .missingCover, .filenameMismatch])
        #expect(report.findings.first { $0.code == .filenameMismatch }?.message == "expected 03 - Drei.mp3")
    }

    @Test("--fail-on und --only steuern Exit-Code 4; unbekannte Codes sind ein Eingabefehler",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func failOnAndOnly() throws {
        let directory = try makeDirectory("check-fail")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeAlbum(in: directory)

        #expect(try runTagx(arguments: ["check", "--fail-on", "warning", directory.path]).status == 4)
        #expect(try runTagx(arguments: ["check", "--fail-on", "hint", directory.path]).status == 4)
        // Nur eine Hinweis-Regel gefiltert: keine Befunde → auch mit --fail-on Exit 0.
        let onlyHint = try runTagx(arguments: ["check", "--only", "genre-inconsistent", "--fail-on", "hint", directory.path])
        #expect(onlyHint.status == 0, Comment(rawValue: onlyHint.stderr))
        #expect(onlyHint.stdout.contains("No findings in 2 file(s)"))
        // Nur die Cover-Regel: genau ein Befund.
        let onlyCover = try runTagx(arguments: ["check", "--json", "--only", "missing-cover,track-gap", directory.path])
        let report = try JSONDecoder().decode(LibraryCheck.Report.self, from: Data(onlyCover.stdout.utf8))
        #expect(report.findings.map(\.code) == [.trackGap, .missingCover])

        let unknown = try runTagx(arguments: ["check", "--only", "nonsense", directory.path])
        #expect(unknown.status == 64)
        #expect(unknown.stderr.contains("Unknown rule code: nonsense"))
        let badLevel = try runTagx(arguments: ["check", "--fail-on", "error", directory.path])
        #expect(badLevel.status == 64)
    }


}

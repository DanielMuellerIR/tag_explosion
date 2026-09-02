// CLI-Regressionen für `tagx nfo` und `tagx subtitle`: JSON-Ausgabe, Setzen
// über den Video-Pfad, Ablehnung einer Nur-URL-NFO, VTT-Kopf und
// Zeitverschiebung mit byteweisem Roundtrip.
import Foundation
import Testing

@Suite("tagx nfo/subtitle CLI", .serialized)
struct SidecarCommandTests {

    private func makeDir() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-sidecar-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("nfo show --json, set über den Videonamen, Nur-URL abgelehnt")
    func nfoShowAndSet() throws {
        let directory = try makeDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nfo = directory.appendingPathComponent("film.nfo")
        try "<movie>\n    <title>Alt</title>\n    <year>2001</year>\n    <custom>bleibt</custom>\n</movie>\n"
            .write(to: nfo, atomically: true, encoding: .utf8)
        // Ein leeres „Video" genügt für die Pfadauflösung film.mkv → film.nfo.
        let video = directory.appendingPathComponent("film.mkv")
        try Data().write(to: video)

        let set = try runTagx(arguments: [
            "nfo", "set", video.path, "--no-backup", "--title", "Neu", "--genre", "Drama, Krimi",
        ])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(set.stdout.contains("OK film.nfo"))
        #expect(try String(contentsOf: nfo, encoding: .utf8)
            == "<movie>\n    <title>Neu</title>\n    <year>2001</year>\n    <custom>bleibt</custom>\n"
            + "    <genre>Drama</genre>\n    <genre>Krimi</genre>\n</movie>\n")

        let show = try runTagx(arguments: ["nfo", "show", nfo.path, "--json"])
        #expect(show.status == 0, Comment(rawValue: show.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any])
        let fields = try #require(json["fields"] as? [String: Any])
        #expect(fields["title"] as? String == "Neu")
        #expect(fields["genres"] as? [String] == ["Drama", "Krimi"])
        #expect(json["type"] as? String == "movie")
        #expect((json["video"] as? String)?.hasSuffix("film.mkv") == true)

        let badYear = try runTagx(arguments: ["nfo", "set", nfo.path, "--no-backup", "--year", "abc"])
        #expect(badYear.status != 0)
        #expect(badYear.stderr.contains("year"))

        let urlOnly = directory.appendingPathComponent("serie.nfo")
        try "https://www.thetvdb.com/series/1\n".write(to: urlOnly, atomically: true, encoding: .utf8)
        let rejected = try runTagx(arguments: ["nfo", "set", urlOnly.path, "--no-backup", "--title", "x"])
        #expect(rejected.status != 0)
        #expect(rejected.stderr.contains("only URLs"))
        let shown = try runTagx(arguments: ["nfo", "show", urlOnly.path, "--json"])
        #expect(shown.status == 0)
        #expect(shown.stdout.contains("\"urlOnly\" : true"))
    }

    @Test("subtitle show, set (VTT-Kopf) und shift mit Roundtrip")
    func subtitleShowSetShift() throws {
        let directory = try makeDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let srt = directory.appendingPathComponent("film.de.forced.srt")
        let srtText = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHallo\r\n\r\n2\r\n00:00:05,000 --> 00:00:06,000\r\nWelt\r\n"
        try srtText.write(to: srt, atomically: true, encoding: .utf8)

        let show = try runTagx(arguments: ["subtitle", "show", srt.path, "--json"])
        #expect(show.status == 0, Comment(rawValue: show.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any])
        let info = try #require(json["info"] as? [String: Any])
        #expect(info["cueCount"] as? Int == 2)
        #expect(info["languageFromName"] as? String == "de")
        #expect(info["flagsFromName"] as? [String] == ["forced"])
        #expect(info["lineEndings"] as? String == "CRLF")
        #expect(info["spanMilliseconds"] as? Int == 5000)

        let shifted = try runTagx(arguments: ["subtitle", "shift", srt.path, "--no-backup", "--seconds", "1.5"])
        #expect(shifted.status == 0, Comment(rawValue: shifted.stderr))
        #expect(try String(contentsOf: srt, encoding: .utf8).contains("00:00:02,500 --> 00:00:03,500"))
        let back = try runTagx(arguments: ["subtitle", "shift", srt.path, "--no-backup", "--seconds=-1.5"])
        #expect(back.status == 0, Comment(rawValue: back.stderr))
        #expect(try String(contentsOf: srt, encoding: .utf8) == srtText)
        let tooFar = try runTagx(arguments: ["subtitle", "shift", srt.path, "--no-backup", "--seconds=-2"])
        #expect(tooFar.status != 0)
        #expect(try String(contentsOf: srt, encoding: .utf8) == srtText)

        // SRT: kein Kopf, Setzen abgelehnt.
        let srtSet = try runTagx(arguments: ["subtitle", "set", srt.path, "--no-backup", "--language", "de"])
        #expect(srtSet.status != 0)

        let vtt = directory.appendingPathComponent("film.vtt")
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nHallo\n".write(to: vtt, atomically: true, encoding: .utf8)
        let vttSet = try runTagx(arguments: [
            "subtitle", "set", vtt.path, "--no-backup", "--title", "Titel", "--language", "de",
        ])
        #expect(vttSet.status == 0, Comment(rawValue: vttSet.stderr))
        #expect(try String(contentsOf: vtt, encoding: .utf8) == "WEBVTT Titel\nLanguage: de\n\n00:01.000 --> 00:02.000\nHallo\n")
        let vttShow = try runTagx(arguments: ["subtitle", "show", vtt.path])
        #expect(vttShow.stdout.contains("TITLE=Titel"))
        #expect(vttShow.stdout.contains("HEADER=Language: de"))
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

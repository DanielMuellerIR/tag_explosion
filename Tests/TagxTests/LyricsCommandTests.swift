// Echte CLI-Regressionen für `tagx lyrics` und die Wertprüfung in `tagx set`:
// LRC-Import in SYLT (MP3) und in die Sidecar (FLAC), JSON-Ausgabe, Export,
// Entfernen, Exit 1 mit Feldname bei ungültigen Lautheitswerten — die Datei
// bleibt dabei byteweise unverändert.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx lyrics", .serialized)
struct LyricsCommandTests {

    private let lrc = """
    [ar:Testkapelle]
    [00:00.00][00:01.50]Refrain
    [00:00.80]Strophe — Ümläute

    """

    @Test("MP3: LRC → SYLT + Text + Sprache, show, export, clear",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func mp3SyncedRoundtrip() throws {
        let directory = try makeWorkDirectory("tagx-lyrics-mp3")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let input = directory.appendingPathComponent("text.lrc")
        try Data(lrc.utf8).write(to: input)

        let set = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path,
                                          "--language", "deu", "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(set.stdout.contains("3 synchronized line(s) (SYLT)"))

        let json = try runTagx(arguments: ["lyrics", "show", file.path, "--json"])
        #expect(json.status == 0)
        let report = try JSONDecoder().decode(Report.self, from: Data(json.stdout.utf8))
        #expect(report.language == "deu")
        #expect(report.supportsSynced)
        #expect(report.syncedSource == "embedded")
        #expect(report.synced.map(\.milliseconds) == [0, 800, 1500])
        #expect(report.synced.map(\.text) == ["Refrain", "Strophe — Ümläute", "Refrain"])
        // Ohne eigenen Text füllt die LRC-Datei auch die unsynchronisierten Lyrics.
        #expect(report.lyrics == "Refrain\nStrophe — Ümläute\nRefrain")

        // --lrc gibt das Austauschformat wieder aus; gleiche Datei erneut = unverändert.
        let show = try runTagx(arguments: ["lyrics", "show", file.path, "--lrc"])
        #expect(show.stdout == "[00:00.00]Refrain\n[00:00.80]Strophe — Ümläute\n[00:01.50]Refrain\n")
        let bytes = try Data(contentsOf: file)
        let again = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path, "--no-backup"])
        #expect(again.status == 0)
        #expect(again.stdout.contains("unchanged"))
        #expect(try Data(contentsOf: file) == bytes)

        // Reiner Text ersetzt nur die unsynchronisierten Lyrics.
        let text = try runTagx(arguments: ["lyrics", "set", file.path, "--text", "Nur Text", "--no-backup"])
        #expect(text.status == 0)
        let after = try TagFile.read(at: file)
        #expect(after.firstValue(for: "LYRICS") == "Nur Text")
        #expect(after.syncedLyrics.count == 3)
        #expect(after.lyricsLanguage == "deu")

        // `tagx show` zeigt Sprache und SYLT-Zeilen.
        let plain = try runTagx(arguments: ["show", file.path])
        #expect(plain.stdout.contains("LYRICS-LANGUAGE: deu"))
        #expect(plain.stdout.contains("SYNCED: [00:00.80] Strophe — Ümläute"))

        // Export schreibt LRC neben die Datei und überschreibt nie.
        let export = try runTagx(arguments: ["lyrics", "export", file.path])
        #expect(export.status == 0)
        let exported = directory.appendingPathComponent("song.lrc")
        #expect(export.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == exported.path)
        #expect(try String(contentsOf: exported, encoding: .utf8) == show.stdout)
        let exportAgain = try runTagx(arguments: ["lyrics", "export", file.path])
        #expect(exportAgain.status == 64)
        #expect(exportAgain.stderr.contains("already exists"))

        // Ungültige Sprache: Exit 1, nichts geschrieben.
        let before = try Data(contentsOf: file)
        let badLanguage = try runTagx(arguments: ["lyrics", "set", file.path, "--language", "de", "--no-backup"])
        #expect(badLanguage.status == 1)
        #expect(badLanguage.stderr.contains("language"))
        #expect(try Data(contentsOf: file) == before)

        let clear = try runTagx(arguments: ["lyrics", "clear", file.path, "--no-backup"])
        #expect(clear.status == 0)
        let cleared = try TagFile.read(at: file)
        #expect(cleared.firstValue(for: "LYRICS") == nil)
        #expect(cleared.syncedLyrics.isEmpty)
    }

    @Test("FLAC: LRC landet in der Sidecar <name>.lrc, SYLT wird ehrlich abgelehnt",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func flacSidecar() throws {
        let directory = try makeWorkDirectory("tagx-lyrics-flac")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.flac"), to: file)
        let input = directory.appendingPathComponent("text.lrc")
        try Data(lrc.utf8).write(to: input)
        let sidecar = directory.appendingPathComponent("song.lrc")

        let set = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path,
                                          "--language", "deu", "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(set.stdout.contains("→ song.lrc"))
        #expect(set.stderr.contains("no lyrics language"))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try TagFile.read(at: file).syncedLyrics.isEmpty)

        let json = try runTagx(arguments: ["lyrics", "show", file.path, "--json"])
        let report = try JSONDecoder().decode(Report.self, from: Data(json.stdout.utf8))
        #expect(!report.supportsSynced)
        #expect(report.syncedSource == "sidecar")
        #expect(report.sidecar == sidecar.path)
        #expect(report.synced.count == 3)

        // Gleiche Datei noch einmal: Sidecar bleibt unangetastet.
        let stamp = FileStamp.current(of: sidecar)
        let again = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path, "--no-backup"])
        #expect(again.stdout.contains("sidecar unchanged"))
        #expect(FileStamp.current(of: sidecar) == stamp)

        let clear = try runTagx(arguments: ["lyrics", "clear", file.path, "--no-backup"])
        #expect(clear.status == 0)
        #expect(clear.stdout.contains("sidecar removed"))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("tagx set: ungültige Lautheits-/Podcast-Werte → Exit 1 mit Feldname, Datei unverändert",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func setRejectsInvalidValues() throws {
        let directory = try makeWorkDirectory("tagx-set-fixed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.opus")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.opus"), to: file)
        let before = try Data(contentsOf: file)

        for assignment in ["REPLAYGAIN_TRACK_GAIN=-61 dB", "REPLAYGAIN_ALBUM_PEAK=12", "R128_TRACK_GAIN=40000",
                           "TVSEASON=zwei", "PODCAST=vielleicht"] {
            let result = try runTagx(arguments: ["set", file.path, "--no-backup", "-t", assignment])
            #expect(result.status == 1, Comment(rawValue: assignment))
            let field = assignment.split(separator: "=")[0]
            #expect(result.stderr.contains("Invalid value for \(field)"), Comment(rawValue: result.stderr))
        }
        #expect(try Data(contentsOf: file) == before)

        // Gültige Werte werden in die Speicherform gebracht; R128 zeigt dB daneben.
        let ok = try runTagx(arguments: ["set", file.path, "--no-backup", "-t",
                                         "REPLAYGAIN_TRACK_GAIN=-6,5", "R128_TRACK_GAIN=-1664", "PODCAST=0"])
        #expect(ok.status == 0, Comment(rawValue: ok.stderr))
        #expect(ok.stdout.contains("2 field(s) changed"))
        let show = try runTagx(arguments: ["show", file.path])
        #expect(show.stdout.contains("REPLAYGAIN_TRACK_GAIN=-6.50 dB"))
        #expect(show.stdout.contains("R128_TRACK_GAIN=-1664\n# R128_TRACK_GAIN = -6.50 dB"))
        #expect(!show.stdout.contains("PODCAST="))
    }

    // MARK: - Helfer

    private struct Report: Decodable {
        var lyrics: String
        var language: String
        var supportsSynced: Bool
        var synced: [SyncedLyricLine]
        var syncedSource: String?
        var sidecar: String?
    }

    private func makeWorkDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

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


    @Test("MP3 mit --sidecar: show/export/clear sehen die Sidecar; neben vorhandenem SYLT wird sie abgelehnt",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func forcedSidecarIsVisibleEverywhere() throws {
        let directory = try makeWorkDirectory("tagx-lyrics-sidecar")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let input = directory.appendingPathComponent("text.lrc")
        try Data(lrc.utf8).write(to: input)
        let sidecar = LRC.sidecarURL(for: file)

        let set = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path, "--sidecar", "--no-backup"])
        #expect(set.status == 0, Comment(rawValue: set.stderr))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try TagFile.read(at: file).syncedLyrics.isEmpty)

        let json = try runTagx(arguments: ["lyrics", "show", file.path, "--json"])
        let report = try JSONDecoder().decode(Report.self, from: Data(json.stdout.utf8))
        #expect(report.syncedSource == "sidecar")
        #expect(report.synced.count == 3)

        let target = directory.appendingPathComponent("export.lrc")
        let export = try runTagx(arguments: ["lyrics", "export", file.path, "--to", target.path])
        #expect(export.status == 0, Comment(rawValue: export.stderr))
        #expect(try LRC.load(from: target).lines.count == 3)

        // Jetzt SYLT einbetten: Eingebettet hat Vorrang, --sidecar daneben wird abgelehnt.
        let embed = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path, "--no-backup"])
        #expect(embed.status == 0, Comment(rawValue: embed.stderr))
        let refused = try runTagx(arguments: ["lyrics", "set", file.path, "--from", input.path, "--sidecar", "--no-backup"])
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("SYLT"))

        let clear = try runTagx(arguments: ["lyrics", "clear", file.path, "--no-backup"])
        #expect(clear.status == 0, Comment(rawValue: clear.stderr))
        #expect(clear.stdout.contains("sidecar removed"))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try TagFile.read(at: file).syncedLyrics.isEmpty)
    }
}

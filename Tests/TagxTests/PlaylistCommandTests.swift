// CLI-Regressionen für `tagx playlist` und `tagx cue`: JSON-Ausgabe,
// Beschriften, Ablehnung nicht speicherbarer Felder, Export und
// `cue apply` (Dry-run als Voreinstellung, Schreiben nur mit --apply).
import Foundation
import TagExplosionTestSupport
import Testing

@Suite("tagx playlist/cue CLI")
struct PlaylistCommandTests {

    @Test("show --json, set, export und cue apply",
          .enabled(if: TagxFixtures.isAvailable, "Fixtures fehlen (ffmpeg?)"))
    func playlistAndCueCommands() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-playlist-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mp3 = directory.appendingPathComponent("01.mp3")
        let flac = directory.appendingPathComponent("02.flac")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: mp3)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.flac"), to: flac)

        // Export aus zwei Dateien, dann Titel setzen und wieder lesen.
        let m3u = directory.appendingPathComponent("liste.m3u8")
        let export = try runTagx(arguments: [
            "playlist", "export", "--out", m3u.path, "--title", "Liste", mp3.path, flac.path,
        ])
        #expect(export.status == 0, Comment(rawValue: export.stderr))
        #expect(export.stdout.contains("2 entries"))

        let set = try runTagx(arguments: [
            "playlist", "set", m3u.path, "--no-backup", "--entry-title", "2=Zwei", "--title", "Neu",
        ])
        #expect(set.status == 0, Comment(rawValue: set.stderr))

        let show = try runTagx(arguments: ["playlist", "show", m3u.path, "--json"])
        #expect(show.status == 0, Comment(rawValue: show.stderr))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(show.stdout.utf8)) as? [String: Any])
        #expect(json["format"] as? String == "m3u8")
        #expect(json["missingCount"] as? Int == 0)
        let fields = try #require(json["fields"] as? [String: Any])
        #expect(fields["title"] as? String == "Neu")
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        #expect(entries[0]["location"] as? String == "01.mp3")
        #expect(entries[0]["exists"] as? Bool == true)
        #expect(entries[1]["title"] as? String == "Zwei")

        // Interpret hat in M3U keinen Speicherort: Fehler, Datei unverändert.
        let bytes = try Data(contentsOf: m3u)
        let rejected = try runTagx(arguments: [
            "playlist", "set", m3u.path, "--no-backup", "--entry-performer", "1=X",
        ])
        #expect(rejected.status != 0)
        #expect(rejected.stderr.contains("entryPerformer"))
        #expect(try Data(contentsOf: m3u) == bytes)

        // Vorhandene Ausgabedatei ohne --force: Fehler.
        let again = try runTagx(arguments: ["playlist", "export", "--out", m3u.path, mp3.path])
        #expect(again.status != 0)
        #expect(again.stderr.contains("already exists"))

        // Cue-Sheet: show, set, apply (erst Dry-run, dann wirklich).
        let cue = directory.appendingPathComponent("album.cue")
        try Data("""
        PERFORMER "Die Band"
        TITLE "Das Album"
        FILE "01.mp3" MP3
          TRACK 01 AUDIO
            TITLE "Eins"
            INDEX 01 00:00:00
        FILE "02.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Zwei"
            INDEX 01 00:00:00

        """.utf8).write(to: cue)
        let cueSet = try runTagx(arguments: ["cue", "set", cue.path, "--no-backup", "--date", "1999"])
        #expect(cueSet.status == 0, Comment(rawValue: cueSet.stderr))
        #expect(String(decoding: try Data(contentsOf: cue), as: UTF8.self).hasPrefix("REM DATE 1999\n"))

        let dryRun = try runTagx(arguments: ["cue", "apply", cue.path, "--no-backup"])
        #expect(dryRun.status == 0, Comment(rawValue: dryRun.stderr))
        #expect(dryRun.stdout.contains("DRY RUN: 2 file(s) would change"))
        let untouched = try runTagx(arguments: ["show", mp3.path, "--json"])
        #expect(!untouched.stdout.contains("Das Album"))

        let applied = try runTagx(arguments: ["cue", "apply", cue.path, "--no-backup", "--apply"])
        #expect(applied.status == 0, Comment(rawValue: applied.stderr))
        #expect(applied.stdout.contains("OK: 2 file(s) changed"))
        let tagged = try runTagx(arguments: ["show", flac.path])
        #expect(tagged.stdout.contains("ALBUM=Das Album"))
        #expect(tagged.stdout.contains("TRACKNUMBER=2/2"))
        #expect(tagged.stdout.contains("DATE=1999"))
        let noop = try runTagx(arguments: ["cue", "apply", cue.path, "--no-backup", "--json"])
        #expect(noop.status == 0)
        let plan = try #require(try JSONSerialization.jsonObject(with: Data(noop.stdout.utf8)) as? [String: Any])
        let items = try #require(plan["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items.allSatisfy { ($0["changedKeys"] as? [String])?.isEmpty == true })
    }

    @Test("Ungültige CUE-Zeiten und sehr große XSPF-Dauern lassen show nicht abstürzen")
    func durationBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cue = directory.appendingPathComponent("large.cue")
        try Data("FILE \"a.flac\" WAVE\nTRACK 01 AUDIO\nINDEX 01 \(Int.max):00:00\n".utf8).write(to: cue)
        let cueResult = try runTagx(arguments: ["playlist", "show", cue.path, "--json"])
        #expect(cueResult.status == 0, Comment(rawValue: cueResult.stderr))
        let report = try #require(try JSONSerialization.jsonObject(with: Data(cueResult.stdout.utf8)) as? [String: Any])
        let entries = try #require(report["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["startMilliseconds"] == nil)

        let xspf = directory.appendingPathComponent("large.xspf")
        try Data(("<playlist><trackList>" + String(repeating:
            "<track><duration>\(Int.max)</duration></track>", count: 2)
            + "</trackList></playlist>").utf8).write(to: xspf)
        for option in [[], ["--json"]] {
            let result = try runTagx(arguments: ["playlist", "show", xspf.path] + option)
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            if option.isEmpty { #expect(result.stdout.contains("TOTAL=2562047788015:12:56")) }
            else {
                let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
                #expect(report["totalDurationMilliseconds"] as? Int == Int.max)
            }
        }
    }
}

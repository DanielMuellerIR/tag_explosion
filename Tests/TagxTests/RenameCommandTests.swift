// CLI-Regression: `tagx rename` und `tagx parse` sind per Voreinstellung ein
// Probelauf, ändern mit --apply genau das Angekündigte und lassen bei einem
// Konflikt beziehungsweise Nicht-Treffer ALLE Dateien in Ruhe (Exit 2).
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore

@Suite("tagx rename/parse", .serialized)
struct RenameCommandTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("parse: Probelauf schreibt nichts, --apply setzt die Felder aus dem Namen",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func parseWritesOnlyWithApply() throws {
        let directory = try makeDirectory("parse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("07 - Miles Davis - So What.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let bytesBefore = try Data(contentsOf: file)
        let pattern = "%{track:2} - %{artist} - %{title}"

        let dry = try runTagx(arguments: ["parse", "-p", pattern, "--json", file.path])
        #expect(dry.status == 0)
        #expect(dry.stdout.contains("\"applied\" : false"))
        #expect(dry.stdout.contains("\"TRACKNUMBER\" : \"7\""))
        #expect(try Data(contentsOf: file) == bytesBefore)

        let applied = try runTagx(arguments: ["parse", "-p", pattern, "--apply", "--no-backup", file.path])
        #expect(applied.status == 0, Comment(rawValue: applied.stderr))
        #expect(applied.stdout.contains("3 field(s) changed"))
        let data = try TagFile.read(at: file)
        #expect(data.firstValue(for: "TRACKNUMBER") == "7")
        #expect(data.firstValue(for: "ARTIST") == "Miles Davis")
        #expect(data.firstValue(for: "TITLE") == "So What")

        // Zweiter Lauf: nichts ändert sich, die Datei bleibt byte-gleich.
        let stampAfter = try #require(FileStamp.current(of: file))
        let again = try runTagx(arguments: ["parse", "-p", pattern, "--apply", "--no-backup", file.path])
        #expect(again.status == 0)
        #expect(again.stdout.contains("0 field(s) changed"))
        #expect(FileStamp.current(of: file) == stampAfter)
    }

    @Test("parse: ein nicht passender Name blockiert den ganzen Lauf mit Exit 2",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func parseRefusesRunWhenOneFileDoesNotMatch() throws {
        let directory = try makeDirectory("parse-nomatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("01 - Titel.mp3")
        let bad = directory.appendingPathComponent("ohne nummer.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: good)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: bad)
        let goodBefore = try Data(contentsOf: good)

        let result = try runTagx(arguments: [
            "parse", "-p", "%{track} - %{title}", "--apply", "--no-backup", good.path, bad.path,
        ])
        #expect(result.status == 2)
        #expect(result.stdout.contains("NOMATCH"))
        #expect(try Data(contentsOf: good) == goodBefore)
    }

    @Test("rename: Vorschau, --apply und Konfliktabbruch",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func renamePreviewApplyAndConflict() throws {
        let directory = try makeDirectory("rename")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("a.mp3")
        let second = directory.appendingPathComponent("b.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: first)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: second)
        #expect(try runTagx(arguments: [
            "set", first.path, "--no-backup", "-t", "TRACKNUMBER=1", "TITLE=Eins", "ARTIST=Duo",
        ]).status == 0)
        #expect(try runTagx(arguments: [
            "set", second.path, "--no-backup", "-t", "TRACKNUMBER=2", "TITLE=Zwei", "ARTIST=Duo",
        ]).status == 0)

        // Probelauf: Vorschau, keine Änderung auf der Platte.
        let dry = try runTagx(arguments: [
            "rename", "-p", "%{track:2} %{title}", first.path, second.path,
        ])
        #expect(dry.status == 0, Comment(rawValue: dry.stderr))
        #expect(dry.stdout.contains("RENAME \(first.path) -> 01 Eins.mp3"))
        #expect(dry.stdout.contains("RENAME \(second.path) -> 02 Zwei.mp3"))
        #expect(FileManager.default.fileExists(atPath: first.path))

        // Konflikt: beide bekämen "Duo.mp3" — Exit 2, keine Datei angefasst.
        let conflict = try runTagx(arguments: [
            "rename", "-p", "%{artist}", "--apply", first.path, second.path,
        ])
        #expect(conflict.status == 2)
        #expect(conflict.stdout.contains("CONFLICT"))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))

        // --apply: Inhalt bleibt, Name ändert sich.
        let contentBefore = try Data(contentsOf: first)
        let applied = try runTagx(arguments: [
            "rename", "-p", "%{track:2} %{title}", "--apply", "--json", first.path, second.path,
        ])
        #expect(applied.status == 0, Comment(rawValue: applied.stderr))
        #expect(applied.stdout.contains("\"applied\" : true"))
        let renamed = directory.appendingPathComponent("01 Eins.mp3")
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try Data(contentsOf: renamed) == contentBefore)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("02 Zwei.mp3").path))
    }

    @Test("rename: XMP-Sidecar eines Bildes erscheint im JSON und wird mit umbenannt",
          .enabled(if: TagxFixtures.trackedCoverIsAvailable && (try? ExifTool.locateExecutable()) != nil,
                   "Getrackte Bild-Fixture oder exiftool fehlt"))
    func renameCarriesImageSidecar() throws {
        let directory = try makeDirectory("sidecar")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("bild.jpg")
        try FileManager.default.copyItem(at: TagxFixtures.trackedCover, to: image)
        // Titel in die Sidecar schreiben — daraus entsteht der neue Name.
        let set = try runTagx(arguments: [
            "exif", "set", image.path, "--sidecar", "--title", "Strand", "--no-backup",
        ])
        #expect(set.status == 0, Comment(rawValue: set.stderr))

        let preview = try runTagx(arguments: ["rename", "-p", "%{title}", image.path, "--json"])
        #expect(preview.status == 0, Comment(rawValue: preview.stderr))
        let report = try JSONSerialization.jsonObject(with: Data(preview.stdout.utf8)) as? [String: Any]
        let item = (report?["items"] as? [[String: Any]])?.first
        #expect(item?["target"] as? String == "Strand.jpg")
        #expect((item?["sidecarSource"] as? String)?.hasSuffix("/bild.xmp") == true)
        #expect(item?["sidecarTarget"] as? String == "Strand.xmp")

        let applied = try runTagx(arguments: ["rename", "-p", "%{title}", image.path, "--apply", "--json"])
        #expect(applied.status == 0, Comment(rawValue: applied.stderr))
        let result = try JSONSerialization.jsonObject(with: Data(applied.stdout.utf8)) as? [String: Any]
        let outcome = (result?["results"] as? [[String: Any]])?.first
        #expect((outcome?["sidecarTarget"] as? String)?.hasSuffix("/Strand.xmp") == true)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Strand.jpg").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Strand.xmp").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("bild.xmp").path))
    }

    @Test("rename: Muster mit Ordnertrenner wird als Eingabefehler abgelehnt")
    func renameRejectsPathInPattern() throws {
        let directory = try makeDirectory("rename-pattern")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("x.mp3")
        try Data().write(to: file)
        let result = try runTagx(arguments: ["rename", "-p", "%{artist}/%{title}", file.path])
        #expect(result.status == 64)
        #expect(result.stderr.contains("file name, not a folder path"))
    }


}

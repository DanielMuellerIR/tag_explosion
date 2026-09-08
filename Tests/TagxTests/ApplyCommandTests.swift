// CLI-Regression: `tagx apply` ist per Voreinstellung ein Probelauf, schreibt
// mit --apply genau den angekündigten Plan über den sicheren Weg, erkennt
// beim zweiten Lauf den No-op und meldet eine kaputte Regeldatei mit Exit 64.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore
@testable import tagx

@Suite("tagx apply", .serialized)
struct ApplyCommandTests {

    @Test("Regelplan bewahrt den XMP-Lesestand bis zum Schreiben",
          .enabled(if: TagxFixtures.isAvailable && (try? ExifTool.locateExecutable()) != nil,
                   "Bild-Fixture oder exiftool fehlt"), arguments: [false, true])
    func plannedImageRejectsChangedSidecar(existing: Bool) throws {
        let copy = try MediaTestFixtures.workingCopy("cover.jpg")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let sidecar = MediaFormats.sidecarURL(for: copy)
        func writeSidecar(_ title: String) throws {
            try Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:title="\(title)"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8).write(to: sidecar)
        }
        if existing { try writeSidecar(" Alter Titel ") }
        let snapshot = try ExifTool.readCoreFieldsSnapshot(url: copy)
        try writeSidecar("Fremder Titel")
        let foreign = try Data(contentsOf: sidecar)
        #expect(throws: TagError.fileChangedOnDisk(path: sidecar.path)) {
            try Parse.write(fields: ["TITLE": "Alter Titel"], to: copy,
                            expecting: snapshot.stamp, imageReading: snapshot.value)
        }
        #expect(try Data(contentsOf: sidecar) == foreign)

        // Ein neuer CLI-Lauf plant aus dem fremden Stand und darf diesen
        // anschließend ändern; die Konfliktprüfung blockiert keine frische Planung.
        let rules = copy.deletingLastPathComponent().appendingPathComponent("rules.json")
        try Data(#"{"version":1,"rules":[{"action":"case","field":"title","mode":"upper"}]}"#.utf8)
            .write(to: rules)
        let result = try runTagx(arguments: ["apply", rules.path, copy.path, "--apply", "--no-backup"])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(try ExifTool.readCoreFields(url: copy).title == "FREMDER TITEL")
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("--example liefert eine gültige Regeldatei")
    func exampleIsLoadable() throws {
        let result = try runTagx(arguments: ["apply", "--example"])
        #expect(result.status == 0)
        let document = try TagRulesIO.parse(Data(result.stdout.utf8))
        #expect(!document.rules.isEmpty)
    }

    @Test("Probelauf zeigt den Plan und schreibt nichts; --apply schreibt; zweiter Lauf ist ein No-op",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func dryRunThenApply() throws {
        let directory = try makeDirectory("apply")
        defer { try? FileManager.default.removeItem(at: directory) }
        let second = directory.appendingPathComponent("10 - zehn.mp3")
        let first = directory.appendingPathComponent("2 - zwei.flac")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: second)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.flac"), to: first)
        #expect(try runTagx(arguments: [
            "set", second.path, "--no-backup", "-t", "TITLE=  so WHAT of the day ", "ARTIST=miles",
        ]).status == 0)
        #expect(try runTagx(arguments: [
            "set", first.path, "--no-backup", "-t", "TITLE=blue in green", "ARTIST=miles", "ALBUMARTIST=Various",
        ]).status == 0)
        let rules = directory.appendingPathComponent("rules.json")
        try Data("""
        {
          "version": 1,
          "rules": [
            { "action": "trim", "field": "*" },
            { "action": "case", "field": "title", "mode": "title" },
            { "action": "copy", "field": "albumartist", "from": "artist", "onlyIfEmpty": true },
            { "action": "number", "sortBy": "filename", "total": true }
          ]
        }
        """.utf8).write(to: rules)
        let bytesBefore = try Data(contentsOf: second)

        // Probelauf über den Ordner: natürliche Sortierung (2 vor 10).
        let dry = try runTagx(arguments: ["apply", rules.path, directory.path])
        #expect(dry.status == 0, Comment(rawValue: dry.stderr))
        #expect(dry.stdout.contains("TITLE:   so WHAT of the day  -> So What of the Day"))
        #expect(dry.stdout.contains("ALBUMARTIST:  -> miles"))
        #expect(dry.stdout.contains("TRACKNUMBER:  -> 2/2"))
        #expect(dry.stdout.contains("Dry run: 2 file(s) to change"))
        #expect(try Data(contentsOf: second) == bytesBefore)

        let json = try runTagx(arguments: ["apply", rules.path, "--json", second.path])
        #expect(json.status == 0)
        #expect(json.stdout.contains("\"applied\" : false"))
        #expect(json.stdout.contains("\"new\" : \"So What of the Day\""))

        let applied = try runTagx(arguments: ["apply", rules.path, "--apply", "--no-backup", directory.path])
        #expect(applied.status == 0, Comment(rawValue: applied.stderr))
        #expect(applied.stdout.contains("Applied to 2 of 2 file(s)"))
        let mp3 = try TagFile.read(at: second)
        #expect(mp3.firstValue(for: "TITLE") == "So What of the Day")
        #expect(mp3.firstValue(for: "ALBUMARTIST") == "miles")
        #expect(mp3.firstValue(for: "TRACKNUMBER") == "2/2")
        let flac = try TagFile.read(at: first)
        #expect(flac.firstValue(for: "TITLE") == "Blue in Green")
        #expect(flac.firstValue(for: "ALBUMARTIST") == "Various")
        #expect(flac.firstValue(for: "TRACKNUMBER") == "1/2")

        // Zweiter Lauf: nichts zu tun, die Dateien bleiben unangetastet.
        let stamp = try #require(FileStamp.current(of: second))
        let again = try runTagx(arguments: ["apply", rules.path, "--apply", "--no-backup", directory.path])
        #expect(again.status == 0)
        #expect(again.stdout.contains("Applied to 0 of 2 file(s)"))
        #expect(FileStamp.current(of: second) == stamp)
    }

    @Test("Überlauf der Nummerierung meldet Exit 64 vor jeder Dateiänderung",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt"))
    func numberingOverflowIsUsageError() throws {
        let directory = try makeDirectory("number-overflow")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["a.mp3", "b.mp3"].map { directory.appendingPathComponent($0) }
        for file in files { try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file) }
        let original = try Data(contentsOf: files[0])
        let rules = directory.appendingPathComponent("rules.json")
        try TagRulesIO.save(TagRuleDocument(rules: [TagRule(action: .number, start: Int.max)]), to: rules)
        let result = try runTagx(arguments: ["apply", rules.path, "--apply", "--no-backup"] + files.map(\.path))
        #expect(result.status == 64)
        #expect(result.stderr.contains("Rule 1"))
        for file in files { #expect(try Data(contentsOf: file) == original) }
    }

    @Test("Ungültige Regeldatei: Exit 64 mit Regelnummer und Zeile, nichts wird gelesen oder geschrieben",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func invalidRulesExit64() throws {
        let directory = try makeDirectory("apply-bad")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let rules = directory.appendingPathComponent("rules.json")
        try Data("""
        {
          "version": 1,
          "rules": [
            { "action": "explode", "field": "title" }
          ]
        }
        """.utf8).write(to: rules)
        let bytesBefore = try Data(contentsOf: file)

        let result = try runTagx(arguments: ["apply", rules.path, "--apply", "--no-backup", file.path])
        #expect(result.status == 64)
        #expect(result.stderr.contains("Rule 1 (line 4)"))
        #expect(result.stderr.contains("unknown action \"explode\""))
        #expect(try Data(contentsOf: file) == bytesBefore)

        // Kein JSON: ebenfalls 64.
        try Data("{ nicht json".utf8).write(to: rules)
        let broken = try runTagx(arguments: ["apply", rules.path, file.path])
        #expect(broken.status == 64)
        #expect(broken.stderr.contains("Invalid rules file"))
    }

    @Test("Ein Feld, das die Medienart nicht kennt, wird beim Schreiben als Fehler gemeldet (Exit 1)",
          .enabled(if: TagxFixtures.trackedCoverIsAvailable, "Bild-Fixture fehlt"))
    func unsupportedFieldFailsForImage() throws {
        let directory = try makeDirectory("apply-image")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("cover.jpg")
        try FileManager.default.copyItem(at: TagxFixtures.trackedCover, to: image)
        let rules = directory.appendingPathComponent("rules.json")
        try Data(#"{"version": 1, "rules": [{"action": "set", "field": "album", "value": "X"}]}"#.utf8)
            .write(to: rules)
        let bytesBefore = try Data(contentsOf: image)

        // Der Plan selbst kennt keine Medienart-Grenzen; erst der Schreibweg
        // lehnt ALBUM für ein Bild ab — die Datei bleibt unverändert.
        let dry = try runTagx(arguments: ["apply", rules.path, image.path])
        #expect(dry.status == 0)
        #expect(dry.stdout.contains("ALBUM:  -> X"))
        let applied = try runTagx(arguments: ["apply", rules.path, "--apply", "--no-backup", image.path])
        #expect(applied.status == 1)
        #expect(applied.stdout.contains("FAILED"))
        #expect(applied.stdout.contains("ALBUM"))
        #expect(try Data(contentsOf: image) == bytesBefore)
    }


}

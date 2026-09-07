// CLI-Regressionen der Cover-Werkzeuge: `cover info --json`, `--strict`,
// `cover convert`, `cover from-folder`, `cover to-folder` samt --force.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore

@Suite("tagx cover info/convert/from-folder/to-folder", .serialized)
struct CoverToolCommandTests {

    /// Spiegel der CLI-JSON-Ausgabe (`Report` ist im CLI-Target privat).
    private struct Report: Decodable {
        struct Entry: Decodable {
            var index: Int
            var pictureType: String
            var analysis: CoverAnalysis
        }
        var file: String
        var artworks: [Entry]
    }

    @Test("cover info --json liefert Analyse und Regelcodes; --strict gibt Exit 3",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func infoJSONAndStrict() throws {
        let directory = try makeWorkDirectory("tagx-cover-info")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let large = try Data(contentsOf: TagxFixtures.url("cover-large.jpg"))
        try TagFile.write(artworks: [Artwork(data: large, pictureType: "Front Cover")], to: file)

        let result = try runTagx(arguments: ["cover", "info", "--json", file.path])
        #expect(result.status == 0)
        let reports = try JSONDecoder().decode([Report].self, from: Data(result.stdout.utf8))
        #expect(reports.count == 1)
        let entry = try #require(reports.first?.artworks.first)
        #expect(entry.index == 1)
        #expect(entry.pictureType == "Front Cover")
        #expect(entry.analysis.format == "JPEG")
        #expect(entry.analysis.pixelWidth == 1200)
        #expect(entry.analysis.pixelHeight == 800)
        #expect(entry.analysis.issues.map(\.code) == [.notSquare])

        let strict = try runTagx(arguments: ["cover", "info", "--strict", file.path])
        #expect(strict.status == 3)
        #expect(strict.stdout.contains("not-square"))

        // Datei ohne Cover: Text meldet es, --strict zählt es als Problem.
        let bare = directory.appendingPathComponent("bare.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: bare)
        let noCover = try runTagx(arguments: ["cover", "info", bare.path])
        #expect(noCover.status == 0)
        #expect(noCover.stdout.contains("(no cover)"))
        #expect(try runTagx(arguments: ["cover", "info", "--strict", bare.path]).status == 3)
    }

    @Test("cover convert --max-size schreibt das verkleinerte Cover in die Datei",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"),
          .enabled(if: CoverTools.isConversionAvailable, "Umwandlung braucht ImageIO"))
    func convertShrinksEmbeddedCover() throws {
        let directory = try makeWorkDirectory("tagx-cover-convert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.flac"), to: file)
        let large = try Data(contentsOf: TagxFixtures.url("cover-large.jpg"))
        let booklet = Artwork(data: try Data(contentsOf: TagxFixtures.url("cover.png")), pictureType: "Illustration")
        try TagFile.write(artworks: [Artwork(data: large, pictureType: "Front Cover"), booklet], to: file)

        // Ohne Auftrag: Validierungsfehler (Exit 64), Datei unverändert.
        let before = try Data(contentsOf: file)
        #expect(try runTagx(arguments: ["cover", "convert", file.path, "--no-backup"]).status == 64)
        #expect(try Data(contentsOf: file) == before)

        let result = try runTagx(arguments: [
            "cover", "convert", "--max-size", "500", "--strip-metadata", file.path, "--no-backup",
        ])
        #expect(result.status == 0)
        #expect(result.stdout.contains("500×333 px"))
        let after = try TagFile.read(at: file)
        #expect(after.artworks.count == 2)
        let cover = CoverTools.analyze(after.artworks[0].data)
        #expect(cover.pixelWidth == 500)
        #expect(cover.pixelHeight == 333)
        #expect(cover.format == "JPEG")
        // Das zweite Bild bleibt unangetastet.
        #expect(after.artworks[1].data == booklet.data)

        // Zweiter Lauf: nichts mehr zu tun.
        let again = try runTagx(arguments: ["cover", "convert", "--max-size", "500", file.path, "--no-backup"])
        #expect(again.status == 0)
        #expect(again.stdout.contains("cover unchanged"))

        // --png wandelt das Format.
        let png = try runTagx(arguments: ["cover", "convert", "--png", file.path, "--no-backup"])
        #expect(png.status == 0)
        #expect(CoverTools.analyze(try TagFile.read(at: file).artworks[0].data).format == "PNG")
    }

    @Test("cover from-folder bettet folder/cover/front ein; to-folder exportiert mit --force-Schutz",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func folderCoverRoundtrip() throws {
        let directory = try makeWorkDirectory("tagx-cover-folder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("01.mp3")
        let second = directory.appendingPathComponent("02.m4a")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: first)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.m4a"), to: second)

        // Ohne Ordner-Cover: Fehler, nichts geschrieben.
        let missing = try runTagx(arguments: ["cover", "from-folder", first.path, "--no-backup"])
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("No folder cover"))
        #expect(try TagFile.read(at: first).artworks.isEmpty)

        let jpg = try Data(contentsOf: TagxFixtures.url("cover.jpg"))
        try jpg.write(to: directory.appendingPathComponent("Folder.JPG"))
        let result = try runTagx(arguments: ["cover", "from-folder", first.path, second.path, "--no-backup"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("cover set from Folder.JPG"))
        #expect(try TagFile.read(at: first).artworks.first?.data == jpg)
        #expect(try TagFile.read(at: second).artworks.first?.data == jpg)

        // to-folder: Folder.JPG belegt den Namen folder.jpg (APFS ignoriert
        // die Schreibweise) → ohne --force Abbruch, Datei bleibt. Auf einem
        // Dateisystem, das Groß-/Kleinschreibung unterscheidet (ext4 unter
        // Linux), ist folder.jpg frei — dort legen wir es ausdrücklich an,
        // damit derselbe Schutz geprüft wird.
        let lowercase = directory.appendingPathComponent("folder.jpg")
        if !FileManager.default.fileExists(atPath: lowercase.path) {
            try jpg.write(to: lowercase)
        }
        let blocked = try runTagx(arguments: ["cover", "to-folder", first.path])
        #expect(blocked.status != 0)
        #expect(blocked.stderr.contains("already exists"))

        let exported = directory.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        let moved = exported.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: first, to: moved)
        let ok = try runTagx(arguments: ["cover", "to-folder", moved.path])
        #expect(ok.status == 0)
        let target = exported.appendingPathComponent("folder.jpg")
        #expect(ok.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == target.path)
        #expect(try Data(contentsOf: target) == jpg)

        // Vorhandene Datei: erst mit --force ersetzen.
        try Data("Platzhalter mit ausreichend vielen Bytes".utf8).write(to: target, options: .atomic)
        #expect(try runTagx(arguments: ["cover", "to-folder", moved.path]).status != 0)
        #expect(try Data(contentsOf: target) != jpg)
        #expect(try runTagx(arguments: ["cover", "to-folder", "--force", moved.path, "--no-backup"]).status == 0)
        #expect(try Data(contentsOf: target) == jpg)
    }

    // MARK: - Helfer

    private func makeWorkDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }


}

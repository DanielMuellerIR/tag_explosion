// CLI-Regression: `tagx set` schreibt nur, wenn sich wirklich etwas ändert.
// Ein semantischer No-op (Sollwerte == Dateizustand) darf weder die Datei neu
// aufbauen (neue Inode/mtime, unnötige Sicherung) noch "geänderte" Felder
// melden.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore

@Suite("tagx set No-op", .serialized)
struct SetCommandTests {

    @Test("Unveränderte Sollwerte lassen die Datei byte-gleich und melden 0 Felder",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func noopSetDoesNotRewriteFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-set-noop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)

        // Erster Lauf setzt den Wert wirklich (genau ein geändertes Feld).
        let first = try runTagx(arguments: [
            "set", file.path, "--no-backup", "-t", "TITLE=Gleichbleibend",
        ])
        #expect(first.status == 0)
        #expect(first.stdout.contains("1 field(s) changed"))
        let bytesAfterFirst = try Data(contentsOf: file)
        let stampAfterFirst = try #require(FileStamp.current(of: file))

        // Zweiter, identischer Lauf: nichts ändert sich — Datei bleibt
        // byte-gleich, gleiche Identität, und die Meldung nennt 0 Felder.
        let second = try runTagx(arguments: [
            "set", file.path, "--no-backup", "-t", "TITLE=Gleichbleibend",
        ])
        #expect(second.status == 0)
        #expect(second.stdout.contains("0 field(s) changed"))
        #expect(try Data(contentsOf: file) == bytesAfterFirst)
        #expect(FileStamp.current(of: file) == stampAfterFirst)

        // Mischfall: ein Feld ändert sich wirklich, das andere nicht — die
        // Meldung zählt nur die echte Änderung.
        let mixed = try runTagx(arguments: [
            "set", file.path, "--no-backup",
            "-t", "TITLE=Gleichbleibend", "ARTIST=Neu dazu",
        ])
        #expect(mixed.status == 0)
        #expect(mixed.stdout.contains("1 field(s) changed"))

        // Die explizite ID3-Version ist ebenfalls ein Sollwert. Unveränderte
        // Tags dürfen die verlangte Umstellung von v2.4 auf v2.3 nicht verhindern.
        let versionArguments = ["set", file.path, "--no-backup", "--id3v23", "-t", "TITLE=Gleichbleibend"]
        #expect(try TagFile.read(at: file).layers.first { $0.kind == .id3v2 }?.version == 4)
        let converted = try runTagx(arguments: versionArguments)
        #expect(converted.status == 0)
        #expect(try TagFile.read(at: file).layers.first { $0.kind == .id3v2 }?.version == 3)
        let convertedStamp = FileStamp.current(of: file)
        #expect(try runTagx(arguments: versionArguments).status == 0)
        #expect(FileStamp.current(of: file) == convertedStamp)
    }

    @Test("Leere Tag-Schlüssel werden ohne Dateiänderung abgelehnt",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func emptyTagKeyIsRejectedWithoutChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-set-empty-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let original = try Data(contentsOf: file)

        let result = try runTagx(arguments: [
            "set", file.path, "--no-backup", "-t", "=unbenannt",
        ])

        #expect(result.status == 64)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Nicht-Bilddaten werden nicht als Audio-Cover eingebettet",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func nonImageCoverIsRejectedWithoutChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-cover-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        let invalidCover = directory.appendingPathComponent("not-an-image.txt")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        try Data("kein Bild".utf8).write(to: invalidCover)
        let original = try Data(contentsOf: file)

        let result = try runTagx(arguments: [
            "cover", "set", file.path, invalidCover.path, "--no-backup",
        ])

        #expect(result.status == 64)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Cover-Export überschreibt keine vorhandene Datei",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func coverExportDoesNotOverwriteExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-cover-collision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let cover = try Data(contentsOf: TagxFixtures.url("cover.jpg"))
        try TagFile.write(artworks: [Artwork(data: cover)], to: file)
        let target = directory.appendingPathComponent("song-cover.jpg")
        let existing = Data("bereits vorhanden".utf8)
        try existing.write(to: target)

        let result = try runTagx(arguments: [
            "cover", "export", file.path, "--output", directory.path,
        ])

        #expect(result.status != 0)
        #expect(try Data(contentsOf: target) == existing)
    }

    @Test("BMP-Cover werden mit passender Dateiendung exportiert",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func bmpCoverUsesBmpExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-cover-bmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let bmp = Data([0x42, 0x4D] + Array(repeating: 0, count: 10))
        try TagFile.write(artworks: [Artwork(data: bmp, mimeType: "image/bmp")], to: file)

        let result = try runTagx(arguments: [
            "cover", "export", file.path, "--output", directory.path,
        ])

        #expect(result.status == 0)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("song-cover.bmp").path))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("song-cover.jpg").path))
    }
}

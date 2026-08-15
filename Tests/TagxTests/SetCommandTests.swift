// CLI-Regression: `tagx set` schreibt nur, wenn sich wirklich etwas ändert.
// Ein semantischer No-op (Sollwerte == Dateizustand) darf weder die Datei neu
// aufbauen (neue Inode/mtime, unnötige Sicherung) noch "geänderte" Felder
// melden.
import Foundation
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
    }

    @Test("No-op-Vertrag lehnt eine Ersetzung nach dem Feldvergleich ab",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func noopSnapshotRejectsSamePathReplacementAfterComparison() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-set-noop-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        let replacement = directory.appendingPathComponent("replacement.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: replacement)

        // Genau derselbe Vertrag liegt im Set-Befehl um Read, Vergleich und
        // No-op-Rückweg. Nach dem semantischen Vergleich wird der Pfad gezielt
        // atomar auf eine andere Inode umgestellt.
        let snapshot = try FileSnapshot.capture(at: file) {
            try TagFile.read(at: file)
        }
        #expect(!snapshot.value.properties.isEmpty)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: file.path)) {
            try snapshot.requireCurrent(at: file)
        }
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

    @Test("Gemeinsamer Prozesshelfer leert große stdout- und stderr-Pipes parallel")
    func processHelperDrainsBothPipes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let byteCount = 1_048_576
        let command = """
        dd if=/dev/zero bs=\(byteCount) count=1 2>/dev/null
        dd if=/dev/zero bs=\(byteCount) count=1 1>&2 2>/dev/null
        """

        let result = try runCapturedProcess(
            executable: "/bin/sh", arguments: ["-c", command], currentDirectory: root)

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == byteCount)
        #expect(result.stderr.utf8.count == byteCount)
    }

    /// Baut das CLI-Produkt über SwiftPM und startet genau das entstandene
    /// Binary (gleiches Muster wie in ExportCollisionTests).
    private func runTagx(arguments: [String]) throws
    -> CapturedProcessResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try runCapturedProcess(
            executable: URL(fileURLWithPath: binaryDirectory)
                .appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
    }

}

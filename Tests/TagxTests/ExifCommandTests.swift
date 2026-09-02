// Echte CLI-Regressionen für Bildmetadaten. Sie prüfen nicht nur den Core,
// sondern auch ArgumentParser, Exit-Code und die vom Befehl gebildeten Felder.
import Foundation
import Testing
import TagExplosionCore

@Suite("tagx exif", .serialized)
struct ExifCommandTests {

    @Test("Rating -1 setzt abgelehnt; nur ein leerer Wert löscht das Tag",
          .enabled(if: TagxFixtures.trackedCoverIsAvailable && exifToolIsAvailable,
                   "Getrackte Bild-Fixture oder exiftool fehlt"))
    func rejectedRatingIsNotDeletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-exif-rating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bild.jpg")
        try FileManager.default.copyItem(at: TagxFixtures.trackedCover, to: file)

        let rejected = try runTagx(arguments: [
            "exif", "set", file.path, "--rating=-1", "--no-backup",
        ])
        #expect(rejected.status == 0)
        #expect(try ExifTool.readCoreFields(url: file).rating == -1)

        let deleted = try runTagx(arguments: [
            "exif", "set", file.path, "--rating", "", "--no-backup",
        ])
        #expect(deleted.status == 0)
        #expect(try ExifTool.readCoreFields(url: file).rating == nil)
    }

    @Test("--sidecar schreibt in <name>.xmp und lässt das Bild unverändert",
          .enabled(if: TagxFixtures.trackedCoverIsAvailable && exifToolIsAvailable,
                   "Getrackte Bild-Fixture oder exiftool fehlt"))
    func sidecarFlagWritesXMPNextToImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-exif-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bild.jpg")
        try FileManager.default.copyItem(at: TagxFixtures.trackedCover, to: file)
        let bytesBefore = try Data(contentsOf: file)
        let sidecar = directory.appendingPathComponent("bild.xmp")

        let written = try runTagx(arguments: [
            "exif", "set", file.path, "--sidecar", "--title", "Sidecar-Titel", "--no-backup",
        ])
        #expect(written.status == 0, Comment(rawValue: written.stderr))
        #expect(written.stdout.contains("bild.xmp"))
        #expect(try Data(contentsOf: file) == bytesBefore)
        #expect(FileManager.default.fileExists(atPath: sidecar.path))

        let shown = try runTagx(arguments: ["exif", "show", file.path, "--json"])
        #expect(shown.status == 0)
        let report = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any]
        // Der Befehl löst den Pfad kanonisch auf (/var → /private/var); der
        // Dateiname genügt als Nachweis.
        #expect((report?["sidecar"] as? String)?.hasSuffix("/bild.xmp") == true)
        #expect(report?["sidecarFields"] as? [String] == ["title"])
        #expect((report?["core"] as? [String: Any])?["title"] as? String == "Sidecar-Titel")
        // Ab jetzt gilt die Sidecar auch ohne Flag als Ziel.
        #expect(report?["writeTarget"] as? String == "existingSidecar")
    }

    @Test("Kamera-RAW wird nie direkt beschrieben — auch ohne --sidecar",
          .enabled(if: TagxFixtures.isAvailable && exifToolIsAvailable,
                   "Fixtures (ffmpeg) oder exiftool fehlen"))
    func rawAlwaysWritesSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-exif-raw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // NEF ist ein TIFF-Container; das TIFF-Fixture unter RAW-Endung genügt exiftool.
        let raw = directory.appendingPathComponent("IMG_0001.nef")
        try FileManager.default.copyItem(at: TagxFixtures.url("cover.tif"), to: raw)
        let bytesBefore = try Data(contentsOf: raw)

        let written = try runTagx(arguments: [
            "exif", "set", raw.path, "--rating=5", "--keywords", "Urlaub, Meer", "--no-backup",
        ])
        #expect(written.status == 0, Comment(rawValue: written.stderr))
        #expect(written.stdout.contains("rawFormat"))
        #expect(try Data(contentsOf: raw) == bytesBefore)
        let reading = try ExifTool.readCoreReading(url: raw)
        #expect(reading.fields.rating == 5)
        #expect(reading.fields.keywords == ["Urlaub", "Meer"])
        #expect(reading.sidecarURL == directory.appendingPathComponent("IMG_0001.xmp"))
    }

    /// Baut das CLI-Produkt und startet genau das entstandene Binary.
    private func runTagx(arguments: [String]) throws -> CapturedProcessResult {
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

private let exifToolIsAvailable = (try? ExifTool.locateExecutable()) != nil

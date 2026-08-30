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

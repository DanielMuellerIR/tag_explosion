// Cover-Werkzeuge im Editor-Puffer (AP12): Verkleinern/Wandeln ändern nur
// `entry.artworks` (dirty, Speichern über den gewohnten Weg), Ordner-Cover
// werden je Verzeichnis gefunden, Einträge ohne Cover übersprungen. Headless,
// ohne Fenster; die Testbilder entstehen im Test selbst (ImageIO).
import AppKit
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("CoverToolActions", .serialized)
@MainActor
struct CoverToolActionsTests {

    @Test("Verkleinern ändert das Cover im Puffer und macht den Eintrag dirty")
    func shrinkChangesBufferOnly() throws {
        let large = try makeImage(width: 1200, height: 800, format: .jpeg)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-tools/song.mp3"),
                              loaded: .audio(TagData(properties: [], artworks: [Artwork(data: large)], audio: nil)))
        let bare = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-tools/bare.mp3"),
                             loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        #expect(!entry.isDirty)

        let outcome = CoverToolActions.convert([entry, bare], .init(maxPixelSize: 500))
        #expect(outcome.changed == 1)
        #expect(outcome.skipped == 1)
        #expect(outcome.errors.isEmpty)
        #expect(entry.isDirty)
        let analysis = CoverTools.analyze(entry.artworks[0].data)
        #expect(analysis.pixelWidth == 500)
        #expect(analysis.pixelHeight == 333)
        // Kein zweites Mal: schon klein genug.
        #expect(CoverToolActions.convert([entry], .init(maxPixelSize: 500)).unchanged == 1)
        entry.revert()
        #expect(entry.artworks[0].data == large)
    }

    @Test("Nach JPEG wandeln setzt den MIME-Type um; Fehler stoppen die anderen nicht")
    func convertToJPEGReportsErrors() throws {
        let png = try makeImage(width: 64, height: 64, format: .png)
        let good = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-tools/a.flac"),
                             loaded: .audio(TagData(properties: [], artworks: [Artwork(data: png)], audio: nil)))
        let broken = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-tools/b.flac"),
                               loaded: .audio(TagData(properties: [], artworks: [Artwork(data: Data(repeating: 7, count: 32))], audio: nil)))
        let outcome = CoverToolActions.convert([broken, good], .init(format: .jpeg))
        #expect(outcome.changed == 1)
        #expect(outcome.errors.count == 1)
        #expect(outcome.errors[0].hasPrefix("b.flac:"))
        #expect(good.artworks[0].mimeType == "image/jpeg")
        #expect(CoverTools.analyze(good.artworks[0].data).format == "JPEG")
        #expect(CoverToolActions.report(outcome, action: "Test")?.contains("b.flac") == true)
        #expect(CoverToolActions.report(.init(changed: 2), action: "Test") == nil)
    }

    @Test("Ordner-Cover wird je Verzeichnis übernommen; Einträge ohne bleiben stehen")
    func applyFolderCoverPerDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-foldercover-\(UUID().uuidString)")
        let withCover = root.appendingPathComponent("album")
        let without = root.appendingPathComponent("single")
        try FileManager.default.createDirectory(at: withCover, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: without, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folderCover = try makeImage(width: 64, height: 64, format: .jpeg)
        try folderCover.write(to: withCover.appendingPathComponent("Folder.jpg"))

        let old = Artwork(data: try makeImage(width: 32, height: 32, format: .png), pictureType: "Front Cover")
        let booklet = Artwork(data: try makeImage(width: 16, height: 16, format: .png), pictureType: "Illustration")
        let first = FileEntry(url: withCover.appendingPathComponent("01.mp3"),
                              loaded: .audio(TagData(properties: [], artworks: [old, booklet], audio: nil)))
        let second = FileEntry(url: withCover.appendingPathComponent("02.mp3"),
                               loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        let lonely = FileEntry(url: without.appendingPathComponent("03.mp3"),
                               loaded: .audio(TagData(properties: [], artworks: [old], audio: nil)))

        let outcome = CoverToolActions.applyFolderCover([first, second, lonely])
        #expect(outcome.changed == 2)
        #expect(outcome.skipped == 1)
        #expect(first.artworks.count == 2)
        #expect(first.artworks[0].data == folderCover)
        #expect(first.artworks[1] == booklet)
        #expect(second.artworks.first?.data == folderCover)
        #expect(lonely.artworks[0] == old)
        #expect(!lonely.isDirty)
        #expect(CoverToolActions.applyFolderCover([first]).unchanged == 1)
        #expect(CoverToolActions.sharedCover(of: [first, second])?.data == folderCover)
        #expect(CoverToolActions.sharedCover(of: [first, lonely]) == nil)
    }

    // MARK: - Helfer

    /// Einfarbiges Testbild über AppKit/ImageIO — keine Fixture nötig.
    private func makeImage(width: Int, height: Int, format: CoverTools.OutputFormat) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(
            using: format == .png ? .png : .jpeg,
            properties: format == .png ? [:] : [.compressionFactor: 0.8]))
        return data
    }
}

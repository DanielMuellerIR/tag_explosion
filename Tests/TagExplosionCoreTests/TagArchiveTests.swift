// Export/Import-Roundtrip über die JSON-Archivdatei: exportieren → Tags
// verändern → importieren → Originalzustand wiederhergestellt. Deckt Audio
// (PropertyMap + Cover), Bild (Kernfelder) und EPUB ab, dazu die Meldungen
// für fehlende/zusätzliche Dateien und --dry-run.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("TagArchive", .serialized)
struct TagArchiveTests {

    /// Kopiert mehrere Fixtures zusammen in EIN frisches Temp-Verzeichnis.
    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Fixtures.directory.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test("Audio: Export → Ändern → Import stellt Tags und Cover wieder her")
    func audioRestore() throws {
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let cover = try Fixtures.coverData("cover.jpg")

        // Ausgangszustand herstellen: Tags + Cover
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Original"),
                         TagProperty(key: "GENRE", value: "Jazz"),
                         TagProperty(key: "GENRE", value: "Bebop")],
            artworks: [Artwork(data: cover, mimeType: "image/jpeg")], to: mp3)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: MediaFormats.expandMediaFiles([dir]),
                                to: json, includeCovers: true)

        // Verändern, dann wiederherstellen
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: [], to: mp3)
        let report = TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        #expect(report.unchanged == ["sample.flac"])
        #expect(report.missing.isEmpty)
        #expect(report.failed.isEmpty)

        let restored = try TagFile.read(at: mp3)
        #expect(restored.firstValue(for: "TITLE") == "Original")
        #expect(restored.values(for: "GENRE") == ["Bebop", "Jazz"]
            || restored.values(for: "GENRE") == ["Jazz", "Bebop"])
        #expect(restored.artworks.first?.data == cover)
    }

    @Test("Bild und EPUB: Import stellt Kernfelder wieder her")
    func imageAndEbookRestore() throws {
        let dir = try makeFolder(["cover.jpg", "book2.epub"])
        let jpg = dir.appendingPathComponent("cover.jpg")
        let epub = dir.appendingPathComponent("book2.epub")

        var imageFields = try ExifTool.readCoreFields(url: jpg)
        imageFields.title = "Bild-Original"
        try ExifTool.writeCoreFields(url: jpg, fields: imageFields,
                                     original: ImageCoreFields())

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: MediaFormats.expandMediaFiles([dir]),
                                to: json, includeCovers: true)

        // Beide Dateien verändern
        var brokenImage = imageFields
        brokenImage.title = "Kaputt"
        try ExifTool.writeCoreFields(url: jpg, fields: brokenImage, original: imageFields)
        let epubOriginal = try EbookTool.readCoreFields(url: epub)
        var brokenEpub = epubOriginal
        brokenEpub.title = "Kaputt"
        try EbookTool.writeCoreFields(url: epub, fields: brokenEpub, original: epubOriginal)

        let report = TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(Set(report.applied) == ["cover.jpg", "book2.epub"])
        #expect(try ExifTool.readCoreFields(url: jpg).title == "Bild-Original")
        #expect(try EbookTool.readCoreFields(url: epub).title == "Testbuch Zwei")
    }

    @Test("Fehlende und zusätzliche Dateien werden gemeldet, dry-run schreibt nicht")
    func missingExtraAndDryRun() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3], to: json, includeCovers: true)

        // Datei umbenennen: Archiv-Eintrag wird "fehlend", neue Datei "zusätzlich"
        let renamed = dir.appendingPathComponent("umbenannt.mp3")
        try FileManager.default.moveItem(at: mp3, to: renamed)
        var report = TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(report.missing == ["sample.mp3"])
        #expect(report.extra == ["umbenannt.mp3"])

        // dry-run: meldet Änderung, schreibt aber nicht
        try FileManager.default.moveItem(at: renamed, to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: [], to: mp3)
        report = TagArchiveIO.apply(try TagArchiveIO.load(json),
                                    relativeTo: dir, dryRun: true)
        #expect(report.applied == ["sample.mp3"])
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Kaputt")
    }

    @Test("--without-covers lässt vorhandene Cover beim Import unangetastet")
    func withoutCoversKeepsArtworks() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let cover = try Fixtures.coverData("cover.jpg")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [Artwork(data: cover, mimeType: "image/jpeg")], to: mp3)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3], to: json, includeCovers: false)
        // Titel ändern, Cover bleibt — Import stellt Titel her, Cover bleibt da
        let current = try TagFile.read(at: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: current.artworks, to: mp3)
        let report = TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        let restored = try TagFile.read(at: mp3)
        #expect(restored.firstValue(for: "TITLE") == "Original")
        #expect(restored.artworks.first?.data == cover)
    }

    @Test("Relative Pfade auch oberhalb des JSON-Ordners")
    func relativePaths() {
        let base = URL(fileURLWithPath: "/a/b/c")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/b/c/x.mp3"), to: base) == "x.mp3")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/b/c/sub/x.mp3"), to: base) == "sub/x.mp3")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/other/x.mp3"), to: base) == "../../other/x.mp3")
    }
}

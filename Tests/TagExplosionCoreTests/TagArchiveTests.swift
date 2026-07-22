// Export/Import-Roundtrip über die JSON-Archivdatei: exportieren → Tags
// verändern → importieren → Originalzustand wiederhergestellt. Deckt Audio
// (PropertyMap + Cover), Bild (Kernfelder) und EPUB ab, dazu die Meldungen
// für fehlende/zusätzliche Dateien und --dry-run.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("TagArchive", .serialized)
struct TagArchiveTests {

    private static let calibreFixtureAvailable = EbookTool.calibreAvailable
        && FileManager.default.fileExists(
            atPath: Fixtures.directory.appendingPathComponent("book.azw3").path)

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
        let report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
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

        let report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
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
        var report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(report.missing == ["sample.mp3"])
        #expect(report.extra == ["umbenannt.mp3"])

        // dry-run: meldet Änderung, schreibt aber nicht
        try FileManager.default.moveItem(at: renamed, to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: [], to: mp3)
        report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
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
        #expect(try TagArchiveIO.load(json).files.first?.artworks == nil)
        // Titel ändern, Cover bleibt — Import stellt Titel her, Cover bleibt da
        let current = try TagFile.read(at: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: current.artworks, to: mp3)
        let report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
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

    @Test("Explizit leere Audio-Cover werden exportiert und beim Import entfernt")
    func emptyAudioCoverRemovesLaterCover() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Ohne Cover")],
                          artworks: [], to: mp3)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3], to: json, includeCovers: true)
        let archive = try TagArchiveIO.load(json)
        #expect(archive.files.first?.artworks == [])

        // Ein nach dem Backup hinzugefügtes Cover gehört nicht zum Soll-Zustand.
        try TagFile.write(artworks: [Artwork(data: try Fixtures.coverData("cover.jpg"))], to: mp3)
        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        #expect(try TagFile.read(at: mp3).artworks.isEmpty)
    }

    @Test("Explizit leere EPUB-Cover werden exportiert und beim Import entfernt")
    func emptyEpubCoverRemovesLaterCover() throws {
        let dir = try makeFolder(["book2.epub"])
        let epub = dir.appendingPathComponent("book2.epub")
        try EbookTool.removeCover(url: epub)
        #expect(try EbookTool.readCover(url: epub) == nil)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [epub], to: json, includeCovers: true)
        let archive = try TagArchiveIO.load(json)
        #expect(archive.files.first?.artworks == [])

        try EbookTool.writeCover(url: epub, data: try Fixtures.coverData("cover.png"))
        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.applied == ["book2.epub"])
        #expect(try EbookTool.readCover(url: epub) == nil)
    }

    @Test("EPUB ohne archivierte Cover lässt ein späteres Cover unverändert")
    func epubWithoutCoversKeepsLaterCover() throws {
        let dir = try makeFolder(["book2.epub"])
        let epub = dir.appendingPathComponent("book2.epub")
        let original = try EbookTool.readCoreFields(url: epub)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [epub], to: json, includeCovers: false)
        let archive = try TagArchiveIO.load(json)
        #expect(archive.files.first?.artworks == nil)

        var changed = original
        changed.title = "Später geändert"
        try EbookTool.writeCoreFields(url: epub, fields: changed, original: original)
        let replacement = try Fixtures.coverData("cover.png")
        try EbookTool.writeCover(url: epub, data: replacement)

        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.applied == ["book2.epub"])
        #expect(try EbookTool.readCoreFields(url: epub) == original)
        #expect(try EbookTool.readCover(url: epub)?.data == replacement)
    }

    @Test("Leeres Calibre-Cover wird vor allen Archivmutationen abgelehnt", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func emptyCalibreCoverIsRejectedBeforeArchiveWrites() throws {
        let dir = try makeFolder(["sample.mp3", "book.azw3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let azw3 = dir.appendingPathComponent("book.azw3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Vorher")],
                          artworks: [], to: mp3)
        let bytesBefore = try Data(contentsOf: mp3)
        let ebook = try EbookTool.readCoreFields(url: azw3)
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "book.azw3", kind: .ebook, artworks: [], ebook: ebook),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "book.azw3",
            detail: "the target ebook backend cannot safely remove covers"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)

        // nil heißt weiterhin: Cover wurden nicht archiviert. Das ist kein
        // Löschauftrag und muss deshalb auf dem Calibre-Backend erlaubt bleiben.
        let withoutCoverInstruction = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "book.azw3", kind: .ebook, artworks: nil, ebook: ebook),
        ])
        let ebookBytesBefore = try Data(contentsOf: azw3)
        let report = try TagArchiveIO.apply(withoutCoverInstruction,
                                            relativeTo: dir, dryRun: false)
        #expect(report.unchanged == ["book.azw3"])
        #expect(try Data(contentsOf: azw3) == ebookBytesBefore)
    }

    @Test("Ungültiges Archiv wird vor jeder Mutation vollständig abgelehnt")
    func invalidArchiveDoesNotChangeEarlierEntries() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")], to: mp3)
        let before = try TagFile.read(at: mp3)
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Wäre geändert worden"]]),
            .init(path: "zweiter-eintrag.mp3", kind: .audio, properties: nil),
        ])

        #expect(throws: TagArchiveError.self) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try TagFile.read(at: mp3) == before)
    }

    @Test("Symlink-Ziele im Archiv werden vor der ersten Mutation dedupliziert")
    func symlinkArchiveTargetsDoNotMutateFirstEntry() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let alias = dir.appendingPathComponent("alias.mp3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mp3)
        let bytesBefore = try Data(contentsOf: mp3)
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "alias.mp3", kind: .audio,
                  properties: ["TITLE": ["Zweites Ziel"]]),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "alias.mp3",
            detail: "different paths resolve to the same target"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Original")
    }

    @Test("Hardlink-Ziele im Archiv werden vor der ersten Mutation dedupliziert")
    func hardlinkArchiveTargetsDoNotMutateFirstEntry() throws {
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let alias = dir.appendingPathComponent("hardlink.mp3")
        try FileManager.default.linkItem(at: mp3, to: alias)
        let bytesBefore = try Data(contentsOf: mp3)
        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "hardlink.mp3", kind: .audio,
                  properties: ["TITLE": ["Zweites Ziel"]]),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "hardlink.mp3",
            detail: "different paths resolve to the same target"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)
    }

    @Test("Externe Archivziele brauchen eine ausdrückliche Freigabe")
    func externalArchiveTargetRequiresApproval() throws {
        let parent = try makeFolder(["sample.mp3"])
        let base = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let external = parent.appendingPathComponent("sample.mp3")
        let bytesBefore = try Data(contentsOf: external)
        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "../sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Explizit freigegeben"]]),
        ])

        #expect(throws: TagArchiveError.externalTargetRequiresApproval(
            path: "../sample.mp3", resolvedPath: external.path
        )) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false)
        }
        #expect(try Data(contentsOf: external) == bytesBefore)

        let targets = try TagArchiveIO.validatedTargets(
            archive, relativeTo: base, allowExternalTargets: true)
        #expect(targets == [MediaFormats.canonicalFileURL(external)])
        #expect(TagArchiveIO.externalTargets(targets, relativeTo: base) == targets)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(
                archive, relativeTo: base, dryRun: false,
                approvedTargets: [base.appendingPathComponent("anderes-ziel.mp3")])
        }
        #expect(try Data(contentsOf: external) == bytesBefore)

        let report = try TagArchiveIO.apply(
            archive, relativeTo: base, dryRun: false,
            approvedTargets: targets)
        #expect(report.applied == ["../sample.mp3"])
        #expect(try TagFile.read(at: external).firstValue(for: "TITLE")
                == "Explizit freigegeben")
    }

    @Test("Nur bekannte Archivversionen und passende Pflichtdaten werden akzeptiert")
    func archiveSchemaValidation() throws {
        let unsupported = TagArchive(version: 2, created: "2026-07-19T00:00:00Z", files: [])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(unsupported) }

        let missingImage = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: nil),
        ])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(missingImage) }

        let missingEbook = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "book.epub", kind: .ebook, ebook: nil),
        ])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(missingEbook) }
    }
}

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

    @Test("Eine schreibgeschützte Datei stoppt den Batch nicht")
    func batchContinuesAfterOneFailure() throws {
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let flac = dir.appendingPathComponent("sample.flac")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Soll")], to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Soll")], to: flac)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3, flac], to: json, includeCovers: false)

        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Weg")], to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Weg")], to: flac)
        // Eine der beiden Dateien lässt sich nicht schreiben.
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: flac.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: flac.path)
        }

        let report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
                                            relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        #expect(report.failed.map(\.0) == ["sample.flac"])
        // Die gute Datei ist vollständig wiederhergestellt, die andere unberührt.
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Soll")
        #expect(try TagFile.read(at: flac).firstValue(for: "TITLE") == "Weg")
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

    @Test("Leere Audio-Wertlisten werden vor jeder Mutation abgelehnt")
    func emptyAudioPropertyValuesDoNotChangeEarlierEntries() throws {
        // Eine leere Wertliste ist kein darstellbarer PropertyMap-Zustand:
        // `propertyList` erzeugt daraus kein Tag, der nächste Vergleich sähe
        // aber weiterhin `["TITLE": []]` und meldete die Datei wieder als
        // geändert. Die vollständige Archivprüfung muss das erkennen, bevor
        // ein früherer, gültiger Eintrag im selben Batch geschrieben wird.
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        let first = dir.appendingPathComponent("sample.mp3")
        let bytesBefore = try Data(contentsOf: first)
        let archive = TagArchive(created: "2026-08-15T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "sample.flac", kind: .audio,
                  properties: ["TITLE": []]),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "sample.flac",
            detail: "audio property TITLE has no values"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: first) == bytesBefore)
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

    @Test("Atomare Ersetzung am gleichen Pfad nach der Zielprüfung wird abgelehnt")
    func samePathReplacementAfterValidationIsRejected() throws {
        let dir = try makeFolder(["sample.mp3"])
        let target = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Geprüfter Stand")],
            artworks: [], to: target)
        let replacement = dir.appendingPathComponent("replacement.mp3")
        try FileManager.default.copyItem(at: target, to: replacement)
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Fremder Ersatz")],
            artworks: [], to: replacement)
        let replacementBytes = try Data(contentsOf: replacement)
        let archive = TagArchive(created: "2026-08-10T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Archivwert"]], artworks: []),
        ])

        let report = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: false,
            afterValidation: {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: replacement)
            })

        #expect(report.applied.isEmpty)
        #expect(report.failed.map(\.0) == ["sample.mp3"])
        #expect(report.failed.first?.1.contains("targetChangedAfterValidation") == true)
        #expect(try Data(contentsOf: target) == replacementBytes)
        #expect(try TagFile.read(at: target).firstValue(for: "TITLE") == "Fremder Ersatz")
    }

    @Test("Ein Archiv-No-op prüft den verglichenen Stand unmittelbar vor Erfolg")
    func noopChangedAfterComparisonIsRejected() throws {
        let dir = try makeFolder(["sample.mp3"])
        let target = dir.appendingPathComponent("sample.mp3")
        let archive = try TagArchiveIO.build(
            files: [target], baseDirectory: dir, includeCovers: true)

        let report = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: false,
            afterValidation: {},
            beforeNoopReturn: { url in
                try TagFile.write(
                    properties: [TagProperty(key: "TITLE", value: "Fremd nach Vergleich")],
                    artworks: [], to: url)
            })

        #expect(report.unchanged.isEmpty)
        #expect(report.failed.map(\.0) == ["sample.mp3"])
        #expect(try TagFile.read(at: target).firstValue(for: "TITLE")
                == "Fremd nach Vergleich")
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
                approvedTargets: [base.appendingPathComponent("anderes-ziel.mp3")],
                allowExternalTargets: true)
        }
        #expect(try Data(contentsOf: external) == bytesBefore)

        let report = try TagArchiveIO.apply(
            archive, relativeTo: base, dryRun: false,
            approvedTargets: targets, allowExternalTargets: true)
        #expect(report.applied == ["../sample.mp3"])
        #expect(try TagFile.read(at: external).firstValue(for: "TITLE")
                == "Explizit freigegeben")
    }

    @Test("Ein nach der Freigabe untergeschobener Symlink stoppt den Import")
    func symlinkSwappedAfterApprovalIsRejected() throws {
        // Angriffsbild: Zwischen Anzeige/Freigabe der Zielliste und dem
        // Schreiben wird das bestätigte Ziel durch einen Symlink auf eine
        // andere Datei ersetzt. Würden die freigegebenen Pfade beim Vergleich
        // erneut kanonisiert, ergäben beide Seiten denselben NEUEN Pfad und
        // das nie angezeigte Ziel würde überschrieben.
        let parent = try makeFolder(["sample.mp3"])
        let base = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let victim = parent.appendingPathComponent("sample.mp3")
        let victimBytes = try Data(contentsOf: victim)
        let entry = base.appendingPathComponent("entry.mp3")
        try FileManager.default.copyItem(at: victim, to: entry)
        let archive = TagArchive(created: "2026-08-02T00:00:00Z", files: [
            .init(path: "entry.mp3", kind: .audio,
                  properties: ["TITLE": ["Nur für das freigegebene Ziel"]]),
        ])

        // Freigabe auf Basis der ehrlich aufgelösten Liste …
        let approved = try TagArchiveIO.validatedTargets(
            archive, relativeTo: base, allowExternalTargets: true)
        #expect(approved == [MediaFormats.canonicalFileURL(entry)])

        // … dann der Austausch: entry.mp3 zeigt jetzt woandershin.
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: victim)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
                                   approvedTargets: approved,
                                   allowExternalTargets: true)
        }
        #expect(try Data(contentsOf: victim) == victimBytes)

        // Ohne die Freigabe für externe Ziele fällt derselbe Austausch schon
        // eine Stufe früher auf: Das neue Ziel liegt außerhalb des Archivordners.
        #expect(throws: TagArchiveError.externalTargetRequiresApproval(
            path: "entry.mp3", resolvedPath: MediaFormats.canonicalFileURL(victim).path
        )) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
                                   approvedTargets: approved)
        }
        #expect(try Data(contentsOf: victim) == victimBytes)
    }

    @Test("Ein umgebogener interner Symlink stoppt den Import auch ohne externe Ziele")
    func internalRetargetingIsRejectedWithApprovedTargets() throws {
        // Zwischen Prüfung und Schreibweg liegt in der App der Save/Discard-
        // Dialog. Wird das Ziel in diesem Fenster auf eine ANDERE Datei im
        // selben Ordner umgebogen, fällt das nur auf, wenn die geprüfte
        // Zielliste mitgegeben wird — externe Ziele sind hier keine im Spiel.
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        let entry = dir.appendingPathComponent("sample.mp3")
        let other = dir.appendingPathComponent("sample.flac")
        let otherBytes = try Data(contentsOf: other)
        let archive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Nur für das geprüfte Ziel"]]),
        ])
        let approved = try TagArchiveIO.validatedTargets(archive, relativeTo: dir)

        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: other)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false,
                                   approvedTargets: approved)
        }
        #expect(try Data(contentsOf: other) == otherBytes)
    }

    @Test("Ein Serienindex ohne Serie bleibt archivierbar (v1-Kompatibilität)")
    func archiveKeepsSeriesIndexWithoutSeries() throws {
        // Bestehende EPUBs können diesen Zustand tragen (calibre:series_index
        // ohne Serie); Export und ältere v1-Archive müssen ihn behalten
        // dürfen. Ob er sich in ein Ziel schreiben lässt, entscheidet erst
        // der Schreibweg (EbookTool.requireStorableSeries).
        var fields = EbookCoreFields()
        fields.seriesIndex = "2"
        let archive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "book2.epub", kind: .ebook, ebook: fields),
        ])
        #expect(throws: Never.self) { try TagArchiveIO.validate(archive) }
    }

    @Test("Cover: erkennbare Bildformate bleiben gültig, Nicht-Bilder werden abgelehnt")
    func archiveCoverRequiresRecognizableImage() throws {
        // EPUBs können gültige GIF-Cover enthalten — sie müssen archivierbar
        // bleiben (v1-Kompatibilität); die engere JPEG/PNG-Regel gilt nur
        // beim tatsächlichen Cover-Setzen im Schreibweg.
        var gifBytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        gifBytes.append(contentsOf: Array(repeating: 0, count: 8))
        let gif = Artwork(data: Data(gifBytes), mimeType: "image/gif",
                          pictureType: "Front Cover")
        let gifArchive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "book2.epub", kind: .ebook, artworks: [gif],
                  ebook: EbookCoreFields()),
        ])
        #expect(throws: Never.self) { try TagArchiveIO.validate(gifArchive) }

        let junk = Artwork(data: Data("kein Bild, nur Text".utf8), mimeType: "image/jpeg",
                           pictureType: "Front Cover")
        let archive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "book2.epub", kind: .ebook, artworks: [junk],
                  ebook: EbookCoreFields()),
        ])
        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "book2.epub", detail: "ebook cover data is not a recognizable image"
        )) {
            try TagArchiveIO.validate(archive)
        }
    }

    @Test("Fachfremde Bildwerte bleiben strukturell archivierbar")
    func foreignImageValuesRemainStructurallyValid() throws {
        // exiftool liest auch fachlich unmögliche Werte (Rating 6, GPS 91/181)
        // aus bestehenden Bildern. Ein Backup muss genau diesen Bestand
        // sichern können — sonst bricht das Auto-Backup jeden Batch-Save ab.
        // Ob ein Wert ins ZIEL geschrieben werden darf, prüft erst der Import
        // je Eintrag gegen den dort gelesenen Zustand.
        var ratingHigh = ImageCoreFields()
        ratingHigh.rating = 6
        var ratingLow = ImageCoreFields()
        ratingLow.rating = -2
        var gpsOutOfRange = ImageCoreFields()
        gpsOutOfRange.gpsLatitude = "91"
        gpsOutOfRange.gpsLongitude = "181"
        var gpsNotANumber = ImageCoreFields()
        gpsNotANumber.gpsLatitude = "keine Zahl"
        gpsNotANumber.gpsLongitude = "0"
        for fields in [ratingHigh, ratingLow, gpsOutOfRange, gpsNotANumber] {
            let archive = TagArchive(created: "2026-08-02T00:00:00Z", files: [
                .init(path: "cover.jpg", kind: .image, image: fields),
            ])
            #expect(throws: Never.self) { try TagArchiveIO.validate(archive) }
        }
    }

    @Test("Bestand mit fachfremden Bildwerten ist exportier- und wiederherstellbar")
    func foreignImageValuesStayExportable() throws {
        // Genau der Auto-Backup-Fall: Ein Bild trägt ein von exiftool
        // gelesenes, fachfremdes Rating. Der Export (== Auto-Backup vor einem
        // Batch-Save) darf daran nicht scheitern, und der unveränderte
        // Bestand muss als No-op wiederherstellbar bleiben.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=6", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 6)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)
        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)
        #expect(report.unchanged == ["cover.jpg"])
        #expect(report.failed.isEmpty)
    }

    @Test("Ein gesicherter Bestandswert kommt auch nach einer Änderung zurück")
    func archivedForeignImageValueRestoresAfterChange() throws {
        // Der Kern des Restore-Vertrags (Review-Fund 2026-08-17): Rating 6
        // exportieren, das Ziel danach auf 5 ändern, wieder auf 6 importieren.
        // Vorher lehnte genau dieser Import ab, weil er die Wertebereiche der
        // Oberfläche auch auf archivierte Bestandswerte anwandte — ein
        // erfolgreich erzeugtes Auto-Backup war damit nicht wiederherstellbar.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=6", image.path])

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        // Ziel danach auf einen gültigen Wert ändern.
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=5", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 5)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failed.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == 6)
    }

    @Test("Ein gesichertes negatives Bestands-Rating kommt exakt zurück")
    func archivedNegativeRatingRestoresExactly() throws {
        // Derselbe Vertrag nach unten (Review-Fund 2026-08-18): Leerwert ist
        // ausschließlich -1. Ein gesichertes -2 bildete der Schreibweg vorher
        // auf „Rating-Tag löschen" ab; die Datei trug danach -1, und der
        // Read-back meldete den Fehlschlag erst NACH dem atomaren Austausch.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=-2", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == -2)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        // Zwischenzeitliche Änderung auf einen normalen Wert.
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=3", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 3)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failed.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == -2)
    }

    // MARK: - Review-Fund 2026-08-20

    @Test("Ein gesichertes Rating -1 wird zurueckgeschrieben, nicht geloescht")
    func archivedRejectedRatingRestoresExactly() throws {
        // -1 ist der von Adobe dokumentierte Wert fuer „abgelehnt" und wird von
        // Bridge und Lightroom wirklich geschrieben. Solange -1 zugleich der
        // Leerwert war, loeschte der Restore genau dieses Tag — und der
        // Read-back konnte den Fehler nicht sehen, weil er das geloeschte Tag
        // wieder als -1 las.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=-1", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == -1)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=3", image.path])
        #expect(try ExifTool.readCoreFields(url: image).rating == 3)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.failed.isEmpty)
        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == -1)
    }

    @Test("Ohne Rating-Tag bleibt das Feld leer und der Restore loescht es wieder")
    func missingRatingStaysAbsent() throws {
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        #expect(try ExifTool.readCoreFields(url: image).rating == nil)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [image], to: json, includeCovers: false)

        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(
            exe, ["-overwrite_original", "-m", "-XMP:Rating=4", image.path])

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)

        #expect(report.applied == ["cover.jpg"])
        #expect(try ExifTool.readCoreFields(url: image).rating == nil)
    }

    @Test("Im alten Schema 1 bleibt -1 der Leerwert")
    func legacySchemaTreatsMinusOneAsAbsent() throws {
        // Schema 1 konnte „kein Tag" und „Tag mit -1" nicht unterscheiden und
        // schrieb fuer beides -1. Ein solcher Bestand darf beim Import kein
        // -1-Tag in eine Datei schreiben, die vorher keines hatte.
        var fields = ImageCoreFields()
        fields.rating = -1
        let legacy = TagArchive(version: 1, created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: fields),
        ])

        let normalized = TagArchiveIO.normalizingLegacyValues(legacy)
        #expect(normalized.files[0].image?.rating == nil)

        // Ein Archiv im heutigen Schema behaelt die -1 dagegen.
        let current = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: fields),
        ])
        #expect(TagArchiveIO.normalizingLegacyValues(current).files[0].image?.rating == -1)
    }

    @Test("Technisch unschreibbare Archivwerte scheitern je Eintrag — Dry-run und Import gleich")
    func unwritableImageValuesFailConsistently() throws {
        // Die Wertebereiche gelten beim Restore nicht mehr, die TECHNISCHEN
        // Schranken schon: Eine halbe GPS-Koordinate kann exiftool nicht
        // sinnvoll schreiben. Der Fehler muss im Dry-run genauso erscheinen wie
        // im echten Lauf, und die Zieldatei bleibt unangetastet (insbesondere
        // entsteht keine Papierkorb-Sicherung vor dem Fehler).
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        var target = try ExifTool.readCoreFields(url: image)
        target.gpsLatitude = "48.1"
        target.gpsLongitude = ""          // unvollständiges Paar
        let archive = TagArchive(created: "2026-08-16T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: target),
        ])

        let dry = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: true)
        #expect(dry.failed.map(\.0) == ["cover.jpg"])
        let bytesBefore = try Data(contentsOf: image)
        let real = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(real.failed.map(\.0) == ["cover.jpg"])
        #expect(try Data(contentsOf: image) == bytesBefore)
    }

    @Test("Die Oberfläche lehnt eine echte Änderung auf fachfremde Werte weiter ab")
    func uiStillRejectsOutOfRangeChanges() throws {
        // Gegenprobe zur Trennung: Der Restore-Pfad ist gelockert, der
        // Bearbeitungspfad NICHT.
        let dir = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("cover.jpg")
        let current = try ExifTool.readCoreFields(url: image)
        var target = current
        target.rating = 6

        #expect(throws: (any Error).self) {
            try ExifTool.requireValidCoreFields(target, original: current)
        }
        #expect(throws: Never.self) {
            try ExifTool.requireWritableCoreFields(target, original: current)
        }
    }

    @Test("EPUB: Serienindex ohne Serie wird aus dem Archiv wiederhergestellt")
    func epubBareSeriesIndexRestores() throws {
        // Fremde EPUBs können calibre:series_index ohne Serie tragen. Der
        // Export sichert den Zustand; wurde die Serie im Ziel danach
        // geändert, muss der Import ihn wieder herstellen können.
        let dir = try makeFolder(["book2.epub"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let epub = dir.appendingPathComponent("book2.epub")
        let original = try EbookTool.readCoreFields(url: epub)
        var bare = original
        bare.series = ""
        bare.seriesIndex = "2.5"
        try EbookTool.write(url: epub, fields: bare, original: original,
                            coverUpdate: .unchanged)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [epub], to: json, includeCovers: true)

        var changed = try EbookTool.readCoreFields(url: epub)
        changed.series = "Zwischenzeitliche Serie"
        changed.seriesIndex = "1"
        try EbookTool.write(url: epub, fields: changed, original: bare,
                            coverUpdate: .unchanged)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)
        #expect(report.applied == ["book2.epub"])
        #expect(report.failed.isEmpty)
        let restored = try EbookTool.readCoreFields(url: epub)
        #expect(restored.series.isEmpty)
        #expect(restored.seriesIndex == "2.5")
    }

    @Test("EPUB: GIF-Cover aus dem Archiv wird wiederhergestellt")
    func epubGifCoverRestores() throws {
        // Export akzeptiert jedes erkennbare Coverformat; der EPUB-Schreibweg
        // muss die EPUB-Kernformate (hier GIF) dann auch wieder SETZEN können —
        // sonst widersprächen sich Export- und Import-Vertrag.
        let dir = try makeFolder(["book2.epub"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let epub = dir.appendingPathComponent("book2.epub")
        var gifBytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        gifBytes.append(contentsOf: Array(repeating: 0, count: 8))
        let gif = Data(gifBytes)
        let fields = try EbookTool.readCoreFields(url: epub)
        try EbookTool.write(url: epub, fields: fields, original: fields,
                            coverUpdate: .set(gif))
        #expect(try EbookTool.readCover(url: epub)?.data == gif)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [epub], to: json, includeCovers: true)

        // Zwischenzeitlich bekommt das Ziel ein anderes Cover.
        let png = try Fixtures.coverData("cover.png")
        try EbookTool.write(url: epub, fields: fields, original: fields,
                            coverUpdate: .set(png))
        #expect(try EbookTool.readCover(url: epub)?.data == png)

        let report = try TagArchiveIO.apply(
            try TagArchiveIO.load(json), relativeTo: dir, dryRun: false)
        #expect(report.applied == ["book2.epub"])
        #expect(report.failed.isEmpty)
        #expect(try EbookTool.readCover(url: epub)?.data == gif)
    }

    @Test("Ein Serienwunsch für ein PDF wird vor jeder Mutation abgelehnt",
          .enabled(if: FileManager.default.fileExists(
              atPath: Fixtures.directory.appendingPathComponent("book.pdf").path),
              "PDF-Fixture fehlt (braucht sips)"))
    func pdfSeriesIsRejectedBeforeArchiveWrites() throws {
        // PDF hat keinen Serien-Ort; das Backend ignoriert das Feld still.
        // Ohne Vorprüfung meldete der Import Erfolg, ohne den Wert zu schreiben.
        let dir = try makeFolder(["sample.mp3", "book.pdf"])
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let bytesBefore = try Data(contentsOf: mp3)
        var ebook = try EbookTool.readCoreFields(url: dir.appendingPathComponent("book.pdf"))
        ebook.series = "Nicht speicherbar"
        let archive = TagArchive(created: "2026-08-02T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "book.pdf", kind: .ebook, ebook: ebook),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "book.pdf",
            detail: "the target ebook format cannot store a series"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)
    }

    @Test("Schnell aufeinanderfolgende Backups überschreiben sich nicht")
    func rapidBackupsGetDistinctFileNames() throws {
        // Der Namens-Zeitstempel ist nur sekundengenau — mehrere Backups
        // desselben Ordners innerhalb einer Sekunde brauchen trotzdem je
        // eine eigene Datei.
        let dir = try makeFolder(["sample.mp3"])
        let mp3 = dir.appendingPathComponent("sample.mp3")

        var written: [URL] = []
        for _ in 1...3 {
            written.append(contentsOf: try TagArchiveIO.writeBackups(files: [mp3]))
        }

        #expect(Set(written.map(\.path)).count == 3)
        for url in written {
            // Jede Datei existiert und ist ein vollständiges, ladbares Archiv
            // (keine leere Reservierung, kein überschriebener Stand).
            let archive = try TagArchiveIO.load(url)
            #expect(archive.files.map(\.path) == ["sample.mp3"])
        }
    }

    @Test("Nur bekannte Archivversionen und passende Pflichtdaten werden akzeptiert")
    func archiveSchemaValidation() throws {
        let unsupported = TagArchive(version: TagArchive.currentVersion + 1,
                                     created: "2026-07-19T00:00:00Z", files: [])
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

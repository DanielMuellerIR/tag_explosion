import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

extension TagArchiveTests {
    // MARK: - Audio

    @Test("Lesbare überlappende Kapitel und leere SYLT bleiben archivierbar und wiederherstellbar",
          arguments: ["chapters", "sylt", "both"])
    func archivesLegacyAudioDetails(_ detail: String) throws {
        let folder = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.mp3")
        try ID3TestFixtures.installLegacyDetails(at: url, overlappingChapters: detail != "sylt",
                                                  emptySyncedLyrics: detail != "chapters")
        let original = try TagFile.read(at: url)
        #expect(original.chapters.count == (detail == "sylt" ? 0 : 2))
        if detail != "sylt" {
            #expect(original.chapters[1].startMilliseconds < original.chapters[0].endMilliseconds)
        }
        #expect(original.syncedLyrics.isEmpty)
        #expect(original.syncedLyricsLanguage == (detail == "chapters" ? "" : "eng"))
        let json = folder.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [url], to: json, includeCovers: true)
        let archive = try TagArchiveIO.load(json)
        #expect(archive.files[0].chapters == original.chapters)
        #expect(archive.files[0].syncedLyricsLanguage == original.syncedLyricsLanguage)
        #expect(try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false).unchanged == ["sample.mp3"])
        try TagFile.write(chapters: [], syncedLyrics: [], to: url)
        let dryRun = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: true)
        #expect(dryRun.applied == ["sample.mp3"])
        let report = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false)
        #expect(report.failures.isEmpty)
        #expect(report.applied == ["sample.mp3"])
        let restored = try TagFile.read(at: url)
        #expect(restored.chapters == original.chapters)
        #expect(restored.syncedLyrics.isEmpty)
        #expect(restored.syncedLyricsLanguage == original.syncedLyricsLanguage)
        #expect(try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false).unchanged == ["sample.mp3"])
        // Die normale Bearbeitung bleibt streng; [] entfernt auch restaurierte leere Frames.
        if !original.chapters.isEmpty {
            var edited = original.chapters
            edited[0].title = "Geändert"
            #expect(throws: TagError.self) { try TagFile.write(chapters: edited, to: url) }
        }
        try TagFile.write(syncedLyrics: [], to: url)
        #expect(try TagFile.read(at: url).syncedLyricsLanguage.isEmpty)
        if detail != "chapters" {
            _ = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false)
            // Ein handgebautes Archiv ohne gesicherte Sprache verlangt nur
            // das Leeren der Zeilen, keinen leeren Frame mit geerbter Sprache.
            var cleared = archive
            cleared.files[0].syncedLyricsLanguage = nil
            try TagFile.write(syncedLyrics: [.init(milliseconds: 0, text: "Text")],
                              syncedLyricsLanguage: "eng", to: url)
            let result = try TagArchiveIO.apply(cleared, relativeTo: folder, dryRun: false)
            #expect(result.failures.isEmpty)
            #expect(try TagFile.read(at: url).syncedLyricsLanguage.isEmpty)
        }
    }

    @Test("Audioarchive stellen Kapitel, Lyrics und unabhängige Sprachen wieder her", arguments: ["chapters", "synced", "uslt", "sylt"])
    func restoresAudioDetails(_ field: String) throws {
        let folder = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sample.mp3")
        let chapters = [Chapter(title: "Intro", startMilliseconds: 0, endMilliseconds: 1000)]
        let lines = [SyncedLyricLine(milliseconds: 0, text: "Original")]
        try TagFile.write(properties: [TagProperty(key: "LYRICS", value: "Text")],
                          chapters: chapters, syncedLyrics: lines, lyricsLanguage: "eng",
                          syncedLyricsLanguage: "deu", to: url)
        let original = try TagFile.read(at: url)
        let archive = try TagArchiveIO.build(files: [url], baseDirectory: folder, includeCovers: false)
        #expect(archive.version == 5)
        #expect(archive.files[0].artworks == nil)
        switch field {
        case "chapters": try TagFile.write(chapters: [], to: url)
        case "synced": try TagFile.write(syncedLyrics: [SyncedLyricLine(milliseconds: 500, text: "Geändert")], to: url)
        case "uslt": try TagFile.write(lyricsLanguage: "fra", to: url)
        default: try TagFile.write(syncedLyricsLanguage: "fra", to: url)
        }
        let report = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        #expect(report.failures.isEmpty)
        let restored = try TagFile.read(at: url)
        #expect(restored.chapters == original.chapters)
        #expect(restored.syncedLyrics == original.syncedLyrics)
        #expect(restored.lyricsLanguage == "eng")
        #expect(restored.syncedLyricsLanguage == "deu")
        #expect(try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: true).unchanged == ["sample.mp3"])
    }

    @Test("Alte Archive lassen nicht gesicherte Kapitel und Lyrics unverändert", arguments: [1, 2, 3, 4])
    func oldSchemaDoesNotClearAudioDetails(_ version: Int) throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let chapters = [Chapter(title: "Intro", startMilliseconds: 0, endMilliseconds: 1000)]
        let lines = [SyncedLyricLine(milliseconds: 0, text: "Original")]
        try TagFile.write(chapters: chapters, syncedLyrics: lines, syncedLyricsLanguage: "deu", to: mp3)
        let json = dir.appendingPathComponent("old-tags.json")
        try Data("""
            {"version": \(version), "created": "2026-10-06T00:00:00Z", "files": [
                {"path": "sample.mp3", "kind": "audio", "properties": {"TITLE": ["Archiv"]}}
            ]}
            """.utf8).write(to: json)
        let decoded = try TagArchiveIO.load(json)
        #expect(decoded.files[0].chapters == nil)
        #expect(decoded.files[0].syncedLyrics == nil)
        var invalid = decoded
        invalid.files[0].chapters = []
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(invalid) }
        let report = try TagArchiveIO.apply(decoded, relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        let restored = try TagFile.read(at: mp3)
        #expect(restored.firstValue(for: "TITLE") == "Archiv")
        #expect(restored.chapters == chapters)
        #expect(restored.syncedLyrics == lines)
        #expect(restored.syncedLyricsLanguage == "deu")
    }

    @Test("NUL und ungültige Kapitel im zweiten Eintrag scheitern vor jeder Mutation", arguments: [false, true])
    func invalidAudioDetailsPreventPartialImport(nul: Bool) throws {
        let folder = try makeFolder(["sample.mp3", "sample.flac"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("sample.mp3")
        let before = try Data(contentsOf: first)
        let second = TagArchive.Entry(path: "sample.flac", kind: .audio,
            properties: nul ? ["TITLE": ["vor\0nach"]] : [:],
            chapters: nul ? nil : [Chapter(title: "Unzulässig", startMilliseconds: 0, endMilliseconds: 1000)])
        let archive = TagArchive(created: "2026-10-06T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio, properties: ["TITLE": ["Geändert"]]), second,
        ])
        #expect(throws: (any Error).self) { _ = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false) }
        #expect(try Data(contentsOf: first) == before)
    }

    /// Der Export sichert den Bestand, auch fachfremde Altwerte — deshalb muss
    /// der Import sie zurückschreiben können. Für Bilder gilt das schon
    /// ausdrücklich; beim Audio-Zweig lehnte die Wertebereichsprüfung in
    /// `TagFile.write` genau die Werte ab, die das eigene Backup enthielt
    /// (Review-Fund 2026-09-10).
    @Test("Ein gesicherter Altwert außerhalb des Wertebereichs lässt sich zurückspielen")
    func archiveRestoresArchivedOutOfRangeValue() throws {
        let dir = try makeFolder(["sample.flac"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let flac = dir.appendingPathComponent("sample.flac")
        let json = dir.appendingPathComponent("backup.json")

        // Bestand, wie ihn ältere ReplayGain-Werkzeuge hinterlassen: außerhalb
        // des von uns geprüften Bereichs −60…+60 dB.
        let legacy = TagProperty(key: FixedFields.replayGainTrackGain, value: "-99.00 dB")
        var properties = try TagFile.read(at: flac).properties
        properties.append(legacy)
        try TagFile.write(properties: properties, to: flac, allowingArchivedValues: true)

        try TagArchiveIO.export(files: [flac], to: json, includeCovers: false)
        let archive = try TagArchiveIO.load(json)

        // Fremdänderung: Der Wert verschwindet aus der Datei.
        let without = try TagFile.read(at: flac).properties.filter { $0.key != legacy.key }
        try TagFile.write(properties: without, to: flac)
        #expect(!(try TagFile.read(at: flac).properties.contains(legacy)))

        // Vorschau und echter Lauf müssen übereinstimmen.
        let preview = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: true)
        #expect(preview.applied.count == 1)
        #expect(preview.failures.isEmpty)
        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.failures.isEmpty)
        #expect(try TagFile.read(at: flac).properties.contains(legacy))
    }

    @Test("Audio: Export → Ändern → Import stellt Tags und Cover wieder her")
    func audioRestore() throws {
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        defer { try? FileManager.default.removeItem(at: dir) }
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
        #expect(report.failures.isEmpty)

        let restored = try TagFile.read(at: mp3)
        #expect(restored.firstValue(for: "TITLE") == "Original")
        #expect(restored.values(for: "GENRE") == ["Bebop", "Jazz"]
            || restored.values(for: "GENRE") == ["Jazz", "Bebop"])
        #expect(restored.artworks.first?.data == cover)
    }

    @Test("--without-covers lässt vorhandene Cover beim Import unangetastet")
    func withoutCoversKeepsArtworks() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
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

    @Test("Explizit leere Audio-Cover werden exportiert und beim Import entfernt")
    func emptyAudioCoverRemovesLaterCover() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
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

    @Test("Leere Audio-Wertlisten werden vor jeder Mutation abgelehnt")
    func emptyAudioPropertyValuesDoNotChangeEarlierEntries() throws {
        // Eine leere Wertliste ist kein darstellbarer PropertyMap-Zustand:
        // `propertyList` erzeugt daraus kein Tag, der nächste Vergleich sähe
        // aber weiterhin `["TITLE": []]` und meldete die Datei wieder als
        // geändert. Die vollständige Archivprüfung muss das erkennen, bevor
        // ein früherer, gültiger Eintrag im selben Batch geschrieben wird.
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        defer { try? FileManager.default.removeItem(at: dir) }
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

    // MARK: - E-Books und Dokumente

    private static let calibreFixtureAvailable = EbookTool.calibreAvailable
        && FileManager.default.fileExists(
            atPath: Fixtures.directory.appendingPathComponent("book.azw3").path)

    @Test("Explizit leere EPUB-Cover werden exportiert und beim Import entfernt")
    func emptyEpubCoverRemovesLaterCover() throws {
        let dir = try makeFolder(["book2.epub"])
        defer { try? FileManager.default.removeItem(at: dir) }
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
        defer { try? FileManager.default.removeItem(at: dir) }
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
        defer { try? FileManager.default.removeItem(at: dir) }
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
        #expect(report.failures.isEmpty)
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
        #expect(report.failures.isEmpty)
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
        defer { try? FileManager.default.removeItem(at: dir) }
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

    @Test("Dokumente: Export → Ändern → Import stellt Felder wieder her, unspeicherbare Felder scheitern vorab")
    func documentRestore() throws {
        let dir = try makeFolder(["doc.docx", "doc.odt", "comic.cbz"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let docx = dir.appendingPathComponent("doc.docx")
        let odt = dir.appendingPathComponent("doc.odt")
        let cbz = dir.appendingPathComponent("comic.cbz")
        let files = [docx, odt, cbz]
        let originals = try files.map { try DocumentTool.readCoreFields(url: $0) }
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: files, to: json, includeCovers: true)

        for (url, original) in zip(files, originals) {
            var changed = original
            changed.title = "Weg"
            changed.authors = ["Niemand"]
            try DocumentTool.write(url: url, fields: changed, original: original)
        }
        let archive = try TagArchiveIO.load(json)
        // Das CBZ-Cover ist reine Anzeige und wird nie archiviert.
        #expect(archive.files.allSatisfy { $0.kind == .document && $0.artworks == nil })

        let preview = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: true)
        #expect(preview.applied.sorted() == ["comic.cbz", "doc.docx", "doc.odt"])
        #expect(try DocumentTool.readCoreFields(url: docx).title == "Weg")

        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.applied.sorted() == ["comic.cbz", "doc.docx", "doc.odt"])
        #expect(report.failures.isEmpty)
        for (url, original) in zip(files, originals) {
            #expect(try DocumentTool.readCoreFields(url: url) == original)
        }
        #expect(try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false).unchanged.count == 3)

        // Ein Archiv, das dem Ziel ein Feld ohne Speicherort zuweist, scheitert
        // je Eintrag — vor der Sicherung, auch im Dry-run — statt Erfolg zu melden.
        var hostile = archive
        hostile.files[0].document?.publisher = "Kein Ort in OOXML"
        let rejected = try TagArchiveIO.apply(hostile, relativeTo: dir, dryRun: true)
        #expect(rejected.failures.map(\.path) == [archive.files[0].path])
        #expect(rejected.failures.first?.message.contains("publisher") == true)
    }

    // MARK: - Medienübergreifend

    @Test("Bild und EPUB: Import stellt Kernfelder wieder her")
    func imageAndEbookRestore() throws {
        let dir = try makeFolder(["cover.jpg", "book2.epub"])
        defer { try? FileManager.default.removeItem(at: dir) }
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
}

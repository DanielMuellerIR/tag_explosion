// E-Book-Metadaten: Lesen/Roundtrip für EPUB 2, EPUB 3, PDF (exiftool) und —
// falls Calibre installiert ist — azw3 via ebook-meta.
import Foundation
import Testing
@testable import TagExplosionCore
import ZIPFoundation

@Suite("EbookTool", .serialized)
struct EbookToolTests {

    /// Testing überspringt die optionalen Calibre-Prüfungen sichtbar statt sie
    /// mit `guard { return }` still grün erscheinen zu lassen.
    private static let calibreFixtureAvailable = EbookTool.calibreAvailable
        && FileManager.default.fileExists(
            atPath: Fixtures.directory.appendingPathComponent("book.azw3").path)
    private static let calibreConversionAvailable: Bool = {
        guard let meta = try? EbookTool.locateCalibre() else { return false }
        let converter = URL(fileURLWithPath: meta)
            .deletingLastPathComponent()
            .appendingPathComponent("ebook-convert")
        return FileManager.default.isExecutableFile(atPath: converter.path)
    }()

    /// Voll ausgefüllte Felder für den Schreib-Roundtrip.
    private var editedFields: EbookCoreFields {
        var fields = EbookCoreFields()
        fields.title = "Änderungstest № 1"
        fields.authors = ["Neue Autorin", "Zweiter Autor"]
        fields.series = "Neue Reihe"
        fields.seriesIndex = "7"
        fields.description = "Geänderter Klappentext mit Ümläuten."
        fields.isbn = "9781566199094"
        fields.publisher = "Neuer Verlag"
        fields.language = "fr"
        fields.date = "2023-11-05"
        fields.subjects = ["Neu", "Geändert"]
        return fields
    }

    // MARK: - EPUB 2

    @Test("EPUB 2: bekannte Felder lesen")
    func epub2Read() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let fields = try EbookTool.readCoreFields(url: url)
        #expect(fields.title == "Testbuch Zwei")
        #expect(fields.authors == ["Erika Beispiel"])
        #expect(fields.series == "Testreihe")
        #expect(fields.seriesIndex == "2")
        #expect(fields.description == "Ein kleines Testbuch.")
        #expect(fields.isbn == "9783161484100")
        #expect(fields.publisher == "Testverlag")
        #expect(fields.language == "de")
        #expect(fields.date == "2020-01-01")
        #expect(fields.subjects == ["Test", "Fixtures"])
    }

    @Test("EPUB 2: Roundtrip aller Felder")
    func epub2Roundtrip() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == editedFields)
    }

    @Test("EPUB 2: Felder löschen")
    func epub2Delete() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        var cleared = original
        cleared.series = ""
        cleared.seriesIndex = ""
        cleared.description = ""
        cleared.isbn = ""
        cleared.subjects = []
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == cleared)
        // Titel/Autor blieben unangetastet
        #expect(readBack.title == "Testbuch Zwei")
    }

    @Test("EPUB 2: Cover lesen und ersetzen")
    func epub2Cover() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let cover = try #require(try EbookTool.readCover(url: url))
        #expect(cover.resolvedMimeType == "image/jpeg")
        #expect(cover.data == (try Fixtures.coverData("cover.jpg")))

        let replacement = try Fixtures.coverData("cover.png")
        try EbookTool.writeCover(url: url, data: replacement)
        let readBack = try #require(try EbookTool.readCover(url: url))
        #expect(readBack.data == replacement)
        #expect(readBack.resolvedMimeType == "image/png")
        // Metadaten haben den Cover-Tausch überlebt
        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
    }

    @Test("EPUB: Read-Pfade funktionieren bei schreibgeschützter Datei")
    func epubReadOnlyStillReadsMetadataAndCover() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let bytesBefore = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
        #expect(try EbookTool.readCover(url: url)?.data == Fixtures.coverData("cover.jpg"))
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Darf nicht speichern"
        #expect(throws: TagError.saveFailed(path: url.path)) {
            try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
        }
        #expect(throws: TagError.saveFailed(path: url.path)) {
            try EbookTool.writeCover(url: url, data: try Fixtures.coverData("cover.png"))
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
    }

    @Test("Felder und Cover können nicht aus zwei EPUB-Fassungen gemischt werden")
    func ebookSnapshotRejectsReplacementBetweenFieldAndCoverRead() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let replacement = try Fixtures.workingCopy("book3.epub")
        let replacementBytes = try Data(contentsOf: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            _ = try EbookTool.readSnapshot(
                url: url, includeCover: true,
                betweenReads: {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
                })
        }
        #expect(try Data(contentsOf: url) == replacementBytes)
    }

    @Test("E-Book-No-op bestätigt keinen inzwischen ersetzten Pfad")
    func ebookNoopRejectsStaleSnapshot() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let snapshot = try EbookTool.readSnapshot(url: url, includeCover: true)
        let replacement = try Fixtures.workingCopy("book2.epub")
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            try EbookTool.write(
                url: url, fields: snapshot.value.fields,
                original: snapshot.value.fields, coverUpdate: .unchanged,
                expecting: snapshot.stamp)
        }
    }

    // MARK: - EPUB 3

    @Test("EPUB 3: bekannte Felder lesen")
    func epub3Read() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let fields = try EbookTool.readCoreFields(url: url)
        #expect(fields.title == "Testbuch Drei")
        #expect(fields.authors == ["Max Muster", "Erika Beispiel"])
        #expect(fields.series == "Dreierreihe")
        #expect(fields.seriesIndex == "3")
        #expect(fields.isbn == "9780306406157")
        #expect(fields.language == "en")
        #expect(fields.date == "2021-06-15")
    }

    @Test("EPUB 3: Roundtrip aller Felder")
    func epub3Roundtrip() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == editedFields)
    }

    @Test("EPUB 3: Cover lesen (properties=cover-image)")
    func epub3Cover() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let cover = try #require(try EbookTool.readCover(url: url))
        #expect(cover.resolvedMimeType == "image/png")
    }

    @Test("EPUB 3: Prozentkodierte Cover-Pfade werden aufgelöst")
    func epub3CoverResolvesPercentEncodedHref() throws {
        // Manifest-hrefs sind URLs. Leerzeichen stehen dort als %20, während
        // der ZIP-Eintrag den dekodierten Dateinamen trägt.
        let url = try Fixtures.workingCopy("book3.epub")
        let expected = try Fixtures.coverData("cover.png")
        do {
            let archive = try Archive(url: url, accessMode: .update)
            let old = try #require(archive["OEBPS/cover.png"])
            try archive.remove(old)
            try archive.addEntry(
                with: "OEBPS/cover image.png", type: .file,
                uncompressedSize: Int64(expected.count), compressionMethod: .deflate
            ) { position, size in
                expected.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(of: "href=\"cover.png\"",
                                     with: "href=\"cover%20image.png\"")
        }

        #expect(try EbookTool.readCover(url: url)?.data == expected)
    }

    @Test("EPUB: mimetype bleibt erster, unkomprimierter Eintrag")
    func epubMimetypeStaysFirst() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        // Ein konformes EPUB beginnt mit dem Local-File-Header von "mimetype"
        // (Offset 30: Dateiname) und direkt danach dem unkomprimierten Inhalt.
        let data = try Data(contentsOf: url)
        let prefix = String(decoding: data[30..<(30 + 8 + 20)], as: UTF8.self)
        #expect(prefix == "mimetypeapplication/epub+zip")
    }

    @Test("EPUB: fehlgeschlagene Temp-Mutation lässt das Original bytegleich")
    func epubAtomicRewriteFailureKeepsOriginal() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let before = try Data(contentsOf: url)

        #expect(throws: TagError.self) {
            try AtomicFileRewrite.run(url: url) { temp in
                try Data("kein EPUB".utf8).write(to: temp)
            } validate: { _ in
                throw TagError.cannotOpen(path: url.path)
            }
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
    }

    @Test("EPUB: Cover-Zyklus erzeugt eindeutige Manifest-IDs und -Pfade")
    func epubCoverCycleAvoidsManifestCollisions() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        try EbookTool.removeCover(url: url)
        try EbookTool.writeCover(url: url, data: try Fixtures.coverData("cover.png"))
        try EbookTool.removeCover(url: url)
        let replacement = try Fixtures.coverData("cover.jpg")
        try EbookTool.writeCover(url: url, data: replacement)
        #expect(try EbookTool.readCover(url: url)?.data == replacement)

        let archive = try Archive(url: url, accessMode: .read)
        let opf = try #require(archive["OEBPS/content.opf"])
        var data = Data()
        _ = try archive.extract(opf) { data.append($0) }
        let xml = String(decoding: data, as: UTF8.self)
        #expect(xml.components(separatedBy: "id=\"cover-tagx\"").count == 2)
        #expect(xml.components(separatedBy: "id=\"cover-tagx-2\"").count == 2)
        #expect(xml.components(separatedBy: "href=\"cover-tagx.png\"").count == 2)
        #expect(xml.components(separatedBy: "href=\"cover-tagx-2.jpg\"").count == 2)
    }

    @Test("EPUB: Neue Cover-ID weicht jeder OPF-ID außerhalb des Manifests aus")
    func epubCoverIdAvoidsIdsOutsideManifest() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        try EbookTool.removeCover(url: url)
        try rewriteOpf(in: url, path: "OEBPS/content.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator opf:role=\"aut\">Erika Beispiel</dc:creator>",
                with: "<dc:creator id=\"cover-tagx\" opf:role=\"aut\">Erika Beispiel</dc:creator>")
        }

        let replacement = try Fixtures.coverData("cover.png")
        try EbookTool.writeCover(url: url, data: replacement)

        let xml = try opfContents(of: url, path: "OEBPS/content.opf")
        #expect(xml.components(separatedBy: "id=\"cover-tagx\"").count - 1 == 1)
        #expect(xml.contains("id=\"cover-tagx-2\""))
        #expect(xml.contains("content=\"cover-tagx-2\""))
        #expect(try EbookTool.readCover(url: url)?.data == replacement)
    }

    // MARK: - PDF (exiftool)

    @Test("PDF: Roundtrip der unterstützten Felder")
    func pdfRoundtrip() throws {
        guard FileManager.default.fileExists(
            atPath: Fixtures.directory.appendingPathComponent("book.pdf").path) else {
            return // Fixture braucht sips (macOS)
        }
        let url = try Fixtures.workingCopy("book.pdf")
        let original = try EbookTool.readCoreFields(url: url)
        var edited = editedFields
        // PDF kennt keine Serie — die Felder bleiben leer
        edited.series = ""
        edited.seriesIndex = ""
        try EbookTool.writeCoreFields(url: url, fields: edited, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == edited)
    }

    @Test("PDF: Serie und Cover gelten als nicht unterstützt")
    func pdfCapabilities() throws {
        let url = URL(fileURLWithPath: "/tmp/x.pdf")
        #expect(!EbookTool.supportsSeries(url: url))
        #expect(!EbookTool.supportsCover(url: url))
        let epub = URL(fileURLWithPath: "/tmp/x.epub")
        #expect(EbookTool.supportsSeries(url: epub))
        #expect(EbookTool.supportsCover(url: epub))
    }

    // MARK: - Calibre (nur falls installiert)

    @Test("azw3: Roundtrip via ebook-meta", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func azw3Roundtrip() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        var edited = editedFields
        // ebook-meta normalisiert Sprachcodes auf ISO-639-2 ("fra")
        edited.language = "fra"
        try EbookTool.writeCoreFields(url: url, fields: edited, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.title == edited.title)
        #expect(readBack.authors == edited.authors)
        // Serie wird von ebook-meta bei azw3 nicht persistiert (verifiziert mit
        // Calibre 7.7; EPUB kann es) — siehe knowledge/ebook-meta-calibre-quirks.md.
        #expect(readBack.isbn == edited.isbn)
        #expect(readBack.publisher == edited.publisher)
        #expect(readBack.subjects == edited.subjects)
        #expect(readBack.date == edited.date)
    }

    @Test("E-Book-Transaktion rollt Kernfelder bei Cover-Fehler zurück", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func ebookTransactionRollsBackFieldsWhenCoverStepFails() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        let bytesBefore = try Data(contentsOf: url)
        var changed = original
        changed.title = "Darf nicht teilweise bleiben"

        #expect(throws: TagError.self) {
            try EbookTool.write(
                url: url, fields: changed, original: original,
                coverUpdate: .remove)
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(try EbookTool.readCoreFields(url: url).title == original.title)
    }

    @Test("Calibre: leeres Datum ersetzt den alten Wert durch den Undefined-Date-Sentinel", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func calibreEmptyDateUsesUndefinedSentinel() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let oldDate = "2023-11-05"
        var changed = try EbookTool.readCoreFields(url: url)
        changed.date = oldDate
        try EbookTool.writeCoreFields(url: url, fields: changed,
                                      original: try EbookTool.readCoreFields(url: url))
        #expect(try directCalibreOutput(url: url).contains(oldDate))

        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.date = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)

        // ebook-meta selbst ist der maßgebliche Read-back: Der alte Wert darf
        // nicht nur im eigenen Parser verschwinden.
        let output = try directCalibreOutput(url: url)
        #expect(!output.contains(oldDate))
        #expect(output.contains("Published"))
        #expect(output.contains("0101-01-01"))
        #expect(try EbookTool.readCoreFields(url: url).date.isEmpty)
    }

    @Test("Calibre: leerer Serienindex normalisiert einen alten Wert zu #1", .enabled(
        if: Self.calibreFixtureAvailable && Self.calibreConversionAvailable,
        "Calibre, ebook-convert oder die EPUB-Fixture fehlt"
    ))
    func calibreEmptySeriesIndexUsesDefaultOne() throws {
        let url = try makeFB2WorkingCopy()
        let original = try EbookTool.readCoreFields(url: url)
        var indexed = original
        indexed.series = "Testreihe"
        indexed.seriesIndex = "7"
        try EbookTool.writeCoreFields(url: url, fields: indexed, original: original)
        #expect(try directCalibreOutput(url: url).contains("Series              : Testreihe #7"))

        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.seriesIndex = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)

        // Calibre bietet für eine vorhandene Serie keinen Null-Index. #1 ist
        // daher der dokumentierte Ersatz und beweist zugleich, dass #7 weg ist.
        let output = try directCalibreOutput(url: url)
        #expect(!output.contains("#7"))
        #expect(output.contains("Series              : Testreihe #1"))
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series == "Testreihe")
        #expect(readBack.seriesIndex == "1")
    }

    // MARK: - EPUB: fremde Metadaten überleben eigene Änderungen

    @Test("EPUB 2: Eine Autorenänderung erhält Creator mit anderer Rolle")
    func epub2AuthorChangeKeepsOtherRoles() throws {
        // Editoren/Übersetzer sind eigene Metadaten. Eine reine
        // Autorenänderung darf sie nicht mitlöschen.
        let url = try Fixtures.workingCopy("book2.epub")
        try rewriteOpf(in: url, path: "OEBPS/content.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator opf:role=\"aut\">Erika Beispiel</dc:creator>",
                with: "<dc:creator opf:role=\"aut\">Erika Beispiel</dc:creator>"
                    + "<dc:creator opf:role=\"edt\">Eddie Editor</dc:creator>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.authors == ["Erika Beispiel"]) // edt ist kein Autor

        var changed = original
        changed.authors = ["Neue Autorin"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).authors == ["Neue Autorin"])
        let xml = try opfContents(of: url, path: "OEBPS/content.opf")
        #expect(xml.contains("Eddie Editor"))
        #expect(!xml.contains("Erika Beispiel"))
    }

    @Test("EPUB 3: Eine per refines markierte Rolle bleibt samt Verfeinerung erhalten")
    func epub3AuthorChangeKeepsRefinedRoles() throws {
        // EPUB 3 markiert Rollen über <meta refines="#id" property="role">.
        // Solche Creator sind keine Autoren und bleiben mitsamt ihrer
        // Verfeinerung stehen.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator>Erika Beispiel</dc:creator>",
                with: "<dc:creator>Erika Beispiel</dc:creator>"
                    + "<dc:creator id=\"ed1\">Eddie Editor</dc:creator>"
                    + "<meta refines=\"#ed1\" property=\"role\" scheme=\"marc:relators\">edt</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.authors == ["Max Muster", "Erika Beispiel"])

        var changed = original
        changed.authors = ["Nur Noch Eine"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).authors == ["Nur Noch Eine"])
        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Eddie Editor"))
        #expect(xml.contains("refines=\"#ed1\""))
    }

    @Test("EPUB 3: Eine Titeländerung erhält weitere Titel samt Verfeinerungen")
    func epub3TitleChangeKeepsAlternateTitles() throws {
        // Das öffentliche Titelfeld bildet nur den ersten dc:title ab. Ein
        // Untertitel ist fremder, nicht dargestellter Zustand und darf bei
        // einer Änderung des Haupttitels nicht verschwinden.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:title>Testbuch Drei</dc:title>",
                with: "<dc:title id=\"main-title\">Testbuch Drei</dc:title>"
                    + "<meta refines=\"#main-title\" property=\"title-type\">main</meta>"
                    + "<dc:title id=\"subtitle\">Bleibender Untertitel</dc:title>"
                    + "<meta refines=\"#subtitle\" property=\"title-type\">subtitle</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Neuer Haupttitel"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Neuer Haupttitel"))
        #expect(xml.contains("Bleibender Untertitel"))
        #expect(xml.contains("refines=\"#subtitle\""))
        #expect(try EbookTool.readCoreFields(url: url).title == "Neuer Haupttitel")

        // Beim ausdrücklichen Löschen verschwinden dagegen alle Titel. Dann
        // müssen auch deren Verfeinerungen mit entfernt werden.
        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.title = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)
        let clearedXML = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(!clearedXML.contains("main-title"))
        #expect(!clearedXML.contains("subtitle"))
        #expect(try EbookTool.readCoreFields(url: url).title.isEmpty)
    }

    @Test("EPUB 3: Ersetzte Schlagwörter hinterlassen keine Verfeinerungen")
    func epub3SubjectChangeRemovesRefinements() throws {
        // dc:subject kann per refines um Normvokabular und Code ergänzt sein.
        // Wird das Schlagwort ersetzt, darf diese Verfeinerung nicht auf eine
        // inzwischen entfernte XML-ID zeigen.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:identifier id=\"uid\">urn:isbn:9780306406157</dc:identifier>",
                with: "<dc:subject id=\"subject-old\">Alte Klassifikation</dc:subject>"
                    + "<meta refines=\"#subject-old\" property=\"authority\">BISAC</meta>"
                    + "<dc:identifier id=\"uid\">urn:isbn:9780306406157</dc:identifier>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.subjects = ["Neues Schlagwort"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(!xml.contains("subject-old"))
        #expect(!xml.contains("BISAC"))
        #expect(try EbookTool.readCoreFields(url: url).subjects == ["Neues Schlagwort"])
    }

    @Test("EPUB 3: Serienänderung und -löschung erhalten fremde Sammlungen")
    func epub3SeriesChangeKeepsUnrelatedCollections() throws {
        // Ein Buch kann neben der Serie weiteren Sammlungen angehören
        // (collection-type != "series"). Die dürfen weder beim Ändern noch
        // beim Löschen der Serie verschwinden.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<meta property=\"belongs-to-collection\" id=\"c01\">Dreierreihe</meta>",
                with: "<meta property=\"belongs-to-collection\" id=\"c01\">Dreierreihe</meta>"
                    + "<meta property=\"belongs-to-collection\" id=\"set1\">Gesamtausgabe</meta>"
                    + "<meta refines=\"#set1\" property=\"collection-type\">set</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        // Die typlose Sammlung c01 bleibt die Serie; "set" zählt nicht.
        #expect(original.series == "Dreierreihe")

        var changed = original
        changed.series = "Neue Reihe"
        changed.seriesIndex = "9"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
        var readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series == "Neue Reihe")
        #expect(readBack.seriesIndex == "9")
        var xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Gesamtausgabe"))
        #expect(xml.contains("collection-type"))
        #expect(!xml.contains("Dreierreihe"))

        // Serie ganz löschen — die fremde Sammlung bleibt trotzdem.
        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.series = ""
        cleared.seriesIndex = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)
        readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series.isEmpty)
        xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Gesamtausgabe"))
    }

    @Test("EPUB 3: Die neue Serien-id weicht auch einer id außerhalb der meta-Elemente aus")
    func epub3SeriesIdAvoidsIdsOutsideMetaElements() throws {
        // Die Kollisionsprüfung sah früher nur die <meta>-Kinder von
        // <metadata>. Trägt ein anderes Element — hier ein dc:creator — die id
        // "series-tagx" bereits, entstünde eine doppelte XML-ID und die neu
        // geschriebenen refines-Verweise wären mehrdeutig.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator>Erika Beispiel</dc:creator>",
                with: "<dc:creator id=\"series-tagx\">Erika Beispiel</dc:creator>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.series = "Neue Reihe"
        changed.seriesIndex = "2"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        // Die fremde id bleibt genau einmal vergeben …
        #expect(xml.components(separatedBy: "id=\"series-tagx\"").count - 1 == 1)
        // … und die eigene Sammlung weicht samt ihrer Verweise darauf aus.
        #expect(xml.contains("id=\"series-tagx-2\""))
        #expect(xml.contains("refines=\"#series-tagx-2\""))
        #expect(try EbookTool.readCoreFields(url: url).series == "Neue Reihe")
    }

    @Test("EPUB: Platzmangel bleibt als solcher erkennbar",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func epubOutOfSpaceKeepsTypedError() throws {
        // `notEnoughSpace` trägt die konkrete Ursache (und den Originalpfad).
        // Die EPUB-Fehlervereinheitlichung darf ihn nicht zu einem
        // nichtssagenden `saveFailed` verwischen.
        let volume = try TestVolume(megabytes: 12)
        defer { volume.detach() }
        let url = volume.mountPoint.appendingPathComponent("book2.epub")
        try FileManager.default.copyItem(
            at: Fixtures.directory.appendingPathComponent("book2.epub"), to: url)
        try volume.fillRemainingSpace()

        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Passt nicht mehr"
        do {
            try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
            Issue.record("Das Schreiben hätte am Platz scheitern müssen")
        } catch TagError.notEnoughSpace {
            // erwartet: der konkrete Grund bleibt sichtbar
        }
        #expect(try EbookTool.readCoreFields(url: url).title == original.title)
    }

    // MARK: - Struktur-Invarianten der OPF

    @Test("EPUB: Geänderte ISBN bleibt der Paket-Identifier",
          arguments: [("book2.epub", "OEBPS/content.opf"), ("book3.epub", "OEBPS/package.opf")])
    func epubIsbnChangeKeepsPackageIdentifier(fixture: String, opfPath: String) throws {
        // Beide Fixtures verwenden den ISBN-Knoten als <package
        // unique-identifier="uid">. Wird er beim Schreiben ersetzt, muss der
        // Verweis mitwandern — sonst entsteht ein strukturell ungültiges EPUB,
        // das der reine Feld-Roundtrip nicht bemerkt.
        let url = try Fixtures.workingCopy(fixture)
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.isbn = "9780306406157X"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).isbn == "9780306406157X")
        #expect(try packageIdentifierValue(of: url, opfPath: opfPath)
                == "urn:isbn:9780306406157X")
    }

    @Test("EPUB: Gelöschte ISBN hinterlässt keinen verwaisten Paket-Identifier",
          arguments: [("book2.epub", "OEBPS/content.opf"), ("book3.epub", "OEBPS/package.opf")])
    func epubIsbnDeletionKeepsPackageIdentifier(fixture: String, opfPath: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        let original = try EbookTool.readCoreFields(url: url)
        var cleared = original
        cleared.isbn = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: original)

        #expect(try EbookTool.readCoreFields(url: url).isbn == "")
        // Der Verweis muss weiterhin auflösen — jetzt auf einen neutralen
        // UUID-Identifier, nicht mehr auf eine ISBN.
        let value = try packageIdentifierValue(of: url, opfPath: opfPath)
        #expect(value.hasPrefix("urn:uuid:"))
    }

    // MARK: - Abgelehnte Zustände

    @Test("Serienindex ohne Serie: EPUB speichert ihn, andere Formate lehnen ab")
    func seriesIndexWithoutSeriesIsBackendSpecific() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        var indexOnly = original
        indexOnly.series = ""
        indexOnly.seriesIndex = "5"

        // EPUB kennt mit calibre:series_index einen Speicherort auch ohne
        // Serie — der in fremden EPUBs verbreitete Zustand muss schreib- und
        // damit aus einem Archiv wiederherstellbar sein.
        try EbookTool.write(url: url, fields: indexOnly, original: original,
                            coverUpdate: .unchanged)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series.isEmpty)
        #expect(readBack.seriesIndex == "5")

        // Formate ohne diesen Speicherort lehnen weiterhin vor jedem
        // Schreibzugriff ab (die Prüfung läuft vor jedem Backend-Kontakt,
        // deshalb genügt hier ein Pfad ohne echte Datei).
        let azw3 = URL(fileURLWithPath: "/nicht-vorhanden/buch.azw3")
        #expect(throws: TagError.seriesIndexWithoutSeries) {
            try EbookTool.write(url: azw3, fields: indexOnly, original: original,
                                coverUpdate: .unchanged)
        }
        // Eine bereits vorhandene, nicht angefasste Kombination darf das
        // Bearbeiten anderer Felder auch dort nicht blockieren.
        var titleOnly = indexOnly
        titleOnly.title = "Anderer Titel"
        #expect(throws: Never.self) {
            try EbookTool.requireStorableSeries(titleOnly, original: indexOnly, url: azw3)
        }
    }

    @Test("Cover ohne gültige Bildsignatur wird abgelehnt")
    func ebookRejectsUnsupportedCoverData() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let before = try Data(contentsOf: url)
        let original = try EbookTool.readCoreFields(url: url)

        for junk in [Data("Das hier ist ein Text, kein Bild.".utf8), Data()] {
            #expect(throws: TagError.unsupportedCoverData) {
                try EbookTool.write(url: url, fields: original, original: original,
                                    coverUpdate: .set(junk))
            }
        }
        #expect(try Data(contentsOf: url) == before)
        // Das echte Cover ist unverändert geblieben.
        #expect(try EbookTool.readCover(url: url)?.data == Fixtures.coverData("cover.jpg"))

        // Ein gültiges PNG geht weiterhin durch.
        let png = try Fixtures.coverData("cover.png")
        try EbookTool.write(url: url, fields: original, original: original,
                            coverUpdate: .set(png))
        #expect(try EbookTool.readCover(url: url)?.data == png)

        // GIF ist ein Kern-Bildformat von EPUB und muss dort setzbar sein
        // (sonst wäre ein exportiertes GIF-Cover nicht wiederherstellbar) —
        // die ebook-meta-Formate bleiben bei JPEG/PNG.
        var gifBytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        gifBytes.append(contentsOf: Array(repeating: 0, count: 8))
        let gif = Data(gifBytes)
        try EbookTool.write(url: url, fields: original, original: original,
                            coverUpdate: .set(gif))
        #expect(try EbookTool.readCover(url: url)?.data == gif)
        #expect(throws: TagError.unsupportedCoverData) {
            try EbookTool.requireSupportedCover(
                gif, for: URL(fileURLWithPath: "/nicht-vorhanden/buch.azw3"))
        }
    }

    /// Prüft die EPUB-Grundregel und liefert den Wert des Paket-Identifiers:
    /// `<package unique-identifier="…">` muss auf einen vorhandenen
    /// `dc:identifier` mit genau dieser id zeigen.
    private func packageIdentifierValue(of url: URL, opfPath: String) throws -> String {
        let document = try XMLDocument(xmlString: try opfContents(of: url, path: opfPath))
        let package = try #require(document.rootElement())
        let uid = try #require(package.attribute(forName: "unique-identifier")?.stringValue)
        let metadata = try #require(package.elements(forName: "metadata").first)
        let identifiers = (metadata.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { ($0.name ?? "").split(separator: ":").last.map(String.init) == "identifier" }
        let match = try #require(
            identifiers.first { $0.attribute(forName: "id")?.stringValue == uid })
        return match.stringValue ?? ""
    }

    /// Schreibt die OPF-Datei eines Test-EPUBs als rohen XML-Text um — zum
    /// Einschleusen von Metadaten, die die Fixtures nicht enthalten.
    private func rewriteOpf(in url: URL, path: String,
                            _ transform: (String) -> String) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = transform(String(decoding: data, as: UTF8.self))
        try archive.remove(entry)
        let newData = Data(xml.utf8)
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(newData.count),
                             compressionMethod: .deflate) { position, size in
            newData.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    /// Liest die OPF-Datei als Text (für Erhaltungs-Prüfungen am rohen XML).
    private func opfContents(of url: URL, path: String) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Führt ebook-meta direkt aus. Der Test kontrolliert damit den externen
    /// Dateizustand und nicht nur die eigene Parser-Interpretation.
    private func directCalibreOutput(url: URL) throws -> String {
        let executable = try EbookTool.locateCalibre()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["LC_ALL=C", executable, url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let error = stderr.fileHandleForReading.readDataToEndOfFile()
            throw NSError(domain: "EbookToolTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// FB2 bewahrt Serienmetadaten in Calibre 7.7, azw3 dagegen nicht. Die
    /// Kopie entsteht nur im Temp-Ordner und ist kein Test-Asset im Repository.
    private func makeFB2WorkingCopy() throws -> URL {
        let meta = try EbookTool.locateCalibre()
        let converter = URL(fileURLWithPath: meta)
            .deletingLastPathComponent()
            .appendingPathComponent("ebook-convert")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-calibre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = dir.appendingPathComponent("book.fb2")
        let process = Process()
        process.executableURL = converter
        process.arguments = [Fixtures.directory.appendingPathComponent("book2.epub").path, result.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "EbookToolTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ebook-convert fehlgeschlagen"])
        }
        return result
    }

    @Test("WebP-Cover: EPUB 3 ja, EPUB 2 nein")
    func webpCoverFollowsPackageVersion() throws {
        // WebP ist erst ab EPUB 3 ein Kern-Bildformat. In einem EPUB-2-Paket
        // braeuchte es ein Fallback-Item; ohne das ignorieren Reader das Cover
        // und Pruefer lehnen das Paket ab. Vorher wurde WebP fuer JEDES EPUB
        // zugelassen und der Schreibweg meldete trotzdem Erfolg
        // (Review-Fund 2026-08-17).
        //
        // Minimales gueltiges WebP: "RIFF" + Groesse + "WEBPVP8 ".
        var webpBytes: [UInt8] = Array("RIFF".utf8)
        webpBytes.append(contentsOf: [0x1A, 0x00, 0x00, 0x00])
        webpBytes.append(contentsOf: Array("WEBPVP8 ".utf8))
        webpBytes.append(contentsOf: Array(repeating: 0, count: 14))
        let webp = Data(webpBytes)

        let epub2 = try Fixtures.workingCopy("book2.epub")
        #expect(EpubFile.packageVersion(url: epub2)?.hasPrefix("2") == true)
        #expect(!EbookTool.supportedCoverMimeTypes(url: epub2).contains("image/webp"))
        let vorher = try Data(contentsOf: epub2)
        let felder2 = try EbookTool.readCoreFields(url: epub2)
        #expect(throws: TagError.unsupportedCoverData) {
            try EbookTool.write(url: epub2, fields: felder2, original: felder2,
                                coverUpdate: .set(webp))
        }
        #expect(try Data(contentsOf: epub2) == vorher, "Die Datei bleibt unangetastet.")

        let epub3 = try Fixtures.workingCopy("book3.epub")
        #expect(EpubFile.packageVersion(url: epub3)?.hasPrefix("3") == true)
        #expect(EbookTool.supportedCoverMimeTypes(url: epub3).contains("image/webp"))
        let felder3 = try EbookTool.readCoreFields(url: epub3)
        try EbookTool.write(url: epub3, fields: felder3, original: felder3,
                            coverUpdate: .set(webp))
        #expect(try EbookTool.readCover(url: epub3)?.data == webp)
    }
}

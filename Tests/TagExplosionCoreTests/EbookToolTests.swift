// E-Book-Metadaten: Lesen/Roundtrip für EPUB 2, EPUB 3, PDF (exiftool) und —
// falls Calibre installiert ist — azw3 via ebook-meta.
import Foundation
import Testing
@testable import TagExplosionCore

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
}

import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("EbookTool", .serialized)
struct EbookToolTests {
    /// Voll ausgefüllte Felder für den Schreib-Roundtrip.
    var editedFields: EbookCoreFields {
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

    @Test("PDF: Roundtrip der unterstützten Felder", .enabled(
        if: FileManager.default.fileExists(atPath: Fixtures.directory.appendingPathComponent("book.pdf").path),
        "PDF-Fixture fehlt"))
    func pdfRoundtrip() throws {
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

    /// PDF hat für eine Serie keinen Speicherort; `writePdf` bildet die Felder
    /// gar nicht ab. Ohne Ablehnung im gemeinsamen Kern sicherte der Schreibweg
    /// die Datei in den Papierkorb, ersetzte sie durch eine inhaltsgleiche
    /// Kopie und meldete Erfolg — der Wert war still weg. Die App erreicht die
    /// Felder über „Tags aus Dateiname" und Batch-Regeln auch dann, wenn der
    /// Editor sie ausblendet (Review-Fund 2026-09-10).
    @Test("PDF lehnt eine Serie im Schreibweg ab, statt sie still zu verwerfen",
          .enabled(if: FileManager.default.fileExists(
              atPath: Fixtures.directory.appendingPathComponent("book.pdf").path),
              "PDF-Fixture fehlt (braucht sips)"))
    func pdfRejectsSeriesInsteadOfDroppingIt() throws {
        let url = try Fixtures.workingCopy("book.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let original = try EbookTool.readCoreFields(url: url)
        var withSeries = original
        withSeries.series = "Die Reihe"
        withSeries.seriesIndex = "2"

        #expect(throws: TagError.seriesUnsupported(path: url.path)) {
            try EbookTool.write(url: url, fields: withSeries, original: original,
                                coverUpdate: .unchanged)
        }
        // Weder Sicherung noch Austausch: Die Datei ist unangetastet.
        #expect(try Data(contentsOf: url) == before)

        // Andere Felder bleiben bei PDF selbstverständlich schreibbar.
        var titleOnly = original
        titleOnly.title = "Anderer Titel"
        #expect(throws: Never.self) {
            try EbookTool.requireStorableSeries(titleOnly, original: original, url: url)
        }
    }

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
        #expect(throws: TagError.seriesUnsupported(path: azw3.path)) {
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
}

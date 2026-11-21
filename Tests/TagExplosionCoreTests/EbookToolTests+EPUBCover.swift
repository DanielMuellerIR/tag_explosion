import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore
import ZIPFoundation

extension EbookToolTests {
    @Test("EPUB: Tags und Cover werden gemeinsam geschrieben, Nutzdaten und EPUB-mimetype bleiben erhalten",
          arguments: ["book2.epub", "book3.epub"])
    func combinedEpubWrite(_ fixture: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        let original = try EbookTool.readSnapshot(url: url, includeCover: true)
        let entries = try ZipContainer.entries(url: url)
        let before = try Archive(url: url, accessMode: .read)
        var payloads: [String: Data] = [:]
        for entry in before where !entry.path.hasSuffix(".opf") && !entry.path.hasSuffix(".jpg") {
            payloads[entry.path] = try ZipContainer.data(of: entry, in: before)
        }
        let cover = try Fixtures.coverData("cover.png")
        try EbookTool.write(url: url, fields: editedFields, original: original.value.fields,
                            coverUpdate: .set(cover), expecting: original.stamp)
        let result = try EbookTool.readSnapshot(url: url, includeCover: true)
        #expect(result.value.fields == editedFields)
        #expect(result.value.cover?.data == cover)
        let rewrittenEntries = try ZipContainer.entries(url: url)
        #expect(rewrittenEntries.first == entries.first)
        #expect(Set(rewrittenEntries.map(\.path)) == Set(entries.map(\.path)))
        for entry in entries where !entry.path.hasSuffix(".opf") && !entry.path.hasSuffix(".jpg") {
            #expect(rewrittenEntries.first(where: { $0.path == entry.path }) == entry)
        }
        let after = try Archive(url: url, accessMode: .read)
        for (path, data) in payloads {
            #expect(try ZipContainer.data(at: path, in: after) == data)
        }
        try EbookTool.write(url: url, fields: original.value.fields, original: result.value.fields,
                            coverUpdate: .remove, expecting: result.stamp)
        let removed = try EbookTool.readSnapshot(url: url, includeCover: true)
        #expect(removed.value.fields == original.value.fields)
        #expect(removed.value.cover == nil)
    }

    @Test("EPUB: Covertausch ohne Formatwechsel schreibt die OPF nicht neu")
    func coverOnlyPreservesOPF() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let before = try opfContents(of: url, path: "OEBPS/package.opf")
        let original = try EbookTool.readCoreFields(url: url)
        let cover = try Fixtures.coverData("cover-alpha.png")
        try EbookTool.write(url: url, fields: original, original: original, coverUpdate: .set(cover))
        #expect(try opfContents(of: url, path: "OEBPS/package.opf") == before)
        #expect(try EbookTool.readCover(url: url)?.data == cover)
    }

    @Test("EPUB 2: Cover lesen und ersetzen")
    func epub2Cover() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let cover = try #require(try EbookTool.readCover(url: url))
        #expect(cover.resolvedMimeType == "image/jpeg")
        let expectedCover = try Fixtures.coverData("cover.jpg")
        #expect(cover.data == expectedCover)

        let replacement = try Fixtures.coverData("cover.png")
        try EbookTool.writeCover(url: url, data: replacement)
        let readBack = try #require(try EbookTool.readCover(url: url))
        #expect(readBack.data == replacement)
        #expect(readBack.resolvedMimeType == "image/png")
        // Metadaten haben den Cover-Tausch überlebt
        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
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

    @Test("EPUB-Cover: Fremdattribut properties bleibt in beiden Reihenfolgen", arguments: [false, true])
    func coverRemovalPreservesNamespacedProperties(foreignFirst: Bool) throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let path = "OEBPS/package.opf"
        try rewriteOpf(in: url, path: path) { xml in
            let foreign = "xmlns:v=\"urn:vendor\" v:properties=\"private\""
            return xml.replacingOccurrences(of: "properties=\"cover-image\"", with:
                foreignFirst ? foreign + " properties=\"cover-image\"" : "properties=\"cover-image\" " + foreign)
        }
        #expect(try EbookTool.readCover(url: url) != nil)
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.write(url: url, fields: original, original: original, coverUpdate: .remove)
        #expect(try EbookTool.readCover(url: url) == nil)
        let document = try XMLDocument(xmlString: try opfContents(of: url, path: path))
        let item = try #require(try document.nodes(forXPath: "//*[@id='cover-image']").first as? XMLElement)
        #expect(item.attribute(forName: "v:properties")?.stringValue == "private")
        #expect(XMLTools.attribute(item, "properties") == nil)
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

    @Test("WebP-Cover: EPUB 3 ja, EPUB 2 nein")
    func webpCoverFollowsPackageVersion() throws {
        // WebP gehört seit EPUB 3.3 zu den Kern-Bildformaten. Das OPF nennt
        // weiterhin Version 3.0; in einem EPUB-2-Paket bräuchte WebP dagegen
        // ein Fallback-Item. Ohne das ignorieren Reader das Cover und Prüfer
        // lehnen das Paket ab. Vorher wurde WebP für JEDES EPUB zugelassen und
        // der Schreibweg meldete trotzdem Erfolg
        // (Review-Fund 2026-08-17).
        //
        // Minimales gültiges WebP: "RIFF" + Größe + "WEBPVP8 ".
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

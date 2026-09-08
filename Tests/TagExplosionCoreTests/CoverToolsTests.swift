// Cover-Werkzeuge (AP12): Analyse und Prüfregeln an den erzeugten
// Test-Covern, synthetische JPEG-Header (progressiv, CMYK), Umwandlungs-
// Roundtrip (Maße nach Verkleinern, Format nach Wandeln), verlustfreies
// Entfernen von Metadaten und die Prioritätsliste der Ordner-Cover.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("CoverTools")
struct CoverToolsTests {

    @Test("Bildanalyse akzeptiert Data-Ausschnitte mit fremdem Startindex", arguments: ["cover.jpg", "cover.png"])
    func analyzeDataSlice(_ name: String) throws {
        let original = try Fixtures.coverData(name)
        let prefixed = Data(repeating: 0, count: 64) + original
        let slice = prefixed.dropFirst(64)
        #expect(slice.startIndex == 64)
        #expect(CoverTools.analyze(slice) == CoverTools.analyze(original))
        #expect(try CoverTools.stripMetadata(slice) == CoverTools.stripMetadata(original))
    }

    // MARK: - Analyse

    @Test("64×64-JPEG: Maße, Format, Farbmodell und Hinweis „zu klein“")
    func analyzeSmallJPEG() throws {
        let analysis = CoverTools.analyze(try Fixtures.coverData("cover.jpg"))
        #expect(analysis.format == "JPEG")
        #expect(analysis.mimeType == "image/jpeg")
        #expect(analysis.pixelWidth == 64)
        #expect(analysis.pixelHeight == 64)
        #expect(analysis.aspectRatio == 1)
        #expect(analysis.colorModel == "RGB")
        #expect(analysis.hasAlpha == false)
        #expect(analysis.isProgressiveJPEG == false)
        #expect(analysis.issues.map(\.code) == [.tooSmall])
    }

    @Test("1200×800-JPEG: nur „nicht quadratisch“")
    func analyzeLargeJPEG() throws {
        let analysis = CoverTools.analyze(try Fixtures.coverData("cover-large.jpg"))
        #expect(analysis.pixelWidth == 1200)
        #expect(analysis.pixelHeight == 800)
        #expect(analysis.issues.map(\.code) == [.notSquare])
        #expect(analysis.summary.contains("1200×800 px"))
    }

    @Test("PNG mit Alphakanal wird erkannt")
    func analyzePNGAlpha() throws {
        let plain = CoverTools.analyze(try Fixtures.coverData("cover.png"))
        #expect(plain.format == "PNG")
        #expect(plain.pixelWidth == 64)
        #expect(plain.hasAlpha == false)
        #expect(plain.isProgressiveJPEG == nil)

        let alpha = CoverTools.analyze(try Fixtures.coverData("cover-alpha.png"))
        #expect(alpha.hasAlpha == true)
        #expect(alpha.colorModel == "RGB")
    }

    @Test("Synthetischer Header: progressives CMYK-JPEG mit 4000 px liefert alle Regeln")
    func analyzeSyntheticProgressiveCMYK() {
        let analysis = CoverTools.analyze(syntheticJPEG(width: 4000, height: 4000, components: 4, progressive: true))
        #expect(analysis.pixelWidth == 4000)
        #expect(analysis.colorModel == "CMYK")
        #expect(analysis.isProgressiveJPEG == true)
        #expect(analysis.issues.map(\.code) == [.tooLarge, .progressiveJPEG, .cmyk])
    }

    @Test("Unbekannte Daten: Maße nil und Hinweis „unknown-format“")
    func analyzeGarbage() {
        let analysis = CoverTools.analyze(Data("kein Bild, nur Text mit genug Bytes".utf8))
        #expect(analysis.pixelWidth == nil)
        #expect(analysis.format == "unknown")
        #expect(analysis.issues.map(\.code) == [.unknownFormat])
    }

    @Test("Bytegrenze: 2 MiB + 1 Byte gilt als zu groß")
    func tooManyBytes() {
        var analysis = CoverAnalysis(mimeType: "image/jpeg", format: "JPEG", bytes: CoverTools.maximumBytes + 1,
                                     pixelWidth: 1000, pixelHeight: 1000, colorModel: "RGB",
                                     hasAlpha: false, isProgressiveJPEG: false)
        analysis.issues = CoverTools.issues(for: analysis)
        #expect(analysis.issues.map(\.code) == [.tooManyBytes])
        // 5 % Toleranz: 1000×1040 ist noch quadratisch, 1000×1060 nicht.
        let within = CoverAnalysis(mimeType: "image/jpeg", format: "JPEG", bytes: 10,
                                   pixelWidth: 1000, pixelHeight: 1040, colorModel: "RGB",
                                   hasAlpha: false, isProgressiveJPEG: false)
        #expect(CoverTools.issues(for: within).isEmpty)
        let outside = CoverAnalysis(mimeType: "image/jpeg", format: "JPEG", bytes: 10,
                                    pixelWidth: 1000, pixelHeight: 1060, colorModel: "RGB",
                                    hasAlpha: false, isProgressiveJPEG: false)
        #expect(CoverTools.issues(for: outside).map(\.code) == [.notSquare])
    }

    // MARK: - Umwandlung

    @Test("Verkleinern auf 500 px hält das Seitenverhältnis",
          .enabled(if: CoverTools.isConversionAvailable, "Umwandlung braucht ImageIO"))
    func shrinkKeepsAspectRatio() throws {
        let source = try Fixtures.coverData("cover-large.jpg")
        let result = try CoverTools.convert(source, .init(maxPixelSize: 500))
        let analysis = CoverTools.analyze(result)
        #expect(analysis.format == "JPEG")
        #expect(analysis.pixelWidth == 500)
        #expect(analysis.pixelHeight == 333)
        #expect(result.count < source.count)
    }

    @Test("Kleinere Bilder werden nicht vergrößert und nicht neu kodiert")
    func shrinkIsNoopForSmallImages() throws {
        let source = try Fixtures.coverData("cover.jpg")
        #expect(try CoverTools.convert(source, .init(maxPixelSize: 1000)) == source)
        #expect(try CoverTools.convert(source, .init()) == source)
    }

    @Test("PNG → JPEG wandelt Format und MIME-Type, Alpha wird auf Weiß abgeflacht",
          .enabled(if: CoverTools.isConversionAvailable, "Umwandlung braucht ImageIO"))
    func convertPNGToJPEG() throws {
        let artwork = Artwork(data: try Fixtures.coverData("cover-alpha.png"),
                              pictureType: "Front Cover", description: "Test")
        let converted = try CoverTools.convert(artwork, .init(format: .jpeg))
        #expect(converted.mimeType == "image/jpeg")
        #expect(converted.pictureType == "Front Cover")
        #expect(converted.description == "Test")
        let analysis = CoverTools.analyze(converted.data)
        #expect(analysis.format == "JPEG")
        #expect(analysis.pixelWidth == 64)
        #expect(analysis.hasAlpha == false)
    }

    @Test("JPEG → PNG und Qualitätsstufen",
          .enabled(if: CoverTools.isConversionAvailable, "Umwandlung braucht ImageIO"))
    func convertJPEGToPNGAndQuality() throws {
        let source = try Fixtures.coverData("cover-large.jpg")
        let png = try CoverTools.convert(source, .init(format: .png))
        #expect(CoverTools.analyze(png).format == "PNG")
        #expect(CoverTools.analyze(png).pixelWidth == 1200)
        // Niedrige Qualität ergibt weniger Bytes als hohe.
        let low = try CoverTools.convert(source, .init(format: .jpeg, jpegQuality: 0.3))
        let high = try CoverTools.convert(source, .init(format: .jpeg, jpegQuality: 1.0))
        #expect(low.count < high.count)
    }

    @Test("Metadaten aus JPEG verlustfrei entfernen: APP1 und COM weg, Bilddaten identisch")
    func stripJPEGMetadata() throws {
        let original = try Fixtures.coverData("cover.jpg")
        // Ein EXIF-Segment (APP1) und einen Kommentar hinter SOI einschieben.
        let exif = Data("Exif\0\0MM\0*\0\0\0\u{08}".utf8)
        let comment = Data("Kommentar".utf8)
        var padded = Data([0xFF, 0xD8])
        padded.append(segment(marker: 0xE1, payload: exif))
        padded.append(segment(marker: 0xFE, payload: comment))
        padded.append(original.dropFirst(2))
        #expect(CoverTools.analyze(padded).pixelWidth == 64)

        let stripped = try CoverTools.stripMetadata(padded)
        let strippedOriginal = try CoverTools.stripMetadata(original)
        #expect(stripped == strippedOriginal)
        #expect(!containsSegment(stripped, marker: 0xE1))
        #expect(!containsSegment(stripped, marker: 0xFE))
        #expect(CoverTools.analyze(stripped).pixelWidth == 64)
        // Der Weg über `convert` mit nur stripMetadata ist derselbe.
        #expect(try CoverTools.convert(padded, .init(stripMetadata: true)) == stripped)
    }

    @Test("Metadaten aus PNG entfernen: tEXt-Chunk weg, Rest byteidentisch")
    func stripPNGMetadata() throws {
        let original = try Fixtures.coverData("cover.png")
        // tEXt-Chunk direkt hinter IHDR (Signatur 8 + IHDR-Chunk 25 Bytes).
        let text = Data("Comment\0Hallo".utf8)
        var chunk = Data()
        chunk.append(contentsOf: bigEndian(UInt32(text.count)))
        chunk.append(contentsOf: Array("tEXt".utf8))
        chunk.append(text)
        chunk.append(contentsOf: [0, 0, 0, 0]) // CRC wird beim Entfernen nicht geprüft
        var padded = original.prefix(33)
        padded.append(chunk)
        padded.append(original.dropFirst(33))

        let stripped = try CoverTools.stripMetadata(padded)
        #expect(stripped == original)
        #expect(CoverTools.analyze(stripped).pixelWidth == 64)
    }

    @Test("Unbekannte Daten lassen sich nicht wandeln")
    func convertRejectsGarbage() {
        #expect(throws: CoverToolError.unsupportedImage) {
            try CoverTools.convert(Data("kein Bild, nur Text mit genug Bytes".utf8), .init(format: .jpeg))
        }
    }

    // MARK: - Ordner-Cover

    @Test("Prioritätsliste: folder vor cover vor front, JPEG vor PNG, Schreibweise egal")
    func folderCoverPriority() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(FolderCover.find(in: directory) == nil)

        let png = try Fixtures.coverData("cover.png")
        let jpg = try Fixtures.coverData("cover.jpg")
        try png.write(to: directory.appendingPathComponent("front.png"))
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "front.png")
        try jpg.write(to: directory.appendingPathComponent("Cover.JPG"))
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "Cover.JPG")
        try png.write(to: directory.appendingPathComponent("cover.png"))
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "Cover.JPG")
        try png.write(to: directory.appendingPathComponent("Folder.png"))
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "Folder.png")
        try jpg.write(to: directory.appendingPathComponent("folder.jpeg"))
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "folder.jpeg")

        // Ein gleichnamiger Ordner ist kein Cover und darf die Datei nicht verdecken.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.jpg"), withIntermediateDirectories: false)
        #expect(FolderCover.find(in: directory)?.lastPathComponent == "folder.jpeg")
        let loaded = try FolderCover.load(in: directory)
        #expect(loaded?.data == jpg)
        #expect(loaded?.mimeType == "image/jpeg")
        #expect(loaded?.pictureType == "Front Cover")
    }

    @Test("Ordner-Cover, das kein Bild ist, wird abgelehnt statt eingebettet")
    func folderCoverRejectsNonImage() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("nur Text, aber mit genügend Bytes".utf8).write(to: directory.appendingPathComponent("folder.jpg"))
        #expect(throws: CoverToolError.unsupportedImage) { try FolderCover.load(in: directory) }
    }

    @Test("Export: Endung nach Magic Bytes, kein stilles Überschreiben, --force ersetzt")
    func folderCoverExport() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Artwork(data: try Fixtures.coverData("cover.png"), mimeType: "image/jpeg")
        let jpg = Artwork(data: try Fixtures.coverData("cover.jpg"), mimeType: "image/jpeg")
        #expect(FolderCover.exportFileName(for: png) == "folder.png")
        #expect(FolderCover.exportFileName(for: jpg) == "folder.jpg")
        #expect(FolderCover.exportFileName(for: Artwork(data: Data(repeating: 0, count: 20))) == nil)

        let target = try FolderCover.export(png, to: directory)
        #expect(target.lastPathComponent == "folder.png")
        #expect(try Data(contentsOf: target) == png.data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["folder.png"])

        let other = Artwork(data: try Fixtures.coverData("cover-alpha.png"))
        #expect(throws: CoverToolError.targetExists(path: target.path)) {
            try FolderCover.export(other, to: directory)
        }
        #expect(try Data(contentsOf: target) == png.data)

        try FolderCover.export(other, to: directory, force: true)
        #expect(try Data(contentsOf: target) == other.data)
    }

    // MARK: - Helfer

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-covertools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// JPEG-Segment: Marker, Länge (inklusive der 2 Längenbytes), Nutzdaten.
    private func segment(marker: UInt8, payload: Data) -> Data {
        var data = Data([0xFF, marker])
        let length = payload.count + 2
        data.append(contentsOf: [UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        data.append(payload)
        return data
    }

    /// Nur Header, keine Bilddaten — reicht für Analyse und Prüfregeln.
    private func syntheticJPEG(width: Int, height: Int, components: Int, progressive: Bool) -> Data {
        var sof = Data([8]) // Präzision
        sof.append(contentsOf: [UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF)])
        sof.append(contentsOf: [UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF)])
        sof.append(UInt8(components))
        for i in 0..<components { sof.append(contentsOf: [UInt8(i + 1), 0x11, 0]) }
        var data = Data([0xFF, 0xD8])
        data.append(segment(marker: progressive ? 0xC2 : 0xC0, payload: sof))
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    private func containsSegment(_ data: Data, marker: UInt8) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count > 2 else { return false }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && bytes[i + 1] == marker { return true }
        return false
    }


    @Test("PNG-Metadatenentfernung lehnt fehlendes IEND ab und erhält nachfolgende Bytes")
    func stripPNGRequiresCompleteChunks() throws {
        let original = try Fixtures.coverData("cover.png")
        for removed in [1, 8, 12] {
            #expect(throws: CoverToolError.unsupportedImage) {
                try CoverTools.stripMetadata(original.dropLast(removed))
            }
        }
        let trailing = original + Data("Anhang".utf8)
        #expect(try CoverTools.stripMetadata(trailing) == trailing)
    }
}

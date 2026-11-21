import Foundation
import Testing
@testable import TagExplosionCore

@Suite("ZIP-Prüfsummen")
struct ZipIntegrityTests {
    @Test("Komprimierte Metadaten und Cover werden vor unbegrenzter Extraktion abgelehnt")
    func rejectsOversizedEntries() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        try ZipContainer.rewrite(url: url, replacing: [
            "OEBPS/content.opf": Data(repeating: 0x20, count: ZipContainer.metadataSizeLimit + 1),
            "OEBPS/cover.jpg": Data(repeating: 0, count: ZipContainer.artworkSizeLimit + 1),
        ])
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let metadata = try #require(archive["OEBPS/content.opf"])
        let cover = try #require(archive["OEBPS/cover.jpg"])
        #expect(throws: TagError.self) { _ = try ZipContainer.data(of: metadata, in: archive) }
        #expect(throws: TagError.self) {
            _ = try ZipContainer.data(of: cover, in: archive, maximumSize: ZipContainer.artworkSizeLimit)
        }
        #expect(try Data(contentsOf: url).count < 100_000)
    }
    /// Nur die gespeicherte Prüfsumme ändern: Inhalt und ZIP-Struktur bleiben
    /// lesbar, sodass nicht schon ein XML-/Deflate-Fehler die Prüfung ersetzt.
    private func corruptChecksum(_ path: String, in url: URL) throws {
        var bytes = try Data(contentsOf: url)
        let name = try #require(bytes.range(of: Data(path.utf8), options: .backwards))
        let header = name.lowerBound - 46
        try #require(header >= 0)
        try #require(bytes.subdata(in: header..<(header + 4)) == Data([0x50, 0x4b, 0x01, 0x02]))
        bytes[header + 16] ^= 0xff
        try bytes.write(to: url)
    }

    @Test("Beschädigte Metadaten und Cover werden nicht als gültiger Lesestand übernommen", arguments: [
        ("doc.docx", "docProps/core.xml"), ("doc.odt", "meta.xml"),
        ("comic.cbz", "ComicInfo.xml"), ("book2.epub", "META-INF/container.xml"),
        ("book2.epub", "OEBPS/content.opf"), ("book2.epub", "OEBPS/cover.jpg"),
    ])
    func rejectsDamagedRead(item: (String, String)) throws {
        let url = try Fixtures.workingCopy(item.0)
        try corruptChecksum(item.1, in: url)
        if url.pathExtension == "epub" {
            #expect(throws: TagError.self) { _ = try EbookTool.readSnapshot(url: url, includeCover: true) }
        } else {
            #expect(throws: TagError.self) { _ = try DocumentTool.readSnapshot(url: url, includeCover: true) }
        }
    }

    @Test("Beschädigte Nutzdaten werden beim ZIP-Neuaufbau nicht still bestätigt", arguments: [false, true])
    func damagedPayloadPreventsRewrite(large: Bool) throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let path = "word/document.xml"
        if large {
            var data = try #require(try ZipContainer.data(at: path, in: ZipContainer.open(url: url, accessMode: .read)))
            data.append(Data(repeating: 0x20, count: 2 * 1024 * 1024))
            try ZipContainer.rewrite(url: url, replacing: [path: data])
        }
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Darf nicht gespeichert werden"
        try corruptChecksum(path, in: url)
        let before = try Data(contentsOf: url)
        #expect(throws: TagError.cannotOpen(path: url.path)) {
            try DocumentTool.write(url: url, fields: edited, original: original)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Falsche ZIP- und ZIP64-Verzeichnisangaben verhindern das Speichern",
          arguments: [-1, 1], [false, true])
    func incompleteDirectoryPreventsRewrite(difference: Int, zip64: Bool) throws {
        let url = try Fixtures.workingCopy("doc.docx")
        var before = try Data(contentsOf: url)
        let end = try #require(before.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards))
        try #require(end.lowerBound + 22 == before.count)
        if zip64 { addZIP64End(to: &before, at: end.lowerBound, difference: difference) }
        else {
            before[end.lowerBound + 8] = UInt8(Int(before[end.lowerBound + 8]) + difference)
            before[end.lowerBound + 10] = UInt8(Int(before[end.lowerBound + 10]) + difference)
        }
        try before.write(to: url)

        #expect(throws: TagError.cannotOpen(path: url.path)) {
            try ZipContainer.rewrite(url: url, replacing: ["word/document.xml": Data("Geändert".utf8)])
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Ein gültiges ZIP64-Verzeichnis lässt sich verlustfrei neu aufbauen")
    func rewritesZIP64Directory() throws {
        let url = try Fixtures.workingCopy("doc.docx")
        var bytes = try Data(contentsOf: url)
        let end = try #require(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards))
        let entries = try ZipContainer.entries(url: url)
        addZIP64End(to: &bytes, at: end.lowerBound, difference: 0)
        try bytes.write(to: url)
        #expect(try ZipContainer.entries(url: url) == entries)
        try ZipContainer.rewrite(url: url, replacing: [:])
        #expect(try ZipContainer.entries(url: url) == entries)
    }

    @Test("ZIP-Kommentar mit abweichendem Verzeichnis verhindert den Neuaufbau", arguments: [false, true])
    func rejectsDifferentDirectoryInComment(validInnerCommentLength: Bool) throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let expected = try ZipContainer.entries(url: url)
        var bytes = try Data(contentsOf: url)
        let signature = try #require(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards))
        let end = signature.lowerBound
        try #require(end + 22 == bytes.count)
        let offset = bytes.withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: end + 16, as: UInt32.self)))
        }
        var directory = bytes.subdata(in: offset..<end)
        directory[46] ^= 1
        var competingEnd = bytes.subdata(in: end..<bytes.count)
        withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { competingEnd.replaceSubrange(16..<20, with: $0) }
        let commentSize = UInt16(directory.count + competingEnd.count + (validInnerCommentLength ? 0 : 1))
        withUnsafeBytes(of: commentSize.littleEndian) { bytes.replaceSubrange((end + 20)..<(end + 22), with: $0) }
        bytes.append(directory)
        bytes.append(competingEnd)
        if !validInnerCommentLength { bytes.append(0) }
        try bytes.write(to: url)

        #expect(try ZipContainer.entries(url: url) != expected)
        #expect(throws: TagError.cannotOpen(path: url.path)) {
            try ZipContainer.rewrite(url: url, replacing: [:])
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    private func addZIP64End(to bytes: inout Data, at end: Int, difference: Int) {
        var extensionBytes = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { extensionBytes.append(contentsOf: $0) }
        }
        func read32(at offset: Int) -> UInt64 {
            bytes.withUnsafeBytes {
                UInt64(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        let entryCount = UInt64(Int(bytes[end + 10]) + difference)
        append(UInt32(0x06064b50))
        append(UInt64(44))
        append(UInt16(45))
        append(UInt16(45))
        append(UInt64(0))
        append(entryCount)
        append(entryCount)
        append(read32(at: end + 12))
        append(read32(at: end + 16))
        append(UInt32(0x07064b50))
        append(UInt32(0))
        append(UInt64(end))
        append(UInt32(1))
        bytes.replaceSubrange((end + 8)..<(end + 20), with: repeatElement(UInt8.max, count: 12))
        bytes.insert(contentsOf: extensionBytes, at: end)
    }
}

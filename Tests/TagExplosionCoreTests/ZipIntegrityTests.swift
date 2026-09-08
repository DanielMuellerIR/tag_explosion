import Foundation
import Testing
@testable import TagExplosionCore

@Suite("ZIP-Prüfsummen")
struct ZipIntegrityTests {
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
        #expect(throws: TagError.self) { try DocumentTool.write(url: url, fields: edited, original: original) }
        #expect(try Data(contentsOf: url) == before)
    }
}

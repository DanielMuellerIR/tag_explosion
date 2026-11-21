import CTagShim
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("TagLib-C-Schnittstelle")
struct TagShimContractTests {
    @Test("Lesefehler melden keine Teilresultate")
    func readErrorOutputs() {
        var count: Int32 = 0
        #expect(tx_get_properties(nil, &count) == nil)
        #expect(count == -1)

        count = 0
        #expect(tx_get_pictures(nil, &count) == nil)
        #expect(count == -1)

        count = 0
        #expect(tx_get_chapters(nil, &count) == nil)
        #expect(count == -1)

        count = 0
        #expect(tx_layers_get(nil, &count) == nil)
        #expect(count == -1)

        let previousLanguage = strdup("deu")
        defer { free(previousLanguage) }
        var language = previousLanguage
        count = 0
        #expect(tx_get_synced_lyrics(nil, &count, &language) == nil)
        #expect(count == -1)
        #expect(language == nil)
    }

    @Test("Ungültige Arraylängen werden ohne Tag-Änderung abgelehnt", arguments: [Int32(-1), 1])
    func invalidWriteCount(count: Int32) throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Titel")],
            artworks: [Artwork(data: try Fixtures.coverData("cover.jpg"), mimeType: "image/jpeg")],
            chapters: [Chapter(title: "Intro", startMilliseconds: 0, endMilliseconds: 200)],
            syncedLyrics: [SyncedLyricLine(milliseconds: 50, text: "Zeile")],
            to: url
        )
        let before = try TagFile.read(at: url)
        let handle = try #require(tx_open(url.path))
        defer { tx_close(handle) }
        #expect(tx_set_properties(handle, nil, count) == -1)
        #expect(tx_set_pictures(handle, nil, count) == 0)
        #expect(tx_set_chapters(handle, nil, count) == 0)
        #expect(tx_set_synced_lyrics(handle, nil, count, nil, 0) == 0)
        try #require(tx_save(handle) == 1)

        let after = try TagFile.read(at: url)
        #expect(after.properties == before.properties)
        #expect(after.artworks == before.artworks)
        #expect(after.chapters == before.chapters)
        #expect(after.syncedLyrics == before.syncedLyrics)
    }

    @Test("Leere SYLT-Frames behalten die Sprache")
    func emptySyncedFrameLanguage() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try #require(tx_open(url.path))
        defer { tx_close(handle) }
        try #require(tx_set_synced_lyrics(handle, nil, 0, "deu", 1) == 1)

        var count: Int32 = -1
        var language: UnsafeMutablePointer<CChar>?
        let lines = tx_get_synced_lyrics(handle, &count, &language)
        defer {
            tx_free_synced_lyrics(lines, count)
            free(language)
        }
        #expect(lines == nil)
        #expect(count == 0)
        #expect(language.map { String(cString: $0) } == "deu")
    }

    @Test("Native ID3-Felder verlangen eine vier Byte lange Frame-ID")
    func nativeID3FrameLength() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let handle = try #require(tx_open(url.path))
        defer { tx_close(handle) }
        #expect(tx_native_field_supported(handle, "TKWD", nil) == 1)
        #expect(tx_native_field_supported(handle, "TKW", nil) == 0)
        #expect(tx_set_native_field(handle, "TKW", nil, nil) == 0)
    }
}

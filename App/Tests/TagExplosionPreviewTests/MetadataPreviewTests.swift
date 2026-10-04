import Foundation
import Testing
import TagExplosionCore
import TagExplosionPreviewSupport
import TagExplosionTestSupport

@Suite("Quick-Look-Metadaten")
struct MetadataPreviewTests {
    @Test("MP3 und EPUB liefern echte Tags und Cover", arguments: ["sample.mp3", "book2.epub"])
    func nativePreview(_ fixture: String) throws {
        let url = try MediaTestFixtures.workingCopy(fixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        if fixture == "sample.mp3" {
            let cover = try Data(contentsOf: MediaTestFixtures.directory().appendingPathComponent("cover.jpg"))
            try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Vorschau-Test")],
                              artworks: [Artwork(data: cover, mimeType: "image/jpeg", pictureType: "Front Cover")], to: url)
        }
        let before = try Data(contentsOf: url)
        let preview = try MetadataPreview.read(url: url)
        #expect(preview.rows.contains { $0.0 == "TITLE" && !$0.1.isEmpty })
        #expect(preview.cover != nil)
        #expect(try Data(contentsOf: url) == before)
    }

}

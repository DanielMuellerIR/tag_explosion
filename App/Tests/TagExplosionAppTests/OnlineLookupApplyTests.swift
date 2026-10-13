import Foundation
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Online-Übernahme: eingebettete Bilder")
@MainActor
struct OnlineLookupApplyTests {
    @Test("Frontcover wird hinter dem Booklet ersetzt oder ergänzt", arguments: [false, true])
    func preservesBooklet(hasFront: Bool) async throws {
        let url = AppTestFixtures.directory.appendingPathComponent("sample.mp3")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("sample.mp3")
        try FileManager.default.copyItem(at: url, to: copy)
        let booklet = Artwork(data: try Data(contentsOf: AppTestFixtures.directory.appendingPathComponent("cover.jpg")),
                              mimeType: "image/jpeg", pictureType: "Leaflet Page", description: "Booklet")
        let old = Artwork(data: booklet.data, mimeType: "image/jpeg", pictureType: "Front Cover")
        try TagFile.write(artworks: hasFront ? [booklet, old] : [booklet], to: copy)
        let entry = FileEntry(url: copy, loaded: .audio(try TagFile.read(at: copy)))
        let new = Artwork(data: try Data(contentsOf: AppTestFixtures.directory.appendingPathComponent("cover.png")),
                          mimeType: "image/png", pictureType: "Front Cover")
        let plan = LookupPlan(fileURL: copy, changes: [.init(key: "TITLE", oldValue: nil, newValue: "Lookup title")])
        entry.applyLookup(plan, artwork: new)
        #expect(entry.artworks == (hasFront ? [booklet, new] : [new, booklet]))
        #expect(entry.firstValue("TITLE") == "Lookup title")
        let model = AppModel()
        #expect(await model.save(entry: entry))
        #expect(try TagFile.read(at: copy).artworks == (hasFront ? [booklet, new] : [new, booklet]))
        #expect(CoverToolActions.sharedCover(of: [entry]) == new)
        let folderCover = folder.appendingPathComponent("folder.png")
        try new.data.write(to: folderCover)
        let outcome = CoverToolActions.applyFolderCover([entry])
        #expect(outcome.unchanged == 1)
        #expect(await model.save(entry: entry))
        let saved = try TagFile.read(at: copy).artworks
        #expect(saved.filter { $0.pictureType == "Leaflet Page" } == [booklet])
        #expect(saved.filter { $0.pictureType == "Front Cover" }.count == 1)
        #expect(saved.first(where: { $0.pictureType == "Front Cover" })?.data == new.data)

    }
}

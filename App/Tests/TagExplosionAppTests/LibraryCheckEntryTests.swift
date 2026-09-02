// Konsistenzprüfung im Modell: Die Items entstehen aus den Bearbeitungs-
// puffern (ungespeicherte Änderungen zählen), nicht prüfbare Medienarten
// fallen heraus, und die Prüfung verändert weder Puffer noch Dateien.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("AppModel Konsistenzprüfung")
@MainActor
struct LibraryCheckEntryTests {

    private func audioEntry(_ name: String, _ fields: [String: String],
                            artworks: [Artwork] = []) -> FileEntry {
        let properties = fields.sorted { $0.key < $1.key }
            .map { TagProperty(key: $0.key, value: $0.value) }
        return FileEntry(
            url: URL(fileURLWithPath: "/lib/album/\(name)"),
            loaded: .audio(TagData(properties: properties, artworks: artworks,
                                   audio: AudioInfo(lengthMilliseconds: 120_000, bitrateKbps: 128,
                                                    sampleRateHz: 44_100, channels: 2))),
            stamp: nil)
    }

    @Test("Puffer statt Platte: eine ungespeicherte Änderung entfernt den Befund")
    func bufferCountsNotOriginal() {
        let entry = audioEntry("01.mp3", ["TITLE": "", "ARTIST": "Duo", "ALBUM": "A",
                                          "ALBUMARTIST": "Duo", "TRACKNUMBER": "1/1"],
                               artworks: [Artwork(data: Data([0xFF, 0xD8, 0xFF, 0xE0]))])
        let model = AppModel()
        model.entries = [entry]
        let before = model.libraryCheckReport(for: [entry], pattern: nil)
        #expect(before.findings.map(\.code) == [.emptyTitle])

        entry.setSingleValue("TITLE", "Eins")
        let after = model.libraryCheckReport(for: [entry], pattern: nil)
        #expect(after.findings.isEmpty)
        #expect(entry.isDirty)
        #expect(after.checkedFiles == 1)
    }

    @Test("Rechnung und Playlist fallen heraus; Bild und Dokument nur mit Titelprüfung")
    func unsupportedKindsAreSkipped() {
        let image = FileEntry(url: URL(fileURLWithPath: "/pics/a.jpg"),
                              loaded: .image(ImageCoreReading(fields: ImageCoreFields())), stamp: nil)
        let document = FileEntry(url: URL(fileURLWithPath: "/docs/d.docx"),
                                 loaded: .document(DocumentCoreFields(title: "D"), cover: nil, info: []),
                                 stamp: nil)
        let playlist = FileEntry(
            url: URL(fileURLWithPath: "/lists/l.m3u"),
            loaded: .playlist(PlaylistContents(format: .m3u, fields: PlaylistCoreFields(), entries: [])),
            stamp: nil)
        #expect(playlist.libraryCheckItem == nil)
        #expect(image.libraryCheckItem?.kind == .image)
        let report = AppModel().libraryCheckReport(for: [image, document, playlist], pattern: nil)
        #expect(report.checkedFiles == 2)
        #expect(report.findings.map(\.code) == [.emptyTitle])
        #expect(report.findings.first?.files == ["/pics/a.jpg"])
    }

    @Test("E-Book: ein im Puffer gewähltes Cover gilt als vorhanden")
    func ebookCoverReplacementCounts() {
        let ebook = FileEntry(url: URL(fileURLWithPath: "/books/b.epub"),
                              loaded: .ebook(EbookCoreFields(title: "B"), cover: nil), stamp: nil)
        #expect(ebook.libraryCheckItem?.covers == [])
        ebook.setEbookCover(Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ebook.libraryCheckItem?.covers?.count == 1)
    }

    @Test("Muster aus dem Sheet erreicht die Dateinamenprüfung")
    func patternReachesCheck() throws {
        let entry = audioEntry("zwei.mp3", ["TITLE": "Zwei", "ARTIST": "Duo", "ALBUM": "A",
                                            "ALBUMARTIST": "Duo", "TRACKNUMBER": "2/2"],
                               artworks: [Artwork(data: Data([0xFF, 0xD8, 0xFF, 0xE0]))])
        let report = AppModel().libraryCheckReport(
            for: [entry], pattern: try FilenamePattern("%{track:2} - %{title}"))
        // Eine einzelne Datei bekommt keine Lücken-Prüfung — nur das Muster greift.
        #expect(report.findings.map(\.code) == [.filenameMismatch])
        #expect(libraryCheckRuleTitle(.filenameMismatch).isEmpty == false)
    }
}

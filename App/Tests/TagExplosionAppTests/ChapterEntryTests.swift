// Kapitel im Editor-Puffer: dirty-Erkennung, Snapshot nur für Formate mit
// Kapiteln, Übernahme des Read-backs — headless, ohne Fenster.
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("FileEntry Kapitel", .serialized)
@MainActor
struct ChapterEntryTests {

    @Test("Eine reine Tagänderung erteilt keinen Kapitel-Schreibauftrag")
    func unchangedChaptersStayUntouched() throws {
        let original = TagData(properties: [], artworks: [], audio: nil,
                               chapters: sample, supportsChapters: true)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/kapitel.mp3"),
                              loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: "Neuer Titel")]
        let snapshot = try #require(entry.beginSaving())
        guard case .audio(let audio) = snapshot else { Issue.record("Audio erwartet"); return }
        #expect(audio.chapters == nil)
        entry.finishSaving()
        entry.chapters = []
        guard case .audio(let clearing)? = entry.beginSaving() else { Issue.record("Audio erwartet"); return }
        #expect(clearing.chapters == [])
        entry.finishSaving()
    }

    @Test("Eine App-Tagänderung erhält fremde CHAP-Unterframes")
    func tagSavePreservesChapterSubframes() async throws {
        let url = try MediaTestFixtures.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var bytes = try Data(contentsOf: url)
        if bytes.starts(with: Data("ID3".utf8)) {
            let size = bytes[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) }
            bytes.removeFirst(10 + size)
        }
        func bigEndian(_ value: Int) -> [UInt8] {
            [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        }
        func frame(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            Array(name.utf8) + bigEndian(payload.count) + [0, 0] + payload
        }
        let marker = "Review-CHAP-Marker"
        let subframes = frame("TIT2", [3] + Array("Intro".utf8))
            + frame("TXXX", [3] + Array("Custom".utf8) + [0] + Array(marker.utf8))
        let chapter = Array("chapter1".utf8) + [0] + bigEndian(0) + bigEndian(1000)
            + Array(repeating: UInt8(255), count: 8) + subframes
        let frames = frame("CHAP", chapter)
        let size = [21, 14, 7, 0].map { UInt8((frames.count >> $0) & 0x7f) }
        try (Data(Array("ID3".utf8) + [3, 0, 0] + size + frames) + bytes).write(to: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        #expect(entry.chapters.map(\.title) == ["Intro"])
        entry.setSingleValue("TITLE", "Neuer Titel")
        #expect(await AppModel().save(entry: entry))
        #expect(try Data(contentsOf: url).range(of: Data(marker.utf8)) != nil)
        #expect(try TagFile.read(at: url).chapters.map(\.title) == ["Intro"])
    }

    private let sample = [
        Chapter(title: "Intro", startMilliseconds: 0, endMilliseconds: 1000),
        Chapter(title: "Zwei", startMilliseconds: 1000, endMilliseconds: 2000),
    ]

    @Test("Geänderte Kapitel machen den Eintrag dirty; Verwerfen stellt sie zurück")
    func chaptersAffectDirtyState() {
        let original = TagData(properties: [], artworks: [], audio: nil,
                               chapters: sample, supportsChapters: true)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/kapitel.mp3"), loaded: .audio(original))
        #expect(entry.supportsChapters)
        #expect(entry.chapters == sample)
        #expect(!entry.isDirty)

        entry.chapters[1].title = "Zwei (neu)"
        #expect(entry.isDirty)
        entry.revert()
        #expect(entry.chapters == sample)
        #expect(!entry.isDirty)
    }

    @Test("Neuer Eintragspfad erhält Kapitel- und Lyrics-Puffer samt Original")
    func relocatingPreservesAudioEdits() throws {
        let original = TagData(properties: [], artworks: [], audio: nil,
            chapters: sample, supportsChapters: true,
            lyricsLanguage: "deu", supportsSyncedLyrics: true)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/alt.mp3"),
                              loaded: .audio(original), stamp: nil)
        entry.chapters[1].title = "Neuer Kapitelname"
        entry.syncedLyrics = [SyncedLyricLine(milliseconds: 0, text: "Neue Zeile")]
        entry.lyricsLanguage = "eng"
        let relocated = try #require(FileEntry(relocating: entry,
            to: URL(fileURLWithPath: "/tmp/neu.mp3")))
        #expect(relocated.original == original)
        #expect(relocated.chapters == entry.chapters)
        #expect(relocated.syncedLyrics == entry.syncedLyrics)
        #expect(relocated.lyricsLanguage == entry.lyricsLanguage)
        #expect(relocated.isDirty)
        relocated.revert()
        #expect(!relocated.isDirty)
        #expect(entry.isDirty)
    }

    @Test("Snapshot trägt Kapitel nur bei Formaten mit Kapiteln")
    func snapshotCarriesChaptersOnlyWhenSupported() {
        let supported = FileEntry(
            url: URL(fileURLWithPath: "/tmp/kapitel.mp3"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil, supportsChapters: true)))
        supported.chapters = sample
        guard case .audio(let snapshot)? = supported.beginSaving(), let chapters = snapshot.chapters else {
            Issue.record("Snapshot fehlt")
            return
        }
        #expect(chapters == sample)
        supported.finishSaving()

        // FLAC: Kapitel-Puffer bleibt leer und wandert als nil in den Snapshot —
        // der Schreibweg fasst die Kapitel dann gar nicht an.
        let unsupported = FileEntry(
            url: URL(fileURLWithPath: "/tmp/ohne.flac"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil, supportsChapters: false)))
        #expect(!unsupported.supportsChapters)
        unsupported.properties = [TagProperty(key: "TITLE", value: "dirty")]
        guard case .audio(let snapshot)? = unsupported.beginSaving(), case let none = snapshot.chapters else {
            Issue.record("Snapshot fehlt")
            return
        }
        #expect(none == nil)
        unsupported.finishSaving()
    }

    @Test("Read-back nach dem Speichern wird zum neuen Original")
    func acceptSavedTakesReadBack() async {
        let entry = FileEntry(
            url: URL(fileURLWithPath: "/tmp/kapitel.mp3"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil, supportsChapters: true)))
        entry.chapters = sample
        let model = AppModel()
        let readBack = TagData(properties: [], artworks: [], audio: nil,
                               chapters: sample, supportsChapters: true)
        let saved = await model.save(entry: entry) { snapshot in
            guard case .audio(let audio) = snapshot, audio.chapters == self.sample else {
                throw TagError.saveFailed(path: "snapshot")
            }
            return (.audio(readBack), nil)
        }
        #expect(saved)
        #expect(!entry.isDirty)
        #expect(entry.chapters == sample)
    }
}

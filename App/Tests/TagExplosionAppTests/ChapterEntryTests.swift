// Kapitel im Editor-Puffer: dirty-Erkennung, Snapshot nur für Formate mit
// Kapiteln, Übernahme des Read-backs — headless, ohne Fenster.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("FileEntry Kapitel", .serialized)
@MainActor
struct ChapterEntryTests {

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

import Foundation
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Kapitel-Editor")
@MainActor
struct ChapterEditorTests {
    @Test("Bindings entfernten Kapitels lesen einen Ersatzwert und schreiben nicht")
    func removedChapterBinding() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/chapters.mp3"), loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        entry.chapters = [Chapter(title: "Alt", startMilliseconds: 0, endMilliseconds: 1000)]
        let title = ChapterSection.binding(entry, index: 0, keyPath: \.title, fallback: "")
        let end = ChapterSection.binding(entry, index: 0, keyPath: \.endMilliseconds, fallback: 0)
        title.wrappedValue = "Neu"
        end.wrappedValue = 2000
        #expect(entry.chapters[0].title == "Neu")
        #expect(entry.chapters[0].endMilliseconds == 2000)
        entry.chapters.removeAll()
        #expect(title.wrappedValue == "")
        #expect(end.wrappedValue == 0)
        title.wrappedValue = "Verspätet"
        end.wrappedValue = 3000
        #expect(entry.chapters.isEmpty)
    }
}

import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Dateiliste und verzögerte Prüfung")
@MainActor
struct FileListTests {
    @Test("Suche, stabile Sortierung und versteckte Auswahl bewahren Puffer und Nummerierung")
    func filtering() throws {
        let a = FileEntry(url: URL(fileURLWithPath: "/b.flac"), loaded: .audio(TagData(
            properties: [TagProperty(key: "TITLE", value: "Gleich"), TagProperty(key: "ARTIST", value: "Miles")], artworks: [], audio: nil)))
        let b = FileEntry(url: URL(fileURLWithPath: "/a.flac"), loaded: .audio(TagData(
            properties: [TagProperty(key: "TITLE", value: "Gleich"), TagProperty(key: "ARTIST", value: "Coltrane")], artworks: [], audio: nil)))
        let model = AppModel()
        model.entries = [a, b]
        model.selection = [a.url, b.url]
        a.setSingleValue("COMMENT", "Puffer")
        b.lastError = "IO"
        model.listSort = .title
        #expect(model.visibleEntries.map(\.url) == [a.url, b.url])
        model.listSort = .filename
        #expect(model.visibleEntries.map(\.url) == [b.url, a.url])
        #expect(model.selectedEntries.map(\.url) == [a.url, b.url])
        model.listSearch = "miles"
        #expect(model.visibleEntries.map(\.url) == [a.url])
        #expect(model.hiddenSelectionCount == 1)
        model.visibleSelection = []
        #expect(model.selection == [b.url])
        model.listSearch = ""
        model.listDirtyOnly = true
        #expect(model.visibleEntries.map(\.url) == [a.url])
        model.listDirtyOnly = false
        model.listErrorsOnly = true
        #expect(model.visibleEntries.map(\.url) == [b.url])
        model.listKind = .image
        #expect(model.visibleEntries.isEmpty)
        #expect(a.firstValue("COMMENT") == "Puffer")
        model.selection = [a.url, b.url]
        let plans = try model.rulePlan(for: model.selectedEntries, document: TagRuleDocument(rules: [TagRule(action: .number)]))
        #expect(plans.first { $0.url == b.url }?.newValues["TRACKNUMBER"] == "1")
    }

    @Test("Veraltete Prüfung überschreibt keine neue; ungültiges Muster entfernt Bericht")
    func staleCheck() async throws {
        let state = LibraryCheckState()
        let gate = ReportGate()
        let request = LibraryCheckRequest(items: [], checkNames: false, pattern: "")
        let old = state.submit(request, delay: .zero) { _, _ in
            await gate.wait()
            return LibraryCheck.run([])
        }
        for _ in 0..<2000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await gate.started)
        let item = LibraryCheck.Item(url: URL(fileURLWithPath: "/a.flac"), kind: .audio, properties: [])
        let newer = state.submit(LibraryCheckRequest(items: [item], checkNames: false, pattern: ""), delay: .zero)
        await newer.value
        #expect(state.report?.checkedFiles == 1)
        await gate.release()
        await old.value
        #expect(state.report?.checkedFiles == 1)
        await state.submit(LibraryCheckRequest(items: [], checkNames: true, pattern: "%{"), delay: .zero).value
        #expect(state.report == nil)
        #expect(state.error != nil)
    }
}

private actor ReportGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

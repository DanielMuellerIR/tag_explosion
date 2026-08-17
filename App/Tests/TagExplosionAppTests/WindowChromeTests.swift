// Fensterkopf und Seitenleiste: Die Regeln sind reine Umwandlungen und
// werden hier ohne Fenster geprüft.
import Foundation
import SwiftUI
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Fensterkopf")
@MainActor
struct WindowChromeTests {

    private func entry(title: String, path: String,
                       isDirty: Bool = false, isSaving: Bool = false) -> WindowChromeEntry {
        WindowChromeEntry(title: title, url: URL(fileURLWithPath: path),
                          isDirty: isDirty, isSaving: isSaving)
    }

    @Test("Weicht der Titel vom Dateinamen ab, steht der Dateiname daneben")
    func fileNameIsVisibleNextToTitle() {
        let chrome = WindowChrome.make(
            selected: [entry(title: "4D Write Pro Neues Dokument",
                             path: "/tmp/Rechnung_68667.pdf")],
            totalCount: 1)
        #expect(chrome.title == "4D Write Pro Neues Dokument")
        #expect(chrome.subtitle == "Rechnung_68667.pdf")
        #expect(chrome.documentURL == URL(fileURLWithPath: "/tmp/Rechnung_68667.pdf"))
    }

    @Test("Ist der Titel schon der Dateiname, steht er nicht zweimal da")
    func fileNameIsNotRepeated() {
        let chrome = WindowChrome.make(
            selected: [entry(title: "lied.mp3", path: "/tmp/lied.mp3")],
            totalCount: 1)
        #expect(chrome.title == "lied.mp3")
        #expect(chrome.subtitle.isEmpty)
    }

    @Test("Bearbeitet und Speichert stehen hinter dem Dateinamen")
    func statusFollowsFileName() {
        let dirty = WindowChrome.make(
            selected: [entry(title: "Titel", path: "/tmp/lied.mp3", isDirty: true)],
            totalCount: 1)
        #expect(dirty.subtitle == "lied.mp3 · Bearbeitet")

        // Während des Schreibens zählt nur der Speicherhinweis.
        let saving = WindowChrome.make(
            selected: [entry(title: "Titel", path: "/tmp/lied.mp3",
                             isDirty: true, isSaving: true)],
            totalCount: 1)
        #expect(saving.subtitle == "lied.mp3 · Speichert …")
    }

    @Test("Mehrfachauswahl vertritt keine einzelne Datei")
    func multipleSelectionHasNoDocument() {
        let chrome = WindowChrome.make(
            selected: [entry(title: "A", path: "/tmp/a.mp3", isDirty: true),
                       entry(title: "B", path: "/tmp/b.mp3")],
            totalCount: 5)
        #expect(chrome.title == "2 Dateien")
        #expect(chrome.subtitle == "1 bearbeitet")
        #expect(chrome.documentURL == nil)
    }

    @Test("Ohne Auswahl zeigt der Kopf den App-Namen und die Anzahl")
    func emptySelection() {
        #expect(WindowChrome.make(selected: [], totalCount: 0)
            == WindowChrome(title: "Tag Explosion", subtitle: "", documentURL: nil))
        #expect(WindowChrome.make(selected: [], totalCount: 3).subtitle == "3 Dateien")
    }

    @Test("Ein geladener Eintrag liefert seine Kopfdaten selbst")
    func fileEntryProvidesChromeData() {
        let url = URL(fileURLWithPath: "/tmp/kopf-test.mp3")
        let entry = FileEntry(url: url, loaded: .audio(
            TagData(properties: [TagProperty(key: "TITLE", value: "Ein Titel")],
                    artworks: [], audio: nil)))
        #expect(entry.chromeEntry == WindowChromeEntry(
            title: "Ein Titel", url: url, isDirty: false, isSaving: false))
    }

    @Test("Seitenleiste erst ab zwei Dateien")
    func sidebarOpensWithSecondFile() {
        #expect(SidebarRule.visibility(fileCount: 0) == .detailOnly)
        #expect(SidebarRule.visibility(fileCount: 1) == .detailOnly)
        #expect(SidebarRule.visibility(fileCount: 2) == .all)
        #expect(SidebarRule.visibility(fileCount: 42) == .all)
    }
}

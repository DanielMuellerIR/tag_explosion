import AppKit
import Testing
@testable import TagExplosionApp

@Suite("Finder-Dienst", .serialized)
@MainActor
struct FinderServiceTests {
    @Test("Mehrfachauswahl erhält Unicode, Leerzeichen und Reihenfolge")
    func fileSelection() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/tmp/Ä & eins.mp3"), URL(fileURLWithPath: "/tmp/zwei.epub")]
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        #expect(FinderService.fileURLs(from: pasteboard) == urls)
    }

    @Test("Ältere Dateiliste funktioniert; Text und Netzwerk-URLs werden abgelehnt")
    func legacyAndInvalidSelections() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setPropertyList(["/tmp/eins.mp3", "relative.mp3"],
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        #expect(FinderService.fileURLs(from: pasteboard) == [URL(fileURLWithPath: "/tmp/eins.mp3")])
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.invalid/audio.mp3")! as NSURL])
        #expect(FinderService.fileURLs(from: pasteboard).isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("/tmp/eins.mp3", forType: .string)
        #expect(FinderService.fileURLs(from: pasteboard).isEmpty)
    }
}

import AppKit
import Testing
@testable import TagExplosionPreviewSupport

@Suite("Quick-Look-Auftragswechsel", .timeLimit(.minutes(1)))
@MainActor
struct MetadataPreviewControllerTests {
    @Test("Standardinitialisierung erstellt die echte Vorschauansicht")
    func standardInitializer() {
        let controller = MetadataPreviewController(nibName: nil, bundle: nil)
        #expect(controller.view.frame.size == NSSize(width: 680, height: 600))
        #expect(controller.preferredContentSize == NSSize(width: 680, height: 600))
    }
    @Test("Späte Vorschau ersetzt keine neuere und fügt keinen zweiten Inhalt hinzu")
    func stalePreview() async {
        let gate = PreviewGate()
        let controller = MetadataPreviewController(reader: { url in
            await gate.wait(url.lastPathComponent)
            return MetadataPreview(fileName: url.lastPathComponent, rows: [])
        })
        var completions: [(String, Bool)] = []
        controller.prepare(at: URL(fileURLWithPath: "/tmp/old.mp3")) { completions.append(("old", $0 == nil)) }
        await gate.started("old.mp3")
        controller.prepare(at: URL(fileURLWithPath: "/tmp/new.mp3")) { completions.append(("new", $0 == nil)) }
        await gate.started("new.mp3")
        await gate.release("new.mp3")
        while completions.isEmpty { await Task.yield() }
        #expect(controller.preview?.fileName == "new.mp3")
        #expect(controller.view.subviews.count == 1)
        await gate.release("old.mp3")
        while completions.count < 2 { await Task.yield() }
        #expect(controller.preview?.fileName == "new.mp3")
        #expect(controller.view.subviews.count == 1)
        #expect(completions.filter { $0.0 == "old" && !$0.1 }.count == 1)
        #expect(completions.filter { $0.0 == "new" && $0.1 }.count == 1)
    }
}

private actor PreviewGate {
    private var readers: [String: CheckedContinuation<Void, Never>] = [:]
    private var starts: [String: CheckedContinuation<Void, Never>] = [:]
    func wait(_ name: String) async {
        await withCheckedContinuation { continuation in
            readers[name] = continuation
            starts.removeValue(forKey: name)?.resume()
        }
    }
    func started(_ name: String) async {
        if readers[name] != nil { return }
        await withCheckedContinuation { starts[name] = $0 }
    }
    func release(_ name: String) { readers.removeValue(forKey: name)?.resume() }
}

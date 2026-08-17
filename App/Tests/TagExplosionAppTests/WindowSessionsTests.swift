// Verteilung geöffneter Dateien auf Fenster — headless, mit ersetzten
// AppKit-Zugriffen (Fensterzustand und Fenster-anlegen).
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Fenster-Registry", .serialized)
@MainActor
struct WindowSessionsTests {

    /// Registry mit prüfbarem Ersatz für alles, was sonst AppKit macht.
    private final class Harness {
        let sessions = WindowSessions()
        var visible: Set<ObjectIdentifier> = []
        var key: ObjectIdentifier?
        var closed: Set<ObjectIdentifier> = []
        var windowRequests = 0
        var opened: [(AppModel, [URL])] = []

        @MainActor
        init() {
            sessions.statusOf = { [unowned self] model in
                let id = ObjectIdentifier(model)
                guard !closed.contains(id) else { return WindowStatus() }
                return WindowStatus(exists: true, isVisible: visible.contains(id),
                                    isKey: key == id, isMain: key == id)
            }
            sessions.makeWindow = { [unowned self] in windowRequests += 1 }
            sessions.openInModel = { [unowned self] model, urls in opened.append((model, urls)) }
        }

        @MainActor
        func addWindow() -> AppModel {
            let model = AppModel()
            visible.insert(ObjectIdentifier(model))
            sessions.register(model)
            return model
        }

        @MainActor
        func close(_ model: AppModel) {
            let id = ObjectIdentifier(model)
            visible.remove(id)
            closed.insert(id)
            sessions.unregister(model)
        }
    }

    private let file = URL(fileURLWithPath: "/tmp/registry-test.mp3")

    @Test("Ohne Fenster wird eins angefordert und die Datei nachgereicht")
    func openWithoutWindowCreatesOne() {
        let harness = Harness()
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)
        #expect(harness.opened.isEmpty)

        // Genau das war der Fehler: Die Datei landete in einem Modell ohne
        // Fenster und war nirgends zu sehen. Jetzt wartet sie auf das Fenster.
        let model = harness.addWindow()
        #expect(harness.opened.count == 1)
        #expect(harness.opened.first?.0 === model)
        #expect(harness.opened.first?.1 == [file])
    }

    @Test("Ein zweiter Auftrag ohne Fenster fordert kein zweites Fenster an")
    func windowIsRequestedOnlyOnce() {
        let harness = Harness()
        harness.sessions.open(urls: [file])
        harness.sessions.open(urls: [URL(fileURLWithPath: "/tmp/zweite.mp3")])
        harness.sessions.requestWindow()
        #expect(harness.windowRequests == 1)

        let model = harness.addWindow()
        // Beide Wartenden kommen in einem Rutsch im neuen Fenster an.
        #expect(harness.opened.count == 1)
        #expect(harness.opened.first?.0 === model)
        #expect(harness.opened.first?.1.count == 2)
    }

    @Test("Dateien landen im vordersten Fenster")
    func openGoesToFrontmostWindow() {
        let harness = Harness()
        let first = harness.addWindow()
        let second = harness.addWindow()
        harness.key = ObjectIdentifier(first)

        harness.sessions.open(urls: [file])
        #expect(harness.opened.last?.0 === first)

        harness.key = ObjectIdentifier(second)
        harness.sessions.open(urls: [file])
        #expect(harness.opened.last?.0 === second)
        #expect(harness.windowRequests == 0)
    }

    @Test("Ohne Schlüsselfenster entscheidet das zuletzt aktive Fenster")
    func lastActiveWindowWins() {
        let harness = Harness()
        let first = harness.addWindow()
        _ = harness.addWindow()
        harness.sessions.markActive(first)

        harness.sessions.open(urls: [file])
        #expect(harness.opened.last?.0 === first)
    }

    @Test("Nach dem Schließen des letzten Fensters entsteht wieder eins")
    func closingTheLastWindowDoesNotSwallowFiles() {
        let harness = Harness()
        let model = harness.addWindow()
        harness.close(model)
        #expect(harness.sessions.models.isEmpty)

        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)
        #expect(harness.opened.isEmpty)

        let replacement = harness.addWindow()
        #expect(harness.opened.first?.0 === replacement)
    }

    @Test("Ein Modell ohne Fenster wird nicht mehr beliefert")
    func modelWithoutWindowIsSkipped() {
        let harness = Harness()
        let model = harness.addWindow()
        // Fenster ist weg, die Abmeldung blieb aber aus (Sicherheitsnetz).
        harness.closed.insert(ObjectIdentifier(model))
        harness.visible.remove(ObjectIdentifier(model))

        harness.sessions.open(urls: [file])
        #expect(harness.opened.isEmpty)
        #expect(harness.windowRequests == 1)
    }

    @Test("Beenden fragt nur, wenn ein Fenster etwas zu verlieren hat")
    func terminationOnlyAsksWhenNeeded() async {
        let harness = Harness()
        let clean = harness.addWindow()
        #expect(!harness.sessions.needsTerminationConfirmation)
        #expect(await harness.sessions.confirmTermination())

        let dirty = harness.addWindow()
        dirty.entries = [Self.changedEntry()]
        #expect(harness.sessions.needsTerminationConfirmation)
        #expect(clean.entries.isEmpty)
    }

    @Test("Ein abgebrochenes Fenster hält das Beenden auf")
    func cancelInOneWindowStopsTermination() async {
        let harness = Harness()
        let dirty = harness.addWindow()
        dirty.entries = [Self.changedEntry()]

        let termination = Task { await harness.sessions.confirmTermination() }
        // Auf die Rückfrage des Fensters warten, ohne feste Wartezeit.
        var attempts = 0
        while dirty.pendingConflict == nil, attempts < 1000 {
            await Task.yield()
            attempts += 1
        }
        #expect(dirty.pendingConflict != nil)

        await dirty.resolvePendingConflict(.cancel)
        #expect(await termination.value == false)
    }

    private static func changedEntry() -> FileEntry {
        let entry = FileEntry(
            url: URL(fileURLWithPath: "/tmp/registry-dirty.mp3"),
            loaded: .audio(TagData(properties: [TagProperty(key: "TITLE", value: "Alt")],
                                   artworks: [], audio: nil)))
        entry.properties = [TagProperty(key: "TITLE", value: "Neu")]
        return entry
    }
}

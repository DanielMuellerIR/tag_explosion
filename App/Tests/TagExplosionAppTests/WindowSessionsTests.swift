// Verteilung geöffneter Dateien auf Fenster — headless, mit ersetzten
// AppKit-Zugriffen (Fensterzustand und Fenster-anlegen).
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Fenster-Registry")
@MainActor
struct WindowSessionsTests {
    @Test("Noch fokussierte geprüfte Eingaben schützen das Beenden")
    func pendingDraftRequiresTerminationConfirmation() {
        let harness = Harness()
        let model = harness.addWindow()
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/draft.mp3"),
            loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        model.entries = [entry]
        entry.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "-6 dB"
        #expect(harness.sessions.needsTerminationConfirmation)
        entry.revert()
        #expect(!harness.sessions.needsTerminationConfirmation)
    }

    /// Registry mit prüfbarem Ersatz für alles, was sonst AppKit macht.
    private final class Harness {
        let sessions = WindowSessions()
        var visible: Set<ObjectIdentifier> = []
        var key: ObjectIdentifier?
        var closed: Set<ObjectIdentifier> = []
        var windowRequests = 0
        /// Ergebnis des ersetzten Fensterstarts (false = Start scheitert).
        var windowLaunchSucceeds = true
        var opened: [(AppModel, [URL])] = []

        @MainActor
        init() {
            sessions.statusOf = { [unowned self] model in
                let id = ObjectIdentifier(model)
                guard !closed.contains(id) else { return WindowStatus() }
                return WindowStatus(exists: true, isVisible: visible.contains(id),
                                    isKey: key == id, isMain: key == id)
            }
            sessions.makeWindow = { [unowned self] in
                windowRequests += 1
                return windowLaunchSucceeds
            }
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

    @Test("Erneute Anmeldung eines alten Fensters verbraucht keinen Auftrag für das neue")
    func repeatedRegistrationKeepsNextWindowRequest() {
        let harness = Harness()
        let old = harness.addWindow()
        harness.sessions.queueForNextWindow(urls: [file])
        harness.sessions.requestWindow()
        harness.sessions.register(old)
        #expect(harness.opened.isEmpty)
        harness.sessions.requestWindow()
        #expect(harness.windowRequests == 1)
        let next = harness.addWindow()
        #expect(harness.opened.count == 1)
        #expect(harness.opened.first?.0 === next)
        #expect(harness.opened.first?.1 == [file])
    }

    @Test("Mehrere neue Fenster erhalten jeweils ihren eigenen Dateisatz")
    func queuedWindowsKeepSeparateFiles() {
        let harness = Harness()
        _ = harness.addWindow()
        let secondFile = URL(fileURLWithPath: "/tmp/second-window.mp3")
        harness.sessions.queueForNextWindow(urls: [file])
        harness.sessions.queueForNextWindow(urls: [secondFile])
        let first = harness.addWindow()
        let second = harness.addWindow()
        #expect(harness.opened.count == 2)
        #expect(harness.opened.first?.0 === first)
        #expect(harness.opened.first?.1 == [file])
        #expect(harness.opened.last?.0 === second)
        #expect(harness.opened.last?.1 == [secondFile])
    }

    @Test("Datei-Drops behalten ihre Reihenfolge trotz verspäteter Antworten")
    func dropOrderFollowsInput() {
        let first = URL(fileURLWithPath: "/tmp/first.mp3")
        let last = URL(fileURLWithPath: "/tmp/last.mp3")
        let collector = URLCollector(count: 3)
        collector.set(last, at: 2)
        collector.set(first, at: 0)
        #expect(collector.snapshot() == [first, last])
    }

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
    func cancelInOneWindowStopsTermination() async throws {
        let harness = Harness()
        let dirty = harness.addWindow()
        dirty.entries = [Self.changedEntry()]

        let termination = Termination(harness.sessions)
        defer { termination.cancel() }
        try await termination.waitForConflict(in: dirty)

        await dirty.resolvePendingConflict(.cancel)
        try await termination.expectAnswer(false)
    }

    // MARK: - Review-Fund 2026-08-18

    @Test("Ein fehlgeschlagener Fensterstart blockiert spätere Anforderungen nicht")
    func failedWindowLaunchDoesNotBlockLaterRequests() {
        let harness = Harness()
        harness.windowLaunchSucceeds = false

        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)

        // Vorher löste nur `register` den Merker: Nach einem gescheiterten
        // Start wies die Registry bis zum App-Neustart jede Anforderung ab.
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 2)
    }

    @Test("Bleibt das Fenster aus, wird begrenzt nachgefasst")
    func missingWindowIsRequestedAgainOnce() async throws {
        let harness = Harness()
        harness.sessions.windowRequestTimeout = .milliseconds(10)

        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)

        // Nach der Frist genau EIN Nachfassen — danach entscheidet wieder der
        // Nutzer, statt dass die App im Hintergrund endlos Fenster anfordert.
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 2)
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 2)

        // Der Merker ist frei: Das Fenster, das doch noch kommt, bekommt die
        // wartende Datei.
        let model = harness.addWindow()
        #expect(harness.opened.first?.0 === model)
        #expect(harness.opened.first?.1 == [file])
    }

    @Test("Ein während der Fragerunde erneut geändertes Fenster hält das Beenden auf")
    func windowChangedDuringRoundIsAskedAgain() async throws {
        let harness = Harness()
        let first = harness.addWindow()
        first.entries = [Self.changedEntry()]
        let second = harness.addWindow()
        second.entries = [Self.changedEntry()]

        let termination = Termination(harness.sessions)
        defer { termination.cancel() }

        try await termination.waitForConflict(in: first)
        await first.resolvePendingConflict(.discard)

        // Während das zweite Fenster fragt, wird im ersten wieder etwas
        // geändert. Genau das sah die einmal gebildete Fensterliste nicht.
        try await termination.waitForConflict(in: second)
        first.entries = [Self.changedEntry()]
        await second.resolvePendingConflict(.discard)

        // Zweite Runde: Das erste Fenster muss erneut gefragt werden.
        try await termination.waitForConflict(in: first)
        await first.resolvePendingConflict(.cancel)
        try await termination.expectAnswer(false)
    }

    @Test("Ein während der Fragerunde neu angemeldetes Fenster wird noch gefragt")
    func windowRegisteredDuringRoundIsAsked() async throws {
        let harness = Harness()
        let first = harness.addWindow()
        first.entries = [Self.changedEntry()]

        let termination = Termination(harness.sessions)
        defer { termination.cancel() }

        try await termination.waitForConflict(in: first)
        let late = harness.addWindow()
        late.entries = [Self.changedEntry()]
        await first.resolvePendingConflict(.discard)

        try await termination.waitForConflict(in: late)
        await late.resolvePendingConflict(.cancel)
        try await termination.expectAnswer(false)
    }

    // MARK: - Review-Fund 2026-08-20

    @Test("Ein angemeldetes Fenster bestellt den Watchdog der Anforderung ab")
    func registeringCancelsTheWatchdog() async throws {
        let harness = Harness()
        // Anforderung 1 …
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)
        let previousWatchdog = try #require(harness.sessions.windowRequestWatchdog)
        // … wird von einem Fenster erfüllt und danach wieder geschlossen.
        let model = harness.addWindow()
        harness.close(model)
        // Die nächste Anforderung darf der abbestellte Watchdog nicht übernehmen.
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 2)

        // Der Watchdog von Anforderung 1 darf jetzt nichts mehr tun. Vorher war
        // sein Token („Versuch 1") nach dem Zähler-Rücksetzen in `register`
        // nicht mehr eindeutig: Er hielt sich für den Watchdog von Anforderung 2
        // und forderte ein drittes Fenster an, während 2 noch unterwegs war.
        await previousWatchdog.value
        #expect(previousWatchdog.isCancelled)
        #expect(harness.windowRequests == 2)
        _ = harness.addWindow()
    }

    @Test("Der Nachfass-Etat gilt je Anforderungskette")
    func retryBudgetIsPerRequestChain() async throws {
        let harness = Harness()
        harness.sessions.windowRequestTimeout = .milliseconds(10)

        // Kette 1: Das Fenster bleibt aus, es wird einmal nachgefasst.
        harness.sessions.open(urls: [file])
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 2)
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 2)

        // Kette 2 aus einem neuen Nutzerereignis: Der Etat beginnt von vorn.
        // Vorher lief ein einziger Zähler über die ganze Sitzung — nach dem
        // ersten ausgebliebenen Fenster gab es nie wieder ein Nachfassen.
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 3)
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 4)
    }

    @Test("Ein fehlgeschlagener Start verbraucht keinen Nachfass-Versuch")
    func failedLaunchKeepsTheRetryBudget() async throws {
        let harness = Harness()
        harness.sessions.windowRequestTimeout = .milliseconds(10)
        harness.windowLaunchSucceeds = false

        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 1)

        // Der zweite Anlauf gelingt bis zum Start, das Fenster bleibt aber aus:
        // Der Watchdog muss trotzdem noch einmal nachfassen dürfen.
        harness.windowLaunchSucceeds = true
        harness.sessions.open(urls: [file])
        #expect(harness.windowRequests == 2)
        try await expireRequest(in: harness)
        #expect(harness.windowRequests == 3)
    }

    @Test("Ist der Runden-Etat aufgebraucht, bleibt die App offen")
    func terminationGivesUpWhenRoundsAreExhausted() async {
        let harness = Harness()
        // Null Runden bildet den Zustand nach der letzten Runde nach: Es wird
        // niemand mehr gefragt, und trotzdem darf die App nicht beenden,
        // solange ein Fenster etwas zu verlieren hat. Dieser Zweig war ohne
        // ersetzbare Rundenzahl aus den Tests nicht erreichbar.
        harness.sessions.maxTerminationRounds = 0
        let model = harness.addWindow()
        model.entries = [Self.changedEntry()]

        #expect(await harness.sessions.confirmTermination() == false)
        #expect(model.pendingConflict == nil)
    }

    /// `windowWillClose` erreicht die Registry nur, solange die Fensterbrücke
    /// noch der Delegate ist. Bleibt die Abmeldung aus, stand ein Modell ohne
    /// Fenster weiter in `models`; mit ungespeicherten Änderungen kam es in der
    /// Runde dran, sein Dialog erschien nirgends, und ⌘Q wartete für immer auf
    /// eine Antwort, die niemand mehr geben konnte.
    @Test("Beenden hängt nicht an einem Fenster, das sich nie abgemeldet hat")
    func terminationDropsWindowThatNeverUnregistered() async throws {
        let harness = Harness()
        let model = harness.addWindow()
        model.entries = [Self.changedEntry()]
        // Fenster weg, aber ohne `unregister` — genau der Fall, gegen den
        // `pruneClosedWindows` gebaut ist.
        harness.visible.remove(ObjectIdentifier(model))
        harness.closed.insert(ObjectIdentifier(model))

        let termination = Termination(harness.sessions)
        defer { termination.cancel() }
        try await termination.expectAnswer(true)
        #expect(model.pendingConflict == nil)
    }

    private func expireRequest(in harness: Harness) async throws {
        let watchdog = try #require(harness.sessions.windowRequestWatchdog)
        await watchdog.value
    }

    @MainActor
    private final class Termination {
        private let answered = TestSignal()
        private var answer: Bool?
        private var task: Task<Void, Never>?
        private let sessions: WindowSessions

        init(_ sessions: WindowSessions) {
            self.sessions = sessions
            task = Task { [weak self] in
                let answer = await sessions.confirmTermination()
                guard let self else { return }
                self.answer = answer
                self.answered.signal()
            }
        }

        func waitForConflict(in model: AppModel) async throws {
            try await waitForObservation("Rückfrage zum Beenden") { model.pendingConflict != nil }
        }

        func expectAnswer(_ expected: Bool) async throws {
            try await answered.wait(for: "Antwort auf die Anfrage zum Beenden")
            #expect(answer == expected)
        }

        func cancel() {
            guard answer == nil else { return }
            task?.cancel()
            Task {
                for model in sessions.models { await model.resolvePendingConflict(.cancel) }
            }
        }
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

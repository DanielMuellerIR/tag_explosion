import Foundation
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Online-Auswahl: verspätete Antworten", .timeLimit(.minutes(1)))
@MainActor
struct OnlineLookupDetailsTests {
    private func candidate(_ id: String) -> LookupCandidate {
        LookupCandidate(source: .musicbrainz, score: 100, artist: "Artist", album: id,
                        hasFullTracklist: true, coverURL: URL(string: "https://example.test/\(id)"),
                        identifiers: LookupIdentifiers(musicBrainzReleaseID: id))
    }

    @Test("Eine alte Detailantwort überschreibt weder Auswahl noch Fehler", arguments: [false, true])
    func staleDetails(fails: Bool) async throws {
        let state = OnlineLookupDetails()
        let gate = LookupGate()
        let oldCandidate = candidate("old"), newCandidate = candidate("new")
        let old = Task {
            await state.load(oldCandidate, includeCover: false, details: { item in
                await gate.wait()
                if fails { throw LookupError.httpStatus(source: .musicbrainz, status: 500) }
                return item
            }, cover: { _ in nil })
        }
        await gate.waitUntilStarted()
        await state.load(newCandidate, includeCover: false, details: { $0 }, cover: { _ in nil })
        gate.release()
        await old.value
        #expect(state.candidate == newCandidate)
        #expect(state.errorMessage == nil)
        #expect(!state.isBusy)
    }

    @Test("Ein altes Cover beendet keinen neuen Ladevorgang und gehört nicht zur neuen Auswahl")
    func staleCover() async {
        let state = OnlineLookupDetails()
        let oldGate = LookupGate(), newGate = LookupGate()
        let old = Task {
            await state.load(candidate("old"), includeCover: true, details: { $0 }, cover: { _ in
                await oldGate.wait()
                return Data([1])
            })
        }
        await oldGate.waitUntilStarted()
        let fresh = Task {
            await state.load(candidate("new"), includeCover: true, details: { $0 }, cover: { _ in
                await newGate.wait()
                return Data([2])
            })
        }
        await newGate.waitUntilStarted()
        oldGate.release()
        await old.value
        #expect(state.isBusy)
        #expect(state.coverData == nil)
        newGate.release()
        await fresh.value
        #expect(state.coverData == Data([2]))
        #expect(state.candidate == candidate("new"))
        #expect(!state.isBusy)
    }

    @Test("Ein aktueller Coverfehler lässt die geladenen Metadaten verfügbar")
    func currentCoverFailure() async {
        let state = OnlineLookupDetails()
        let selected = candidate("current")
        await state.load(selected, includeCover: true, details: { $0 }, cover: { _ in
            throw LookupError.httpStatus(source: .musicbrainz, status: 500)
        })
        #expect(state.candidate == selected)
        #expect(state.coverData == nil)
        #expect(state.errorMessage != nil)
        #expect(!state.isBusy)
    }

    @Test("Schließen verwirft eine noch laufende Antwort")
    func resetWhileLoading() async {
        let state = OnlineLookupDetails()
        let gate = LookupGate()
        let task = Task {
            await state.load(candidate("old"), includeCover: false, details: { item in
                await gate.wait()
                return item
            }, cover: { _ in nil })
        }
        await gate.waitUntilStarted()
        state.reset()
        gate.release()
        await task.value
        #expect(state.candidate == nil)
        #expect(!state.isBusy)
    }
}

@MainActor
private final class LookupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

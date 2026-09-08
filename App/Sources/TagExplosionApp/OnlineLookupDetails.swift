// Der Ladezustand einer Kandidatenauswahl, unabhängig vom SwiftUI-Sheet.
import Foundation
import Observation
import TagExplosionCore

@MainActor
@Observable
final class OnlineLookupDetails {
    private(set) var candidate: LookupCandidate?
    private(set) var coverData: Data?
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    // Jede Auswahl besitzt ihre Antworten. Alte Tasks dürfen weder Werte
    // noch Fehler oder den Beschäftigt-Zustand einer neueren Auswahl ändern.
    @ObservationIgnored private var requestID = UUID()

    func reset() {
        requestID = UUID()
        candidate = nil
        coverData = nil
        isBusy = false
        errorMessage = nil
    }

    func load(_ selected: LookupCandidate, includeCover: Bool,
              details: (LookupCandidate) async throws -> LookupCandidate,
              cover: (LookupCandidate) async throws -> Data?) async {
        guard !Task.isCancelled else { return }
        reset()
        let request = requestID
        isBusy = true
        defer { if requestID == request { isBusy = false } }
        do {
            let full = try await details(selected)
            guard requestID == request, !Task.isCancelled else { return }
            candidate = full
            coverData = nil
            if includeCover, full.coverURL != nil {
                let data = try await cover(full)
                guard requestID == request, !Task.isCancelled else { return }
                coverData = data
            }
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

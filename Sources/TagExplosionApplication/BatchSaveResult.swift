import Foundation

public struct BatchSaveResult: Identifiable {
    public enum Status {
        case pending, saving, success, failed, skipped
        public var title: String {
            switch self {
            case .pending: String(localized: "Wartend")
            case .saving: String(localized: "Speichern …")
            case .success: String(localized: "Erfolgreich")
            case .failed: String(localized: "Fehlgeschlagen")
            case .skipped: String(localized: "Übersprungen")
            }
        }
    }
    public var url: URL
    public var id: URL { url }
    public var status: Status = .pending
    public var reason = ""
}

/// Erfolgreicher Container-Austausch lässt sich bei einem Sidecar-Fehler
/// nicht zurückrollen. Die Meldung nennt deshalb die bereits geschriebenen Ziele.
public struct PartialSaveError: LocalizedError {
    public init(completed: [String], underlying: Error) {
        self.completed = completed; self.underlying = underlying
    }
    public let completed: [String]
    public let underlying: Error
    public var errorDescription: String? {
        String(localized: "Bereits geschrieben:") + " " + completed.joined(separator: ", ")
            + "\n" + underlying.localizedDescription
    }
}

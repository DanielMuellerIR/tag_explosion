// Umbenennen von Dateien nach einem Muster: erst planen (Vorschau mit
// Konflikten), dann ausführen. Der Plan ist ein reiner Wert und kann in
// App und CLI gleich angezeigt werden.
//
// Warum hier KEINE Papierkorb-Sicherung (`TrashBackup`) läuft: Umbenennen
// ändert kein einziges Byte des Inhalts, nur den Verzeichniseintrag —
// dieselbe `rename(2)`-Operation, mit der `AtomicFileRewrite` eine fertig
// geprüfte Kopie einsetzt. Die Regel „Sicherung vor jeder Mutation" aus
// knowledge/dateisicherheit-schreibwege.md schützt vor kaputten oder
// ungewollt veränderten Inhalten; ein Umbenennen ist verlustfrei durch
// Zurückbenennen umkehrbar. Eine Kopie im Papierkorb wäre dagegen bei großen
// Ordnern reine Plattenlast. Was stattdessen schützt: `moveItem` überschreibt
// nie (ein vorhandenes Ziel ist ein Fehler), und der Plan lehnt jede
// Kollision vorher ab. Der einzige Schreibweg, der Inhalte anfasst — Tags
// aus dem Dateinamen — läuft weiterhin über Sicherung + atomaren Austausch.
import Foundation

public enum FileRenamer {

    /// Eine geplante Umbenennung mit Ergebnis der Prüfung.
    public struct Item: Sendable, Codable, Equatable {
        public enum Status: String, Sendable, Codable {
            /// Neuer Name unterscheidet sich; Umbenennen ist möglich.
            case rename
            /// Alter und neuer Name sind gleich; nichts zu tun.
            case unchanged
            /// Umbenennen wird verweigert; Grund in `reason`.
            case conflict
        }

        public var source: String
        /// Neuer Name (nur Dateiname, gleicher Ordner); leer bei leerem Muster-Ergebnis.
        public var target: String
        public var status: Status
        /// Konfliktgrund in Klartext (englisch, wie alle Core-Fehlertexte).
        public var reason: String?

        public var sourceURL: URL { URL(fileURLWithPath: source) }
        public var targetURL: URL {
            URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(target)
        }
    }

    /// Vorschau: alle Einträge in Eingabereihenfolge.
    public struct Plan: Sendable, Codable, Equatable {
        public var items: [Item]

        public var hasConflicts: Bool { items.contains { $0.status == .conflict } }
        public var renames: [Item] { items.filter { $0.status == .rename } }
        public var conflicts: [Item] { items.filter { $0.status == .conflict } }
    }

    /// Eingabe für die Planung: Datei plus die Feldwerte für das Muster.
    public struct Request: Sendable {
        public var url: URL
        public var fields: [String: String]

        public init(url: URL, fields: [String: String]) {
            self.url = url
            self.fields = fields
        }
    }

    /// Ergebnis einer ausgeführten Umbenennung.
    public struct Outcome: Sendable, Codable, Equatable {
        public var source: String
        public var target: String
        /// nil = umbenannt; sonst der Fehlertext.
        public var error: String?

        public var succeeded: Bool { error == nil }
    }

    /// Prüft, ob der Datenträger eines Ordners Groß-/Kleinschreibung
    /// unterscheidet. Unbekannt gilt als „nicht unterscheidend" — das ist die
    /// strengere Annahme und meldet im Zweifel einen Konflikt mehr.
    public static func isCaseSensitive(directory: URL) -> Bool {
        (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? false
    }

    /// Plant die Umbenennung. Es wird nichts verändert.
    ///
    /// Konflikte, die den Eintrag stoppen:
    /// - Das Muster liefert einen leeren Namen (alle Felder leer).
    /// - Zwei Dateien bekämen denselben Namen (auf Datenträgern ohne
    ///   Unterscheidung der Schreibweise auch „song" gegen „Song").
    /// - Am Zielnamen liegt schon eine andere Datei. Ausnahme: Das Ziel ist
    ///   dieselbe Datei in anderer Schreibweise (song.mp3 → Song.mp3) — das
    ///   ist eine gewöhnliche Umbenennung, kein Konflikt.
    public static func plan(_ requests: [Request], pattern: FilenamePattern) -> Plan {
        var items: [Item] = []
        // Zielnamen je Ordner, schon vergeben durch frühere Einträge des Plans.
        var claimed: [URL: [String: String]] = [:]   // Ordner → Vergleichsname → Quelle
        var caseSensitivity: [URL: Bool] = [:]

        for request in requests {
            let source = request.url
            let directory = source.deletingLastPathComponent()
            let caseSensitive: Bool
            if let known = caseSensitivity[directory] {
                caseSensitive = known
            } else {
                caseSensitive = isCaseSensitive(directory: directory)
                caseSensitivity[directory] = caseSensitive
            }
            let target = pattern.renderFileName(fields: request.fields, extension: source.pathExtension)
            var item = Item(source: source.path, target: target, status: .rename, reason: nil)

            // Vergleichsname: auf Datenträgern ohne Unterscheidung der
            // Schreibweise klein geschrieben, damit "a" und "A" kollidieren.
            func comparable(_ name: String) -> String {
                caseSensitive ? name : name.lowercased()
            }

            if target.isEmpty {
                item.status = .conflict
                item.reason = "Pattern yields an empty name (all fields empty)"
            } else if target == source.lastPathComponent {
                item.status = .unchanged
            } else if let other = claimed[directory]?[comparable(target)] {
                item.status = .conflict
                item.reason = "Same target name as \(other)"
            } else if comparable(target) != comparable(source.lastPathComponent),
                      FileManager.default.fileExists(atPath: item.targetURL.path) {
                // Ein anderer Eintrag des Plans könnte diese Datei gerade
                // freigeben (A→B, B→C). Das wäre reihenfolgeabhängig und wird
                // deshalb bewusst als Konflikt gemeldet, nicht aufgelöst.
                item.status = .conflict
                item.reason = "A file with this name already exists"
            }

            // Auch unveränderte Namen belegen ihren Platz: Ein zweiter Eintrag
            // darf nicht auf den Namen einer Datei umbenannt werden, die
            // unverändert bleibt.
            if item.status != .conflict {
                claimed[directory, default: [:]][comparable(target)] = source.lastPathComponent
            }
            items.append(item)
        }
        return Plan(items: items)
    }

    /// Führt die Umbenennungen des Plans aus — nur die Einträge mit Status
    /// `rename`. Vorbedingung: `plan.hasConflicts == false`; ein Plan mit
    /// Konflikten wird komplett abgelehnt, damit nie ein Teil eines Albums
    /// umbenannt ist und der Rest nicht.
    ///
    /// Jede Datei wird direkt vor ihrem `moveItem` noch einmal geprüft
    /// (Quelle vorhanden, Ziel frei). `moveItem` selbst überschreibt nie.
    /// Schlägt ein Eintrag fehl, laufen die übrigen weiter; das Ergebnis
    /// nennt jeden Eintrag einzeln.
    public static func apply(_ plan: Plan) throws -> [Outcome] {
        guard !plan.hasConflicts else { throw RenameError.planHasConflicts }
        let fm = FileManager.default
        var outcomes: [Outcome] = []
        for item in plan.renames {
            let sourceURL = item.sourceURL
            let targetURL = item.targetURL
            var outcome = Outcome(source: item.source, target: targetURL.path, error: nil)
            do {
                guard fm.fileExists(atPath: sourceURL.path) else {
                    throw RenameError.sourceMissing(path: sourceURL.path)
                }
                let sameFile = FileStamp.current(of: sourceURL).flatMap { sourceStamp in
                    FileStamp.current(of: targetURL).map { sourceStamp.hasSameFileIdentity(as: $0) }
                } ?? false
                if !sameFile, fm.fileExists(atPath: targetURL.path) {
                    throw RenameError.targetExists(path: targetURL.path)
                }
                try fm.moveItem(at: sourceURL, to: targetURL)
            } catch {
                outcome.error = error.localizedDescription
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    public enum RenameError: Error, LocalizedError, Equatable, Sendable {
        case planHasConflicts
        case sourceMissing(path: String)
        case targetExists(path: String)

        public var errorDescription: String? {
            switch self {
            case .planHasConflicts:
                return "The rename plan has conflicts; nothing was renamed"
            case .sourceMissing(let path):
                return "File disappeared before renaming: \(path)"
            case .targetExists(let path):
                return "A file with this name appeared in the meantime: \(path)"
            }
        }
    }
}

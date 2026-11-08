import Foundation
import TagExplosionCore

public enum RuleLabels {
    public static func action(_ action: TagRule.Action) -> String {
        switch action {
        case .set: return String(localized: "Setzen")
        case .copy: return String(localized: "Kopieren")
        case .replace: return String(localized: "Ersetzen")
        case .case: return String(localized: "Schreibweise")
        case .trim: return String(localized: "Trimmen")
        case .remove: return String(localized: "Entfernen")
        case .number: return String(localized: "Nummerieren")
        }
    }

    public static func mode(_ mode: TagRule.CaseMode) -> String {
        switch mode {
        case .upper: return String(localized: "GROSSBUCHSTABEN")
        case .lower: return String(localized: "kleinbuchstaben")
        case .title: return String(localized: "Titel-Schreibweise")
        case .sentence: return String(localized: "Satz-Schreibweise")
        }
    }

    public static func test(_ test: TagRuleCondition.Test) -> String {
        switch test {
        case .empty: return String(localized: "ist leer")
        case .notEmpty: return String(localized: "ist nicht leer")
        case .equals: return String(localized: "ist gleich")
        case .contains: return String(localized: "enthält")
        case .matches: return String(localized: "passt auf Regex")
        }
    }

    public static func kind(_ kind: MediaFormats.Kind?) -> String {
        switch kind {
        case nil: return String(localized: "Alle Medienarten")
        case .audio: return String(localized: "Audio/Video")
        case .image: return String(localized: "Bilder")
        case .ebook: return String(localized: "E-Books")
        case .document: return String(localized: "Dokumente")
        case .sidecar: return String(localized: "NFO")
        case .invoice, .playlist: return kind?.rawValue ?? ""
        }
    }

    public static func template(_ template: TagRuleTemplate) -> String {
        switch template {
        case .titleCase: return String(localized: "Titel-Schreibweise für Titel und Album")
        case .trimWhitespace: return String(localized: "Leerzeichen in allen Feldern trimmen")
        case .albumArtistFromArtist: return String(localized: "Albumkünstler aus Künstler (wenn leer)")
        case .renumberTracks: return String(localized: "Tracks nach Dateiname nummerieren")
        }
    }

    /// Medienarten, die eine Regel filtern kann (Rechnungen und Playlists
    /// haben keine Regel-Felder).
    public static let selectableKinds: [MediaFormats.Kind?] = [nil, .audio, .image, .ebook, .document, .sidecar]

    /// Kurzbeschreibung einer Regel für die Liste, z.B. "Ersetzen · TITLE · „_" → „ "".
    public static func summary(_ rule: TagRule) -> String {
        var parts = [action(rule.action), rule.field]
        switch rule.action {
        case .set: parts.append("= \(rule.value ?? "")")
        case .copy: parts.append("← \(rule.from ?? "")")
        case .replace: parts.append("„\(rule.search ?? "")“ → „\(rule.replacement ?? "")“")
        case .case: parts.append(mode(rule.mode ?? .title))
        case .trim, .remove: break
        case .number: parts.append(rule.total == true ? "n/\(String(localized: "gesamt"))" : "n")
        }
        return parts.joined(separator: " · ")
    }
}

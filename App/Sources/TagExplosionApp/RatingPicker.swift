// Einträge der Bewertungs-Picker (Einzel- und Batch-Editor) als reine
// Abbildung ohne SwiftUI, damit sie headless testbar ist.
//
// Das Modell kennt drei Arten von Werten: kein Rating-Tag (`nil`), die
// Standardwerte −1 („abgelehnt", so schreiben es Adobe Bridge und Lightroom)
// und 0…5, sowie tolerierte Fremdwerte (etwa 7 aus einer fremden Datei oder
// einem Archiv-Restore). Ein Picker, der nur `nil` und 0…5 anbietet, findet
// für −1 oder 7 keinen passenden Eintrag und zeigt dann nichts Ausgewähltes;
// der Wert wurde stillschweigend unsichtbar (Review-Fund 2026-08-22). Darum
// bekommt −1 einen festen Eintrag und jeder andere Bestandswert einen
// sichtbaren Zusatzeintrag, der ihn benennt statt umzudeuten.
import Foundation

/// Ein Eintrag im Bewertungs-Picker des Einzel-Editors.
struct RatingPickerOption: Hashable, Identifiable {
    /// Der Wert, den der Picker bei Auswahl setzt (nil = kein Rating-Tag).
    let value: Int?
    /// Beschriftung im Picker.
    let label: String
    /// Kennung für `ForEach`; ein Optional ist hier eindeutig genug.
    var id: Int? { value }
}

enum RatingPicker {
    /// Adobes dokumentierter Wert für „abgelehnt".
    static let rejected = -1
    /// Werte mit festem Eintrag, in Anzeigereihenfolge.
    static let standardValues: [Int] = [rejected, 0, 1, 2, 3, 4, 5]

    /// Beschriftung eines Werts: „keine" für fehlendes Tag, „abgelehnt" für
    /// −1, Sterne für 1…5, sonst der nackte Wert als Bestandswert.
    static func label(for value: Int?) -> String {
        // `Text(option.label)` erhält hier einen Laufzeit-String und behandelt
        // ihn deshalb wörtlich. Die Lokalisierung muss bereits an dieser
        // Abbildungsgrenze passieren; nur String-Literale direkt in `Text`
        // werden von SwiftUI selbst als Lokalisierungsschlüssel erkannt.
        guard let value else { return String(localized: "keine") }
        switch value {
        case rejected: return String(localized: "abgelehnt")
        case 0: return "0"
        case 1...5: return String(repeating: "★", count: value)
        default: return String(localized: "\(value) (Bestand)")
        }
    }

    /// Einträge des Einzel-Pickers: „keine", die Standardwerte und — nur wenn
    /// der aktuelle Wert außerhalb davon liegt — ein Zusatzeintrag für genau
    /// diesen Bestandswert, damit die Auswahl immer sichtbar ist.
    static func options(current: Int?) -> [RatingPickerOption] {
        var options = [RatingPickerOption(value: nil, label: label(for: nil))]
        options += standardValues.map { RatingPickerOption(value: $0, label: label(for: $0)) }
        if let current, !standardValues.contains(current) {
            options.append(RatingPickerOption(value: current, label: label(for: current)))
        }
        return options
    }
}

/// Die Zustände der Bewertung in einer Mehrfachauswahl. Ein doppeltes
/// Optional („kein Wert" gegen „uneinheitlich") wäre an dieser Stelle nicht
/// mehr lesbar, seit `rating` selbst optional ist.
enum RatingChoice: Hashable {
    /// Die ausgewählten Bilder tragen verschiedene Bewertungen.
    case mixed
    /// Alle tragen gar kein Rating-Tag.
    case none
    /// Alle tragen dieselbe Bewertung (auch −1 oder ein Fremdwert).
    case value(Int)

    /// Gemeinsamer Zustand einer Liste von Bewertungen.
    static func choice(for ratings: [Int?]) -> RatingChoice {
        guard let first = ratings.first else { return .none }
        guard ratings.allSatisfy({ $0 == first }) else { return .mixed }
        guard let value = first else { return .none }
        return .value(value)
    }

    /// Einträge des Batch-Pickers: „— verschieden —", „keine", die
    /// Standardwerte und — nur wenn alle Bilder denselben Fremdwert tragen —
    /// ein Zusatzeintrag für diesen Bestandswert.
    static func options(current: RatingChoice) -> [RatingChoice] {
        var options: [RatingChoice] = [.mixed, .none]
        options += RatingPicker.standardValues.map(RatingChoice.value)
        if case .value(let value) = current, !RatingPicker.standardValues.contains(value) {
            options.append(.value(value))
        }
        return options
    }

    /// Beschriftung im Picker.
    var label: String {
        switch self {
        case .mixed: return String(localized: "— verschieden —")
        case .none: return RatingPicker.label(for: nil)
        case .value(let value): return RatingPicker.label(for: value)
        }
    }

    /// Was die Auswahl dieses Eintrags in jedes Bild schreibt: `.some(nil)`
    /// löscht das Tag, `.some(v)` setzt v, `nil` (bei „verschieden") ändert
    /// nichts.
    var ratingToApply: Int?? {
        switch self {
        case .mixed: return nil
        case .none: return .some(nil)
        case .value(let value): return .some(value)
        }
    }
}

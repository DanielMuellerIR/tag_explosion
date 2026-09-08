// Textentwurf für geprüfte Felder: erst Bestätigen verändert den Editorpuffer.
import Foundation
import TagExplosionCore

struct ValidatedFieldDraft {
    private(set) var text = ""
    private var edited = false

    mutating func synchronize(_ value: String) {
        text = value
        edited = false
    }

    mutating func edit(_ value: String) {
        text = value
        edited = true
    }

    mutating func commit(key: String) throws -> String? {
        // Ein gemischter Batch-Wert erscheint leer. Fokusverlust allein
        // darf deshalb nicht als Löschauftrag an alle Einträge gehen.
        guard edited else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "" : try FixedFields.normalized(key: key, value: trimmed)
        synchronize(normalized)
        return normalized
    }
}

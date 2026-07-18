// Gemeinsame Formular-Bausteine der Editoren (Bild + E-Book; Audio hat für
// Tags seine key-basierte BatchTextField-Form in BatchEditorView).
import SwiftUI

/// Batch-Textfeld über get/set-Closures: zeigt den gemeinsamen Wert der
/// Auswahl oder den Platzhalter „— verschieden —"; Eingabe setzt den Wert in
/// allen Dateien.
struct BatchFieldTextField: View {
    let entries: [FileEntry]
    var placeholderWhenMixed = true
    let get: (FileEntry) -> String
    let set: (FileEntry, String) -> Void

    var body: some View {
        let common = commonValue
        TextField(common == nil && placeholderWhenMixed ? "— verschieden —" : "", text: Binding(
            get: { common ?? "" },
            set: { newValue in
                for entry in entries { set(entry, newValue) }
            }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private var commonValue: String? {
        guard let firstEntry = entries.first else { return nil }
        let first = get(firstEntry)
        return entries.allSatisfy { get($0) == first } ? first : nil
    }
}

/// Rechtsbündiges Beschriftungs-Label der Grid-Formulare.
struct GridFieldLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }
}

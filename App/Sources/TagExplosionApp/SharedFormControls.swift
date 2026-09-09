// Gemeinsame Formular-Bausteine der Editoren (Bild + E-Book; Audio hat für
// Tags seine key-basierte BatchTextField-Form in BatchEditorView).
import SwiftUI
import TagExplosionCore

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

// Die Export-Panels bestätigen das Ziel; Dateisicherung und Austausch laufen
// danach im Hintergrund. Fehler erscheinen im gemeinsamen App-Dialog.
extension AppModel {
    func exportData(_ data: Data, to url: URL) async {
        await exportData(data, to: url) { try FileExport.write($0, to: $1) }
    }

    /// Variante mit austauschbarem Schreiber für headless Tests. Anmeldung,
    /// Hintergrundstart und Fehleranzeige bleiben identisch zur App.
    ///
    /// Der Export wird vor dem Hintergrundstart als laufender Schreibauftrag
    /// angemeldet und erst nach seinem Ende wieder abgemeldet. Sonst meldet
    /// `hasUnfinishedWork` bei sauberen Puffern nichts, und ⌘Q beendet die App
    /// mitten zwischen Sicherung und atomarem Austausch (Review-Fund 2026-09-09).
    func exportData(
        _ data: Data,
        to url: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void
    ) async {
        beginExport()
        defer { endExport() }
        do {
            try await Task.detached(priority: .userInitiated) {
                try write(data, url)
            }.value
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

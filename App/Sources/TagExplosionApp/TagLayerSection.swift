// Abschnitt „Tag-Schichten" des Audio-Editors: zeigt je Schicht (ID3v1,
// ID3v2, APEv2, RIFF INFO, Vorbis), ob sie in der Datei steht, welche
// Version sie hat und wie viele Felder sie trägt. „Entfernen …" fragt nach
// und ruft dann `AppModel.stripLayer`, das die Datei sichert, die Schicht
// entfernt und neu einliest. Nur sichtbar bei Formaten mit Schichtenmodell.
import SwiftUI
import TagExplosionCore

struct TagLayerSection: View {
    @Bindable var entry: FileEntry
    @Environment(AppModel.self) private var model
    /// Schicht, für die gerade die Rückfrage offen ist (nil = keine).
    @State private var pendingKind: TagLayerKind?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Schicht").foregroundStyle(.secondary)
                        Text("Status").foregroundStyle(.secondary)
                        Text("Felder").foregroundStyle(.secondary)
                        Text("")
                    }
                    .font(.caption)
                    ForEach(entry.layers, id: \.kind) { layer in
                        layerRow(layer)
                    }
                }
                if entry.isDirty {
                    Text("Schichten lassen sich erst nach dem Speichern entfernen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } label: {
            Text("Tag-Schichten")
        }
        .confirmationDialog(
            String(localized: "Schicht „\(pendingKind.map(displayName) ?? "")“ entfernen?"),
            isPresented: .init(
                get: { pendingKind != nil },
                set: { if !$0 { pendingKind = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                guard let kind = pendingKind else { return }
                pendingKind = nil
                Task { await model.stripLayer(entry: entry, kind: kind) }
            }
            Button("Abbrechen", role: .cancel) { pendingKind = nil }
        } message: {
            Text("Die Schicht wird aus der Datei entfernt; die anderen Schichten bleiben. Im abgesicherten Modus liegt vorher eine Kopie im Papierkorb.")
        }
    }

    /// Eine Zeile: Name mit Version, vorhanden/fehlt, Feldanzahl, Knopf.
    private func layerRow(_ layer: TagLayer) -> some View {
        GridRow {
            Text(layer.displayName)
                .font(.body.monospacedDigit())
            Text(layer.present ? "vorhanden" : "fehlt")
                .foregroundStyle(layer.present ? .primary : .secondary)
            Text(layer.present ? String(localized: "\(layer.fields.count) Felder") : "–")
                .foregroundStyle(.secondary)
                .help(layer.fields.joined(separator: ", "))
            Button("Entfernen …") { pendingKind = layer.kind }
                .buttonStyle(.borderless)
                .disabled(!layer.present || !layer.strippable || entry.isDirty
                          || entry.isSaving || entry.isReadOnly || model.isDestructiveActionLocked)
        }
    }

    /// Anzeigename der Schicht, wie sie gerade in der Datei steht.
    private func displayName(_ kind: TagLayerKind) -> String {
        entry.layers.first { $0.kind == kind }?.displayName ?? kind.rawValue
    }
}

// Batch-Editor für Bilder: setzt Ersteller/Copyright/Schlagwörter/Bewertung
// für alle ausgewählten Bilder.
import SwiftUI
import TagExplosionCore

struct ImageBatchEditorView: View {
    let entries: [FileEntry]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                fieldsSection
                fileListSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entries.count) Bilder ausgewählt")
                .font(.title3.weight(.semibold))
            Text("Änderungen wirken auf alle ausgewählten Bilder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let dirtyCount = entries.filter(\.isDirty).count
            if dirtyCount > 0 {
                Label("\(dirtyCount) mit ungespeicherten Änderungen", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var fieldsSection: some View {
        GroupBox("Metadaten (für alle setzen)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Schlagwörter")
                    ImageBatchTextField(
                        entries: entries, placeholderWhenMixed: true,
                        get: { $0.imageFields.keywords.joined(separator: ", ") },
                        set: { entry, value in
                            entry.imageFields.keywords = value.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        })
                }
                GridRow {
                    label("Ersteller")
                    ImageBatchTextField(
                        entries: entries, placeholderWhenMixed: true,
                        get: { $0.imageFields.creator },
                        set: { entry, value in entry.imageFields.creator = value })
                }
                GridRow {
                    label("Copyright")
                    ImageBatchTextField(
                        entries: entries, placeholderWhenMixed: true,
                        get: { $0.imageFields.copyright },
                        set: { entry, value in entry.imageFields.copyright = value })
                }
                GridRow {
                    label("Bewertung")
                    Picker("", selection: ratingBinding) {
                        Text("— verschieden —").tag(Int?.none)
                        Text("keine").tag(Int?.some(-1))
                        ForEach(0...5, id: \.self) { stars in
                            Text(stars == 0 ? "0" : String(repeating: "★", count: stars))
                                .tag(Int?.some(stars))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(8)
        }
    }

    private var ratingBinding: Binding<Int?> {
        Binding(
            get: {
                guard let first = entries.first?.imageFields.rating else { return nil }
                return entries.allSatisfy { $0.imageFields.rating == first } ? first : nil
            },
            set: { newValue in
                guard let newValue else { return }
                for entry in entries { entry.imageFields.rating = newValue }
            }
        )
    }

    private var fileListSection: some View {
        GroupBox("Ausgewählte Bilder") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.url.lastPathComponent)
                            .lineLimit(1)
                        Text(entry.imageFields.keywords.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if entry.isDirty {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }
}

/// Batch-Textfeld für Bilder: gemeinsamer Wert oder "— verschieden —".
struct ImageBatchTextField: View {
    let entries: [FileEntry]
    let placeholderWhenMixed: Bool
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

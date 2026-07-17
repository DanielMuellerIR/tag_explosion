// Einzeldatei-Editor: Cover + Kernfelder + weitere Felder + Technik-Panel.
import SwiftUI
import TagExplosionCore

/// Bekannte Schlüssel mit deutschem Label und Anzeige-Reihenfolge.
/// Alles, was hier nicht steht, landet automatisch unter „Weitere Felder".
let primaryFields: [(key: String, label: String)] = [
    ("TITLE", "Titel"),
    ("ARTIST", "Künstler"),
    ("ALBUM", "Album"),
    ("ALBUMARTIST", "Albumkünstler"),
    ("GENRE", "Genre"),
    ("DATE", "Jahr"),
    ("TRACKNUMBER", "Track"),
    ("DISCNUMBER", "CD"),
    ("COMPOSER", "Komponist"),
    ("COMMENT", "Kommentar"),
]

/// Vorschläge fürs Hinzufügen weiterer Felder.
let suggestedExtraKeys: [String] = [
    "LYRICS", "LYRICIST", "CONDUCTOR", "REMIXER", "BPM", "COPYRIGHT",
    "ENCODEDBY", "LANGUAGE", "ISRC", "LABEL", "COMPILATION", "SUBTITLE",
    "ORIGINALDATE", "MOOD", "MEDIA", "SORTALBUM", "SORTARTIST", "SORTTITLE",
]

struct EditorView: View {
    @Bindable var entry: FileEntry
    @State private var tab: Tab = .tags

    enum Tab: Hashable {
        case tags
        case technik
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Tags").tag(Tab.tags)
                Text("Technik").tag(Tab.technik)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .tags:
                TagEditorTab(entry: entry)
            case .technik:
                MediaInfoTab(url: entry.url)
            }
        }
        .background(.background)
    }
}

/// Tab 1: Tag-Bearbeitung.
struct TagEditorTab: View {
    @Bindable var entry: FileEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if entry.isReadOnly {
                    Label("Diese Datei ist schreibgeschützt — Änderungen können nicht gespeichert werden.",
                          systemImage: "lock.fill")
                        .foregroundStyle(.orange)
                }
                if let error = entry.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                primarySection
                extraSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // Kopfbereich: Cover + Datei-Infos
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverWell(entry: entry)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let audio = entry.audio {
                    Text(audioSummary(audio))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    private func audioSummary(_ audio: AudioInfo) -> String {
        let seconds = audio.lengthMilliseconds / 1000
        let duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return "\(duration) · \(audio.bitrateKbps) kbps · \(audio.sampleRateHz) Hz · \(audio.channels == 1 ? "Mono" : "\(audio.channels) Kanäle")"
    }

    // Kernfelder als zweispaltiges Formular
    private var primarySection: some View {
        GroupBox("Tags") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(primaryFields, id: \.key) { field in
                    GridRow {
                        Text(field.label)
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("", text: singleValueBinding(field.key))
                                .textFieldStyle(.roundedBorder)
                            // Gleiche Kopier-Mechanik wie im Batch, nur für diese eine Datei.
                            CopyFromFieldMenu(entries: [entry], targetKey: field.key)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    /// Binding für Einfach-Felder (erster Wert des Schlüssels).
    private func singleValueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { entry.firstValue(key) },
            set: { entry.setSingleValue(key, $0) }
        )
    }

    // Alle übrigen Felder generisch, editierbar, lösch- und ergänzbar
    private var extraSection: some View {
        let primaryKeys = Set(primaryFields.map(\.key))
        let extraIndices = entry.properties.indices.filter {
            !primaryKeys.contains(entry.properties[$0].key)
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if extraIndices.isEmpty {
                    Text("Keine weiteren Felder")
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                ForEach(extraIndices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("FELD", text: Binding(
                            get: { entry.properties[index].key },
                            set: { entry.properties[index].key = $0.uppercased() }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 180)

                        TextField("Wert", text: Binding(
                            get: { entry.properties[index].value },
                            set: { entry.properties[index].value = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            entry.properties.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Feld entfernen")
                    }
                }

                Menu {
                    ForEach(suggestedExtraKeys, id: \.self) { key in
                        Button(key) {
                            entry.properties.append(TagProperty(key: key, value: ""))
                        }
                    }
                    Divider()
                    Button("Eigenes Feld …") {
                        entry.properties.append(TagProperty(key: "", value: ""))
                    }
                } label: {
                    Label("Feld hinzufügen", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(8)
        } label: {
            Text("Weitere Felder")
        }
    }
}

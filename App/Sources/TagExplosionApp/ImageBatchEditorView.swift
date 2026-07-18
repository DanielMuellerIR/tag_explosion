// Batch-Editor für Bilder: setzt Titel/Beschreibung/Ersteller/Copyright/
// Schlagwörter/Bewertung für alle ausgewählten Bilder. Textfelder können ihren
// Wert pro Datei aus einem beliebigen rohen Metadaten-Tag übernehmen
// (EXIF/IPTC/XMP, formatübergreifend) — geschrieben wird MWG-harmonisiert.
import SwiftUI
import TagExplosionCore

struct ImageBatchEditorView: View {
    let entries: [FileEntry]

    /// Roh-Tags aller ausgewählten Bilder als Kopier-Quellen:
    /// Pfad → ("Gruppe:Tag" → Textwert). nil = wird noch geladen.
    @State private var rawTags: [String: [String: String]]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                fieldsSection
                ArchiveButtons(entries: entries)
                fileListSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .task(id: entries.map(\.url)) {
            await loadRawTags()
        }
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
                    GridFieldLabel("Titel")
                    textFieldWithCopy(
                        get: { $0.imageFields.title },
                        set: { entry, value in entry.imageFields.title = value })
                }
                GridRow {
                    GridFieldLabel("Beschreibung")
                    textFieldWithCopy(
                        get: { $0.imageFields.description },
                        set: { entry, value in entry.imageFields.description = value })
                }
                GridRow {
                    GridFieldLabel("Schlagwörter")
                    textFieldWithCopy(
                        get: { $0.imageFields.keywords.joined(separator: ", ") },
                        set: { entry, value in entry.imageFields.keywords = value.splitCommaList() })
                }
                GridRow {
                    GridFieldLabel("Ersteller")
                    textFieldWithCopy(
                        get: { $0.imageFields.creator },
                        set: { entry, value in entry.imageFields.creator = value })
                }
                GridRow {
                    GridFieldLabel("Copyright")
                    textFieldWithCopy(
                        get: { $0.imageFields.copyright },
                        set: { entry, value in entry.imageFields.copyright = value })
                }
                GridRow {
                    GridFieldLabel("Bewertung")
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

    /// Textfeld plus Kopier-Menü. Bewertung und GPS bekommen bewusst kein
    /// Kopier-Menü: dorthin passt kein freier Text (Typkompatibilität).
    private func textFieldWithCopy(
        get: @escaping (FileEntry) -> String,
        set: @escaping (FileEntry, String) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            BatchFieldTextField(entries: entries, get: get, set: set)
            ImageCopyFromTagMenu(entries: entries, rawTags: rawTags, assign: set)
        }
    }

    /// Lädt die Roh-Tags aller Bilder in einem exiftool-Aufruf (im Hintergrund,
    /// exiftool braucht spürbar Zeit pro Prozessstart).
    private func loadRawTags() async {
        rawTags = nil
        let urls = entries.map(\.url)
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? ExifTool.readRawStringTags(urls: urls)) ?? [:]
        }.value
        rawTags = loaded
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

}

/// Menü „Wert aus Tag übernehmen" für Bilder: Quellen sind ALLE rohen
/// Text-Tags der ausgewählten Bilder, nach Gruppe (EXIF, IPTC, XMP-dc …)
/// als Untermenüs sortiert. So lässt sich z.B. ein EXIF-Wert pro Datei in
/// ein IPTC-/XMP-Feld umkopieren; geschrieben wird MWG-harmonisiert.
/// Dateien ohne Quellwert bleiben unverändert.
struct ImageCopyFromTagMenu: View {
    let entries: [FileEntry]
    /// Pfad → ("Gruppe:Tag" → Wert); nil = lädt noch.
    let rawTags: [String: [String: String]]?
    /// Wendet den Quellwert auf das Zielfeld eines Eintrags an.
    let assign: (FileEntry, String) -> Void

    /// Gruppen → Tag-Namen, Vereinigungsmenge über alle ausgewählten Bilder.
    private var groupedKeys: [(group: String, tags: [String])] {
        guard let rawTags else { return [] }
        var byGroup: [String: Set<String>] = [:]
        for tags in rawTags.values {
            for key in tags.keys {
                let parts = key.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                byGroup[String(parts[0]), default: []].insert(String(parts[1]))
            }
        }
        return byGroup.keys.sorted().map { ($0, byGroup[$0]!.sorted()) }
    }

    var body: some View {
        Menu {
            if rawTags == nil {
                Text("Lade Metadaten …")
            } else {
                ForEach(groupedKeys, id: \.group) { entry in
                    Menu(entry.group) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Button(tag) { copy(from: "\(entry.group):\(tag)") }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Wert aus anderem Tag übernehmen (pro Bild, EXIF/IPTC/XMP)")
        .disabled(rawTags != nil && groupedKeys.isEmpty)
    }

    private func copy(from key: String) {
        guard let rawTags else { return }
        for entry in entries {
            guard let value = rawTags[entry.url.path]?[key], !value.isEmpty else { continue }
            assign(entry, value)
        }
    }
}


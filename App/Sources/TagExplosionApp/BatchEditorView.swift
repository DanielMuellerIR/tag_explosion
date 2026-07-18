// Batch-Editor: bearbeitet mehrere ausgewählte Dateien gleichzeitig.
// Felder zeigen den gemeinsamen Wert oder "— verschieden —"; eine Eingabe
// setzt den Wert für ALLE ausgewählten Dateien.
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct BatchEditorView: View {
    let entries: [FileEntry]
    @State private var coverTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                batchFieldsSection
                actionsSection
                ArchiveButtons(entries: entries)
                fileListSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            batchCoverWell
            VStack(alignment: .leading, spacing: 6) {
                Text("\(entries.count) Dateien ausgewählt")
                    .font(.title3.weight(.semibold))
                Text("Änderungen wirken auf alle ausgewählten Dateien.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let dirtyCount = entries.filter(\.isDirty).count
                if dirtyCount > 0 {
                    Label("\(dirtyCount) mit ungespeicherten Änderungen", systemImage: "pencil.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    /// Gemeinsames Cover: zeigt es, wenn alle Dateien dasselbe erste Bild haben.
    private var batchCoverWell: some View {
        let firstData = entries.first?.artworks.first?.data
        let allSame = entries.allSatisfy { $0.artworks.first?.data == firstData }
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
            if allSame, let firstData, let image = NSImage(data: firstData) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: allSame ? "photo.on.rectangle.angled" : "questionmark.square.dashed")
                        .font(.largeTitle)
                    Text(allSame ? "Cover für alle\nhierher ziehen" : "verschiedene Cover\n(Drop ersetzt alle)")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
            if coverTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .frame(width: 140, height: 140)
        .onDrop(of: [.fileURL, .image], isTargeted: $coverTargeted) { providers in
            handleCoverDrop(providers)
        }
        .contextMenu {
            Button("Bild auswählen …") { pickCover() }
            Button("Cover überall entfernen", role: .destructive) {
                for entry in entries { entry.artworks = [] }
            }
        }
    }

    // MARK: Felder

    private var batchFieldsSection: some View {
        GroupBox("Tags (für alle setzen)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(primaryFields.filter { $0.key != "TRACKNUMBER" && $0.key != "TITLE" }, id: \.key) { field in
                    GridRow {
                        Text(field.label)
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            BatchTextField(entries: entries, key: field.key)
                            CopyFromFieldMenu(entries: entries, targetKey: field.key)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: Aktionen

    private var actionsSection: some View {
        GroupBox("Aktionen") {
            HStack(spacing: 12) {
                Button {
                    renumberTracks()
                } label: {
                    Label("Tracks nummerieren (1–\(entries.count))", systemImage: "list.number")
                }
                .help("Setzt TRACKNUMBER in Listenreihenfolge auf n/\(entries.count)")

                Button {
                    for entry in entries {
                        entry.setSingleValue("TITLE", titleFromFilename(entry))
                    }
                } label: {
                    Label("Titel aus Dateinamen", systemImage: "textformat")
                }
                .help("Setzt TITLE aus dem Dateinamen (ohne Nummer-Präfix und Endung)")

                Spacer()
            }
            .padding(8)
        }
    }

    /// TRACKNUMBER in Listenreihenfolge als n/total setzen.
    private func renumberTracks() {
        let total = entries.count
        for (i, entry) in entries.enumerated() {
            entry.setSingleValue("TRACKNUMBER", "\(i + 1)/\(total)")
        }
    }

    /// Dateiname ohne Endung und ohne führende Tracknummer ("07 - " / "07_" / "07. ").
    private func titleFromFilename(_ entry: FileEntry) -> String {
        var name = entry.url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"^\d+\s*[-_.–]\s*"#, options: .regularExpression) {
            name = String(name[range.upperBound...])
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Dateiliste

    private var fileListSection: some View {
        GroupBox("Ausgewählte Dateien") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.firstValue("TRACKNUMBER"))
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                            .gridColumnAlignment(.trailing)
                        Text(entry.url.lastPathComponent)
                            .lineLimit(1)
                        Text(entry.displayTitle)
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

    // MARK: Cover-Handling

    private func setCoverForAll(_ data: Data) {
        guard Artwork.sniffMimeType(from: data) != nil else { return }
        let artwork = Artwork(data: data, pictureType: "Front Cover")
        for entry in entries {
            if entry.artworks.isEmpty {
                entry.artworks = [artwork]
            } else {
                entry.artworks[0] = artwork
            }
        }
    }

    private func handleCoverDrop(_ providers: [NSItemProvider]) -> Bool {
        CoverDrop.load(providers) { setCoverForAll($0) }
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Coverbild für alle ausgewählten Dateien")
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            setCoverForAll(data)
        }
    }
}

/// Menü „Wert aus Feld übernehmen": kopiert pro Datei den Wert eines anderen
/// Tag-Feldes in das Zielfeld — das Werkzeug zum Umkopieren von Tags, z.B.
/// ALBUMARTIST aus ARTIST befüllen. Audio-Tags sind durchweg Text, daher ist
/// jede Quelle typkompatibel. Dateien ohne Quellwert bleiben unverändert.
struct CopyFromFieldMenu: View {
    let entries: [FileEntry]
    let targetKey: String

    /// Alle Tag-Schlüssel, die in mindestens einer der Dateien vorkommen —
    /// außer dem Ziel selbst (inklusive Custom-Keys).
    private var sourceKeys: [String] {
        var keys = Set<String>()
        for entry in entries { keys.formUnion(entry.properties.map(\.key)) }
        keys.remove(targetKey)
        return keys.sorted()
    }

    var body: some View {
        Menu {
            ForEach(sourceKeys, id: \.self) { key in
                Button(key) { copyValues(from: key) }
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Wert aus anderem Feld übernehmen (pro Datei)")
        .disabled(sourceKeys.isEmpty)
    }

    /// Übernimmt pro Datei ALLE Werte des Quell-Feldes (mehrwertige Felder
    /// wie zwei Genres bleiben vollständig erhalten).
    private func copyValues(from sourceKey: String) {
        for entry in entries {
            let values = entry.properties.filter { $0.key == sourceKey }.map(\.value)
            guard !values.isEmpty else { continue }
            entry.properties.removeAll { $0.key == targetKey }
            entry.properties.append(contentsOf: values.map { TagProperty(key: targetKey, value: $0) })
        }
    }
}

/// Textfeld für ein Batch-Feld: zeigt gemeinsamen Wert oder Platzhalter
/// "— verschieden —"; Eingabe setzt den Wert in allen Dateien.
struct BatchTextField: View {
    let entries: [FileEntry]
    let key: String

    var body: some View {
        let common = commonValue
        TextField(common == nil ? "— verschieden —" : "", text: Binding(
            get: { common ?? "" },
            set: { newValue in
                for entry in entries { entry.setSingleValue(key, newValue) }
            }
        ))
        .textFieldStyle(.roundedBorder)
    }

    /// Der gemeinsame Wert aller Dateien oder nil bei Unterschieden.
    private var commonValue: String? {
        guard let first = entries.first?.firstValue(key) else { return nil }
        return entries.allSatisfy { $0.firstValue(key) == first } ? first : nil
    }
}

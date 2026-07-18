// Bild-Editor: Vorschau + Kernfelder (EXIF/IPTC/XMP via exiftool, MWG-harmonisiert)
// + vollständige Metadaten-Ansicht.
import SwiftUI
import TagExplosionCore

struct ImageEditorView: View {
    @Bindable var entry: FileEntry
    @State private var tab: Tab = .fields

    enum Tab: Hashable {
        case fields
        case metadata
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Bild").tag(Tab.fields)
                Text("Alle Metadaten").tag(Tab.metadata)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .fields:
                ImageFieldsTab(entry: entry)
            case .metadata:
                ImageMetadataTab(url: entry.url)
            }
        }
        .background(.background)
    }
}

/// Tab 1: Vorschau + editierbare Kernfelder.
struct ImageFieldsTab: View {
    @Bindable var entry: FileEntry
    @State private var preview: NSImage?
    /// Roh-Tags dieses Bildes als Kopier-Quellen (wie im Batch-Editor):
    /// Pfad → ("Gruppe:Tag" → Textwert). nil = wird noch geladen.
    @State private var rawTags: [String: [String: String]]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = entry.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                fieldsSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: entry.url) {
            let url = entry.url
            preview = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
        .task(id: entry.url) {
            rawTags = nil
            let url = entry.url
            rawTags = await Task.detached(priority: .userInitiated) {
                (try? ExifTool.readRawStringTags(urls: [url])) ?? [:]
            }.value
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView()
                }
            }
            .frame(width: 220, height: 220)

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                // Echte Pixelmaße aus dem Bitmap-Rep — NSImage.size wäre die
                // DPI-skalierte Punktgröße und zeigt bei krummen DPI-Metadaten
                // absurde Werte.
                if let rep = preview?.representations.first, rep.pixelsWide > 0 {
                    Text("\(rep.pixelsWide) × \(rep.pixelsHigh) px")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    private var fieldsSection: some View {
        GroupBox("Metadaten (EXIF/IPTC/XMP harmonisiert)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    GridFieldLabel("Titel")
                    HStack(spacing: 6) {
                        TextField("", text: $entry.imageFields.title)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.title = value }
                    }
                }
                GridRow {
                    GridFieldLabel("Beschreibung")
                    HStack(alignment: .top, spacing: 6) {
                        TextField("", text: $entry.imageFields.description, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.description = value }
                    }
                }
                GridRow {
                    GridFieldLabel("Schlagwörter")
                    HStack(spacing: 6) {
                        TextField("kommagetrennt", text: keywordsBinding)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in
                            entry.imageFields.keywords = value.splitCommaList()
                        }
                    }
                }
                GridRow {
                    GridFieldLabel("Ersteller")
                    HStack(spacing: 6) {
                        TextField("", text: $entry.imageFields.creator)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.creator = value }
                    }
                }
                GridRow {
                    GridFieldLabel("Copyright")
                    HStack(spacing: 6) {
                        TextField("", text: $entry.imageFields.copyright)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.copyright = value }
                    }
                }
                GridRow {
                    GridFieldLabel("Aufnahmedatum")
                    TextField("JJJJ:MM:TT HH:MM:SS", text: $entry.imageFields.dateTimeOriginal)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                }
                GridRow {
                    GridFieldLabel("Bewertung")
                    Picker("", selection: $entry.imageFields.rating) {
                        Text("keine").tag(-1)
                        ForEach(0...5, id: \.self) { stars in
                            Text(stars == 0 ? "0" : String(repeating: "★", count: stars)).tag(stars)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    GridFieldLabel("GPS Breite")
                    TextField("z.B. 50.9375", text: $entry.imageFields.gpsLatitude)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                }
                GridRow {
                    GridFieldLabel("GPS Länge")
                    TextField("z.B. 6.9603", text: $entry.imageFields.gpsLongitude)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                }
            }
            .padding(8)
        }
    }


    /// Kopier-Menü wie im Batch-Editor, nur für dieses eine Bild.
    /// Datum/Bewertung/GPS bekommen bewusst keins (Typkompatibilität).
    private func copyMenu(assign: @escaping (FileEntry, String) -> Void) -> some View {
        ImageCopyFromTagMenu(entries: [entry], rawTags: rawTags, assign: assign)
    }

    /// Schlagwörter als kommagetrennter String.
    private var keywordsBinding: Binding<String> {
        Binding(
            get: { entry.imageFields.keywords.joined(separator: ", ") },
            set: { newValue in
                entry.imageFields.keywords = newValue.splitCommaList()
            }
        )
    }
}

/// Tab 2: alle Metadaten-Gruppen (read-only, filterbar).
struct ImageMetadataTab: View {
    let url: URL

    @State private var groups: [MetadataGroup]?
    @State private var errorText: String?
    @State private var filter = ""

    var body: some View {
        Group {
            if let groups {
                groupsView(groups)
            } else if let errorText {
                ContentUnavailableView(
                    "exiftool nicht verfügbar",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else {
                ProgressView("Analysiere …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            groups = nil
            errorText = nil
            let target = url
            do {
                groups = try await Task.detached(priority: .userInitiated) {
                    try ExifTool.readAllGroups(url: target)
                }.value
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func groupsView(_ groups: [MetadataGroup]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filtern …", text: $filter)
                    .textFieldStyle(.plain)
                Spacer()
            }
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        let fields = filteredFields(group)
                        if !fields.isEmpty {
                            GroupBox(group.name) {
                                Grid(alignment: .leadingFirstTextBaseline,
                                     horizontalSpacing: 16, verticalSpacing: 4) {
                                    ForEach(fields, id: \.self) { field in
                                        GridRow {
                                            Text(field.key)
                                                .foregroundStyle(.secondary)
                                                .gridColumnAlignment(.trailing)
                                            Text(field.value)
                                                .font(.body.monospaced())
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(6)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func filteredFields(_ group: MetadataGroup) -> [TagProperty] {
        guard !filter.isEmpty else { return group.fields }
        return group.fields.filter {
            $0.key.localizedCaseInsensitiveContains(filter)
                || $0.value.localizedCaseInsensitiveContains(filter)
        }
    }
}

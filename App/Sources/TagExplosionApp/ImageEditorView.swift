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
                ImageMetadataTab(url: entry.url, sidecarURL: entry.imageReading.sidecarURL)
            }
        }
        .background(.background)
    }
}

/// Tab 1: Vorschau + editierbare Kernfelder.
struct ImageFieldsTab: View {
    @Bindable var entry: FileEntry
    @State private var preview: NSImage?
    /// true, sobald der Ladeversuch der Vorschau vorbei ist — für Formate
    /// ohne Pixel (.xmp) oder ohne Decoder zeigt der Kopf dann ein
    /// Platzhaltersymbol statt eines endlosen Ladekreises.
    @State private var previewLoaded = false
    /// Einstellung „Sidecar statt Original" — steuert den Hinweistext.
    @AppStorage(AppModel.imageSidecarDefaultsKey) private var sidecarPreferred = false
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
                ImageSidecarNotice(entry: entry, sidecarPreferred: sidecarPreferred)
                fieldsSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: entry.url) {
            let url = entry.url
            // NSImage ist nicht Sendable und darf den Hintergrund-Task deshalb
            // nicht verlassen. Gelesen werden die Bytes, das Bild entsteht
            // hier auf dem MainActor.
            previewLoaded = false
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            preview = data.flatMap { NSImage(data: $0) }
            previewLoaded = true
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
                } else if previewLoaded {
                    // Kein Bild darstellbar: eine .xmp hat keine Pixel, und
                    // für manche RAW-/Exoten fehlt macOS der Decoder.
                    Image(systemName: MediaFormats.isXMPSidecar(entry.url) ? "doc.text" : "photo")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
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
                FilenamePatternMenu(entries: [entry])
                    .padding(.top, 4)
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
                        sourceBadge(.title)
                    }
                }
                GridRow {
                    GridFieldLabel("Beschreibung")
                    HStack(alignment: .top, spacing: 6) {
                        TextField("", text: $entry.imageFields.description, axis: .vertical)
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.description = value }
                        sourceBadge(.description)
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
                        sourceBadge(.keywords)
                    }
                }
                GridRow {
                    GridFieldLabel("Ersteller")
                    HStack(spacing: 6) {
                        TextField("", text: $entry.imageFields.creator)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.creator = value }
                        sourceBadge(.creator)
                    }
                }
                GridRow {
                    GridFieldLabel("Copyright")
                    HStack(spacing: 6) {
                        TextField("", text: $entry.imageFields.copyright)
                            .textFieldStyle(.roundedBorder)
                        copyMenu { entry, value in entry.imageFields.copyright = value }
                        sourceBadge(.copyright)
                    }
                }
                GridRow {
                    GridFieldLabel("Aufnahmedatum")
                    HStack(spacing: 6) {
                        TextField("JJJJ:MM:TT HH:MM:SS", text: $entry.imageFields.dateTimeOriginal)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                        sourceBadge(.dateTimeOriginal)
                    }
                }
                GridRow {
                    GridFieldLabel("Bewertung")
                    // Einträge samt „abgelehnt" (−1) und ggf. einem sichtbaren
                    // Bestandswert außerhalb des Standards: siehe RatingPicker.
                    HStack(spacing: 6) {
                        Picker("", selection: $entry.imageFields.rating) {
                            ForEach(RatingPicker.options(current: entry.imageFields.rating)) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        sourceBadge(.rating)
                    }
                }
                GridRow {
                    GridFieldLabel("GPS Breite")
                    HStack(spacing: 6) {
                        TextField("z.B. 50.9375", text: $entry.imageFields.gpsLatitude)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                        sourceBadge(.gps)
                    }
                }
                GridRow {
                    GridFieldLabel("GPS Länge")
                    HStack(spacing: 6) {
                        TextField("z.B. 6.9603", text: $entry.imageFields.gpsLongitude)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                        sourceBadge(.gps)
                    }
                }
            }
            .padding(8)
        }
    }

    /// Kleine Marke „Sidecar" hinter einem Feld, dessen gelesener Wert aus
    /// der XMP-Sidecar stammt (und nicht aus der Bilddatei). Ohne Sidecar
    /// bleibt die Zeile unverändert.
    @ViewBuilder
    private func sourceBadge(_ key: ImageCoreFieldKey) -> some View {
        if entry.imageReading.sidecarFields.contains(key) {
            Text("Sidecar")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .help("Dieser Wert stammt aus der XMP-Sidecar-Datei, nicht aus der Bilddatei.")
                .accessibilityIdentifier("image.source.sidecar.\(key.rawValue)")
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

/// Hinweiskasten über den Feldern: Woher kommen die Werte, wohin geht das
/// Speichern? Erscheint nur, wenn eine Sidecar im Spiel ist — vorhanden,
/// erzwungen (RAW, nicht schreibbares Format) oder per Einstellung gewählt.
struct ImageSidecarNotice: View {
    let entry: FileEntry
    let sidecarPreferred: Bool

    /// Schreibziel nach denselben Regeln wie beim Speichern (Core).
    private var destination: ImageWriteDestination {
        ExifTool.writeDestination(for: entry.url, preferSidecar: sidecarPreferred)
    }

    var body: some View {
        let destination = destination
        if destination.isSidecar || entry.imageReading.sidecarURL != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let sidecarURL = entry.imageReading.sidecarURL {
                    Label("Werte aus Sidecar: \(sidecarURL.lastPathComponent)", systemImage: "doc.badge.gearshape")
                        .accessibilityIdentifier("image.sidecar.present")
                }
                if destination.isSidecar {
                    Label(Self.destinationText(destination), systemImage: "arrow.right.doc.on.clipboard")
                        .accessibilityIdentifier("image.sidecar.target")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// Text zum Schreibziel samt Grund — der Nutzer soll wissen, WARUM sein
    /// Bild unverändert bleibt.
    static func destinationText(_ destination: ImageWriteDestination) -> String {
        let name = destination.url.lastPathComponent
        switch destination.reason {
        case .original:
            return String(localized: "Änderungen werden in die Bilddatei geschrieben.")
        case .rawFormat:
            return String(localized: "Kamera-RAW: Änderungen gehen in die Sidecar \(name), das RAW bleibt unverändert.")
        case .formatNotWritable:
            return String(localized: "exiftool kann dieses Format nicht beschreiben: Änderungen gehen in die Sidecar \(name).")
        case .existingSidecar:
            return String(localized: "Änderungen gehen in die vorhandene Sidecar \(name), weil ihre Werte beim Lesen Vorrang haben.")
        case .setting:
            return String(localized: "Einstellung: Änderungen gehen in die Sidecar \(name) statt in die Bilddatei.")
        }
    }
}

/// Tab 2: alle Metadaten-Gruppen (read-only, filterbar). Liegt eine Sidecar
/// neben dem Bild, folgen deren Gruppen mit dem Präfix „Sidecar ·".
struct ImageMetadataTab: View {
    let url: URL
    var sidecarURL: URL? = nil

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
            let sidecar = sidecarURL
            do {
                groups = try await Task.detached(priority: .userInitiated) {
                    var all = try ExifTool.readAllGroups(url: target)
                    if let sidecar {
                        for group in try ExifTool.readAllGroups(url: sidecar) {
                            all.append(MetadataGroup(name: "Sidecar · \(group.name)", fields: group.fields))
                        }
                    }
                    return all
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

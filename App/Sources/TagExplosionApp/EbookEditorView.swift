// E-Book-Editor: Cover + Kernfelder (Umfang wie Calibres Metadaten-Dialog).
// EPUB nativ, PDF via exiftool (ohne Serie/Cover), mobi/azw3/fb2 via Calibre.
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct EbookEditorView: View {
    @Bindable var entry: FileEntry
    /// Aktuelles Cover aus der Datei (nil = keins oder lädt noch).
    @State private var currentCover: NSImage?
    @State private var coverLoaded = false

    private var supportsCover: Bool { EbookTool.supportsCover(url: entry.url) }
    private var supportsSeries: Bool { EbookTool.supportsSeries(url: entry.url) }

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
        .background(.background)
        .task(id: entry.url) {
            await loadCover()
        }
        // Nach dem Speichern (Puffer leer) das Cover neu aus der Datei lesen
        .onChange(of: entry.ebookCoverReplacement) { _, newValue in
            if newValue == nil {
                Task { await loadCover() }
            }
        }
    }

    // MARK: - Kopf: Cover + Dateiinfo

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if supportsCover {
                coverWell
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !supportsCover {
                    Text("PDF: Serie und Cover werden von diesem Format nicht unterstützt.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                if supportsCover {
                    Button("Cover auswählen …") { presentCoverPanel() }
                        .padding(.top, 6)
                    if entry.ebookCoverReplacement != nil {
                        Label("Neues Cover wird beim Speichern übernommen", systemImage: "photo.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
    }

    /// Cover-Anzeige, nimmt auch Bilddateien per Drag & Drop an.
    private var coverWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
            if let image = displayedCover {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if coverLoaded {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32))
                    Text("Kein Cover")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .frame(width: 180, height: 240)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleCoverDrop(providers)
        }
        .help("Bilddatei hierher ziehen, um das Cover zu ersetzen")
    }

    /// Ersatz-Cover (ungespeichert) vor dem Datei-Cover anzeigen.
    private var displayedCover: NSImage? {
        if let data = entry.ebookCoverReplacement { return NSImage(data: data) }
        return currentCover
    }

    private func loadCover() async {
        coverLoaded = false
        currentCover = nil
        let url = entry.url
        let artwork = await Task.detached(priority: .userInitiated) {
            try? EbookTool.readCover(url: url)
        }.value
        currentCover = artwork.flatMap { NSImage(data: $0.data) }
        coverLoaded = true
    }

    private func presentCoverPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = String(localized: "Neues Cover auswählen (JPEG oder PNG)")
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            entry.ebookCoverReplacement = data
        }
    }

    private func handleCoverDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url,
                  ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                entry.ebookCoverReplacement = data
            }
        }
        return true
    }

    // MARK: - Felder

    private var fieldsSection: some View {
        GroupBox("Buch-Metadaten") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Titel")
                    TextField("", text: $entry.ebookFields.title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("Autor(en)")
                    TextField("kommagetrennt", text: listBinding(\.authors))
                        .textFieldStyle(.roundedBorder)
                }
                if supportsSeries {
                    GridRow {
                        label("Serie")
                        TextField("", text: $entry.ebookFields.series)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("Serienindex")
                        TextField("z.B. 2 oder 2.5", text: $entry.ebookFields.seriesIndex)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 140)
                    }
                }
                GridRow {
                    label("Beschreibung")
                    TextField("", text: $entry.ebookFields.description, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("ISBN")
                    TextField("", text: $entry.ebookFields.isbn)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 240)
                }
                GridRow {
                    label("Verlag")
                    TextField("", text: $entry.ebookFields.publisher)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("Sprache")
                    TextField("z.B. de", text: $entry.ebookFields.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }
                GridRow {
                    label("Datum")
                    TextField("JJJJ-MM-TT", text: $entry.ebookFields.date)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 180)
                }
                GridRow {
                    label("Schlagwörter")
                    TextField("kommagetrennt", text: listBinding(\.subjects))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(8)
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .gridColumnAlignment(.trailing)
            .foregroundStyle(.secondary)
    }

    /// Mehrwertiges Feld als kommagetrennter String.
    private func listBinding(_ keyPath: WritableKeyPath<EbookCoreFields, [String]>) -> Binding<String> {
        Binding(
            get: { entry.ebookFields[keyPath: keyPath].joined(separator: ", ") },
            set: { newValue in
                entry.ebookFields[keyPath: keyPath] = newValue.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

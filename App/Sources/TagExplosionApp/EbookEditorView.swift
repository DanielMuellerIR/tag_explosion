// E-Book-Editor: Cover + Kernfelder (Umfang wie Calibres Metadaten-Dialog).
// EPUB nativ, PDF via exiftool (ohne Serie/Cover), mobi/azw3/fb2 via Calibre.
// PDFs mit eingebetteter E-Rechnung (ZUGFeRD/Factur-X) bekommen zusätzlich
// einen Rechnungs-Tab.
import EInvoiceCore
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct EbookEditorView: View {
    @Bindable var entry: FileEntry
    @State private var tab: Tab = .metadata
    /// Eingebettete E-Rechnung dieses PDFs (nil = keine oder Prüfung läuft).
    /// Das Dokument wird genau EINMAL im Hintergrund gelesen und danach für
    /// Tab-Sichtbarkeit UND Tab-Inhalt verwendet — Extraktion und Parsen pro
    /// angezeigtem PDF nicht doppelt.
    @State private var invoiceDocument: EInvoiceDocument?

    enum Tab: Hashable {
        case metadata
        case invoice
    }

    private var supportsCover: Bool { EbookTool.supportsCover(url: entry.url) }
    private var supportsSeries: Bool { EbookTool.supportsSeries(url: entry.url) }

    var body: some View {
        VStack(spacing: 0) {
            if invoiceDocument != nil {
                Picker("", selection: $tab) {
                    Text("Metadaten").tag(Tab.metadata)
                    Text("E-Rechnung").tag(Tab.invoice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .padding(.vertical, 8)

                Divider()
            }

            switch tab {
            case .metadata:
                metadataTab
            case .invoice:
                if let invoiceDocument {
                    InvoiceContentView(document: invoiceDocument)
                }
            }
        }
        // Die Prüfung liest das PDF im Hintergrund; nur PDFs kommen infrage.
        .task(id: entry.url) {
            invoiceDocument = nil
            tab = .metadata
            guard entry.url.pathExtension.lowercased() == "pdf" else { return }
            let target = entry.url
            invoiceDocument = await Task.detached(priority: .utility) {
                try? EInvoiceReader.read(url: target)
            }.value
        }
    }

    private var metadataTab: some View {
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
                if supportsCover {
                    Button("Cover auswählen …") { presentCoverPanel() }
                        .padding(.top, 6)
                    if entry.ebookCoverReplacement != nil {
                        Label("Neues Cover wird beim Speichern übernommen", systemImage: "photo.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("PDF: Serie und Cover werden von diesem Format nicht unterstützt.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
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
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32))
                    Text("Kein Cover")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 180, height: 240)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleCoverDrop(providers)
        }
        .help("Bilddatei hierher ziehen, um das Cover zu ersetzen")
    }

    /// Ersatz-Cover (ungespeichert) vor dem Datei-Cover anzeigen. Beide Stände
    /// liegen im Modell — das Cover wurde beim Öffnen gemeinsam mit den Feldern
    /// gelesen, der Editor braucht dafür keinen eigenen Dateizugriff.
    private var displayedCover: NSImage? {
        if let data = entry.ebookCoverReplacement { return NSImage(data: data) }
        return entry.ebookOriginalCover.flatMap { NSImage(data: $0) }
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
            entry.setEbookCover(data)
        }
    }

    private func handleCoverDrop(_ providers: [NSItemProvider]) -> Bool {
        // E-Book-Cover bleiben auf JPEG/PNG beschränkt (EPUB-Reader-Support).
        CoverDrop.load(providers, acceptedMimeTypes: ["image/jpeg", "image/png"]) {
            entry.setEbookCover($0)
        }
    }

    // MARK: - Felder

    private var fieldsSection: some View {
        GroupBox("Buch-Metadaten") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    GridFieldLabel("Titel")
                    TextField("", text: $entry.ebookFields.title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GridFieldLabel("Autor(en)")
                    TextField("kommagetrennt", text: listBinding(\.authors))
                        .textFieldStyle(.roundedBorder)
                }
                if supportsSeries {
                    GridRow {
                        GridFieldLabel("Serie")
                        TextField("", text: $entry.ebookFields.series)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        GridFieldLabel("Serienindex")
                        TextField("z.B. 2 oder 2.5", text: $entry.ebookFields.seriesIndex)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 140)
                    }
                }
                GridRow {
                    GridFieldLabel("Beschreibung")
                    TextField("", text: $entry.ebookFields.description, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GridFieldLabel("ISBN")
                    TextField("", text: $entry.ebookFields.isbn)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 240)
                }
                GridRow {
                    GridFieldLabel("Verlag")
                    TextField("", text: $entry.ebookFields.publisher)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    GridFieldLabel("Sprache")
                    TextField("z.B. de", text: $entry.ebookFields.language)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }
                GridRow {
                    GridFieldLabel("Datum")
                    TextField("JJJJ-MM-TT", text: $entry.ebookFields.date)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .frame(maxWidth: 180)
                }
                GridRow {
                    GridFieldLabel("Schlagwörter")
                    TextField("kommagetrennt", text: listBinding(\.subjects))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(8)
        }
    }


    /// Mehrwertiges Feld als kommagetrennter String.
    private func listBinding(_ keyPath: WritableKeyPath<EbookCoreFields, [String]>) -> Binding<String> {
        Binding(
            get: { entry.ebookFields[keyPath: keyPath].joined(separator: ", ") },
            set: { newValue in
                entry.ebookFields[keyPath: keyPath] = newValue.splitCommaList()
            }
        )
    }
}

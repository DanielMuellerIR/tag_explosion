// Dokument-Editor: Office (docx/xlsx/pptx), OpenDocument (odt/ods/odp),
// Comic-Archive (cbz) und Markdown-Frontmatter. Gezeigt werden nur die Felder,
// die das Format speichern kann (`DocumentTool.supportedFields`); dazu die
// formatspezifischen Zusatzfelder (feste Schlüssel, bei Markdown beliebige)
// und eine reine Anzeige-Liste (Anwendung, Seiten, Wörter …).
import SwiftUI
import TagExplosionCore

struct DocumentEditorView: View {
    @Bindable var entry: FileEntry
    /// Neues Zusatzfeld (nur Markdown: beliebige Schlüssel).
    @State private var newCustomKey = ""
    @State private var newCustomValue = ""

    private var supported: Set<DocumentField> { DocumentTool.supportedFields(url: entry.url) }
    /// nil = beliebige Schlüssel (Markdown).
    private var fixedCustomKeys: [String]? { DocumentTool.customKeys(url: entry.url) }
    private var supportsCover: Bool { DocumentTool.supportsCover(url: entry.url) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = entry.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                fieldsSection
                customSection
                if !entry.documentInfo.isEmpty {
                    infoSection
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: - Kopf: Cover (nur cbz) + Dateiinfo

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
                FilenamePatternMenu(entries: [entry])
                    .padding(.top, 4)
                // Papierkorb-Sicherungen dieser Datei ansehen und zurückholen.
                VersionHistoryButton(entry: entry)
                if supportsCover {
                    Text("Cover = erste Seite des Archivs (nur Anzeige).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    /// Erste Seite als Cover — reine Anzeige, kein Drop-Ziel.
    private var coverWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
            if let data = entry.documentCover, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 32))
                    Text("Keine Seite")
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 180, height: 240)
    }

    // MARK: - Kernfelder

    private var fieldsSection: some View {
        GroupBox("Dokument-Metadaten") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if supported.contains(.title) {
                    GridRow {
                        GridFieldLabel("Titel")
                        TextField("", text: $entry.documentFields.title)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.authors) {
                    GridRow {
                        GridFieldLabel("Autor(en)")
                        TextField("kommagetrennt", text: listBinding(\.authors))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.subject) {
                    GridRow {
                        GridFieldLabel("Thema")
                        TextField("", text: $entry.documentFields.subject)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.description) {
                    GridRow {
                        GridFieldLabel("Beschreibung")
                        TextField("", text: $entry.documentFields.description, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.keywords) {
                    GridRow {
                        GridFieldLabel("Schlagwörter")
                        TextField("kommagetrennt", text: listBinding(\.keywords))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.publisher) {
                    GridRow {
                        GridFieldLabel("Verlag")
                        TextField("", text: $entry.documentFields.publisher)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.language) {
                    GridRow {
                        GridFieldLabel("Sprache")
                        TextField("z.B. de", text: $entry.documentFields.language)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                    }
                }
                if supported.contains(.category) {
                    GridRow {
                        GridFieldLabel("Kategorie")
                        TextField("", text: $entry.documentFields.category)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.created) {
                    GridRow {
                        GridFieldLabel("Erstellt")
                        TextField("JJJJ-MM-TT", text: $entry.documentFields.created)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 260)
                    }
                }
                if supported.contains(.modified) {
                    GridRow {
                        GridFieldLabel("Geändert")
                        TextField("JJJJ-MM-TT", text: $entry.documentFields.modified)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 260)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Zusatzfelder

    /// Feste Schlüssel (Office, ODF, cbz) erscheinen immer, auch leer; bei
    /// Markdown stehen die vorhandenen Schlüssel plus eine Zeile zum Anlegen.
    private var customSection: some View {
        GroupBox("Weitere Felder") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if let keys = fixedCustomKeys {
                    ForEach(keys, id: \.self) { key in
                        GridRow {
                            Text(key)
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            TextField("", text: customBinding(key))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    ForEach(entry.documentFields.custom, id: \.key) { field in
                        GridRow {
                            Text(field.key)
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                            TextField("", text: customBinding(field.key))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        TextField("Schlüssel", text: $newCustomKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                        HStack {
                            TextField("Wert", text: $newCustomValue)
                                .textFieldStyle(.roundedBorder)
                            Button("Hinzufügen") { addCustomField() }
                                .disabled(newCustomKey.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newCustomValue.isEmpty)
                        }
                    }
                    Text("Unbekannte Frontmatter-Schlüssel bleiben erhalten; verschachtelte Einträge werden nur durchgereicht.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(2)
                }
            }
            .padding(8)
        }
    }

    private func addCustomField() {
        let key = newCustomKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        entry.documentFields.setCustom(key, newCustomValue)
        newCustomKey = ""
        newCustomValue = ""
    }

    // MARK: - Anzeige

    private var infoSection: some View {
        GroupBox("Dokument-Info (nur Anzeige)") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(entry.documentInfo.enumerated()), id: \.offset) { _, item in
                    GridRow {
                        Text(item.label)
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Bindings

    /// Mehrwertiges Feld als kommagetrennter String.
    private func listBinding(_ keyPath: WritableKeyPath<DocumentCoreFields, [String]>) -> Binding<String> {
        Binding(
            get: { entry.documentFields[keyPath: keyPath].joined(separator: ", ") },
            set: { newValue in
                entry.documentFields[keyPath: keyPath] = newValue.splitCommaList()
            }
        )
    }

    /// Zusatzfeld; ein leerer Wert entfernt es (wie in CLI und Archiv).
    private func customBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { entry.documentFields.customValue(for: key) },
            set: { entry.documentFields.setCustom(key, $0) }
        )
    }
}

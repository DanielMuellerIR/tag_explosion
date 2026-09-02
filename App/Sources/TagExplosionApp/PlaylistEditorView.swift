// Playlist-/Cue-Sheet-Editor: Kopffelder (Titel, Interpret, bei Cue-Sheets
// Datum und Genre — nur die, die das Format speichern kann), darunter die
// Tabelle der Einträge mit aufgelöstem Pfad, Existenzprüfung und Spielzeit.
// Bearbeitbar sind Titel und Interpret je Eintrag; Reihenfolge und Pfade
// nicht. Doppelklick auf einen Eintrag öffnet die Datei in einem neuen
// Fenster über den gewohnten Öffnen-Weg.
import SwiftUI
import TagExplosionCore

struct PlaylistEditorView: View {
    @Bindable var entry: FileEntry
    @Environment(\.openWindow) private var openWindow
    @State private var selectedRows: Set<Int> = []

    private var supported: Set<PlaylistField> { PlaylistTool.supportedFields(url: entry.url) }
    private var contents: PlaylistContents { entry.playlistContents }

    /// Eine Tabellenzeile: Position in der Eintragsliste plus Anzeigeinhalt.
    private struct Row: Identifiable {
        let id: Int
        let entry: PlaylistEntry
    }

    private var rows: [Row] {
        contents.entries.enumerated().map { Row(id: $0.offset, entry: $0.element) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = entry.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                fieldsSection
                entriesSection
                if !contents.info.isEmpty {
                    infoSection
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: - Kopf

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: contents.format == .cue ? "opticaldisc" : "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.url.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                summaryLine
                if contents.usedEncodingFallback {
                    Text("Datei ist kein UTF-8 (Latin1/MacRoman-Fallback); beim Speichern wird sie als UTF-8 geschrieben.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }

    /// Format, Anzahl, Gesamtdauer und fehlende Dateien in einer Zeile.
    private var summaryLine: some View {
        var parts: [String] = [contents.format.rawValue.uppercased()]
        parts.append(String(localized: "\(contents.entries.count) Einträge"))
        var duration = PlaylistTool.formatDuration(contents.totalDurationMilliseconds)
        if contents.unknownDurationCount > 0 {
            duration += " " + String(localized: "(+\(contents.unknownDurationCount) unbekannt)")
        }
        parts.append(String(localized: "Gesamt \(duration)"))
        if contents.missingCount > 0 {
            parts.append(String(localized: "\(contents.missingCount) fehlend"))
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(contents.missingCount > 0 ? .orange : .secondary)
    }

    // MARK: - Kopffelder

    private var fieldsSection: some View {
        GroupBox(contents.format == .cue ? "Album" : "Playlist") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if supported.contains(.title) {
                    GridRow {
                        GridFieldLabel("Titel")
                        TextField("", text: $entry.playlistFields.title)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.performer) {
                    GridRow {
                        GridFieldLabel("Interpret")
                        TextField("", text: $entry.playlistFields.performer)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if supported.contains(.date) {
                    GridRow {
                        GridFieldLabel("Datum")
                        TextField("JJJJ", text: $entry.playlistFields.date)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: 200)
                    }
                }
                if supported.contains(.genre) {
                    GridRow {
                        GridFieldLabel("Genre")
                        TextField("", text: $entry.playlistFields.genre)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                if !supported.contains(.title) {
                    Text("Dieses Format kennt keinen Titel für die ganze Liste.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(2)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Einträge

    private var entriesSection: some View {
        GroupBox("Einträge") {
            VStack(alignment: .leading, spacing: 6) {
                entriesTable
                    .frame(minHeight: 160, idealHeight: tableHeight, maxHeight: 480)
                    .contextMenu(forSelectionType: Int.self) { ids in
                        Button("In neuem Fenster öffnen") { openInNewWindow(ids) }
                            .disabled(openableURLs(ids).isEmpty)
                        Button("Im Finder zeigen") {
                            NSWorkspace.shared.activateFileViewerSelecting(openableURLs(ids))
                        }
                        .disabled(openableURLs(ids).isEmpty)
                    } primaryAction: { ids in
                        openInNewWindow(ids)
                    }
                Text("Doppelklick öffnet die Datei in einem neuen Fenster. Reihenfolge und Pfade werden hier nicht geändert.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
        }
    }

    private var tableHeight: CGFloat { CGFloat(rows.count) * 28 + 40 }

    /// Die Spalten stehen in eigenen Funktionen: als ein einziger Ausdruck
    /// war die Tabelle dem Typprüfer zu groß.
    private var entriesTable: some View {
        Table(rows, selection: $selectedRows) {
            TableColumn("Nr.") { row in numberCell(row) }.width(40)
            TableColumn("") { row in statusIcon(row.entry) }.width(24)
            TableColumn("Titel") { row in titleCell(row) }
            TableColumn("Interpret") { row in performerCell(row) }
            TableColumn("Dauer") { row in durationCell(row) }.width(70)
            TableColumn("Datei") { row in pathCell(row) }
        }
    }

    private func numberCell(_ row: Row) -> some View {
        Text("\(row.entry.number)")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func titleCell(_ row: Row) -> some View {
        if supported.contains(.entryTitle) {
            TextField("", text: entryBinding(row.id, \.title))
                .textFieldStyle(.plain)
        } else {
            Text(row.entry.title)
        }
    }

    @ViewBuilder
    private func performerCell(_ row: Row) -> some View {
        if supported.contains(.entryPerformer) {
            TextField("", text: entryBinding(row.id, \.performer))
                .textFieldStyle(.plain)
        } else {
            Text(row.entry.performer)
                .foregroundStyle(.secondary)
        }
    }

    private func durationCell(_ row: Row) -> some View {
        Text(row.entry.durationMilliseconds.map(PlaylistTool.formatDuration) ?? "–")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func pathCell(_ row: Row) -> some View {
        let text = row.entry.resolvedPath ?? row.entry.location
        let isFine = row.entry.exists || row.entry.isRemote
        return Text(text)
            .font(.caption)
            .foregroundStyle(isFine ? Color.secondary : Color.orange)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }

    @ViewBuilder
    private func statusIcon(_ entry: PlaylistEntry) -> some View {
        if entry.isRemote {
            Image(systemName: "network").foregroundStyle(.secondary).help("Netzadresse")
        } else if entry.resolvedPath == nil {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help("Kein Dateipfad")
        } else if entry.exists {
            Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Datei vorhanden")
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Datei fehlt")
        }
    }

    /// Vorhandene lokale Dateien der gewählten Zeilen (in Listenreihenfolge).
    private func openableURLs(_ ids: Set<Int>) -> [URL] {
        ids.sorted().compactMap { id -> URL? in
            guard id < contents.entries.count, let path = contents.entries[id].resolvedPath,
                  contents.entries[id].exists else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// Neues Fenster mit den Dateien: erst vormerken, dann das Fenster
    /// anfordern — das Modell des neuen Fensters holt sie beim Anmelden ab.
    private func openInNewWindow(_ ids: Set<Int>) {
        let urls = openableURLs(ids)
        guard !urls.isEmpty else { return }
        WindowSessions.shared.queueForNextWindow(urls: urls)
        openWindow(id: TagExplosionApp.windowGroupID)
    }

    // MARK: - Anzeige

    private var infoSection: some View {
        GroupBox("Weitere Angaben (nur Anzeige)") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(contents.info.enumerated()), id: \.offset) { _, item in
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

    /// Titel/Interpret eines Eintrags im Bearbeitungspuffer. Der Index wird
    /// geprüft, weil die Tabelle nach einem Neuladen kurz alte Zeilen zeigen kann.
    private func entryBinding(_ index: Int,
                              _ keyPath: WritableKeyPath<PlaylistEntryFields, String>) -> Binding<String> {
        Binding(
            get: {
                guard index < entry.playlistFields.entries.count else { return "" }
                return entry.playlistFields.entries[index][keyPath: keyPath]
            },
            set: { newValue in
                guard index < entry.playlistFields.entries.count else { return }
                entry.playlistFields.entries[index][keyPath: keyPath] = newValue
            }
        )
    }
}

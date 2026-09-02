// Dialoge „Umbenennen aus Tags …" und „Tags aus Dateiname …": Musterfeld
// mit Vorgaben und Verlauf, Vorschautabelle, Ausführen-Knopf. Die Logik
// (Muster, Plan, Konflikte) liegt im Core; hier steht nur die Anzeige.
import SwiftUI
import TagExplosionCore

/// Menü mit den beiden Dateinamen-Aktionen. Steht im Batch-Editor bei den
/// Aktionen und im Einzel-Editor neben dem Dateinamen.
struct FilenamePatternMenu: View {
    let entries: [FileEntry]
    @State private var showRename = false
    @State private var showParse = false

    var body: some View {
        Menu {
            Button("Umbenennen aus Tags …") { showRename = true }
            Button("Tags aus Dateiname …") { showParse = true }
        } label: {
            Label("Dateiname", systemImage: "character.cursor.ibeam")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!entries.contains(where: \.supportsFilenamePatterns))
        .help("Dateinamen aus Tags bilden oder Tags aus Dateinamen lesen")
        .sheet(isPresented: $showRename) { RenameFromTagsSheet(entries: entries) }
        .sheet(isPresented: $showParse) { TagsFromFilenameSheet(entries: entries) }
    }
}

/// Eingabefeld für ein Muster mit Menü für Verlauf und Vorgaben.
private struct PatternInputField: View {
    @Binding var text: String
    let history: [String]

    static let placeholderHelp: String =
        String(localized: "Platzhalter:")
        + " %{artist} %{title} %{album} %{albumartist} %{track} %{disc} %{year} %{genre} %{composer} "
        + String(localized: "oder jeder Tag-Schlüssel")
        + " (%{isrc}); %{track:2} "
        + String(localized: "füllt mit Nullen auf.")
        + " " + String(localized: "Bilder:")
        + " %{title} %{creator} %{description} %{keywords} %{date}. "
        + String(localized: "E-Books:")
        + " %{title} %{author} %{series} %{seriesindex} %{publisher} %{date}."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Prompt bewusst verbatim: Ein "%{" darf nie durch die
                // Format-Auswertung lokalisierter Texte laufen.
                TextField("Muster", text: $text,
                          prompt: Text(verbatim: "%{track:2} - %{artist} - %{title}"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Menu {
                    if !history.isEmpty {
                        Section("Zuletzt benutzt") {
                            ForEach(history, id: \.self) { pattern in
                                Button(pattern) { text = pattern }
                            }
                        }
                    }
                    Section("Vorgaben") {
                        ForEach(PatternHistory.presets, id: \.self) { pattern in
                            Button(pattern) { text = pattern }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Zuletzt benutzte Muster und Vorgaben")
            }
            // Zusammengesetzt aus lokalisierten Wörtern und wörtlichen
            // Platzhalterlisten (siehe Prompt oben).
            Text(Self.placeholderHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Fehlertext eines ungültigen Musters (Core-Text ist englisch; hier die
/// deutschen Gegenstücke).
private func patternErrorText(_ error: Error) -> String {
    guard let parseError = error as? FilenamePattern.ParseError else {
        return error.localizedDescription
    }
    switch parseError {
    case .unbalancedBraces:
        return String(localized: "Ein Platzhalter ist nicht geschlossen (schließende Klammer fehlt).")
    case .emptyPlaceholder:
        return String(localized: "Ein Platzhalter ist leer.")
    case .invalidWidth:
        return String(localized: "Die Breite hinter dem Doppelpunkt muss eine Zahl von 1 bis 9 sein.")
    case .containsPathSeparator:
        return String(localized: "Das Muster darf keinen Ordner enthalten (kein /).")
    case .noPlaceholder:
        return String(localized: "Das Muster braucht mindestens einen Platzhalter, zum Beispiel für den Titel.")
    }
}

// MARK: - Umbenennen aus Tags

struct RenameFromTagsSheet: View {
    let entries: [FileEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var patternText = PatternHistory.initialPattern(.rename)
    @State private var history = PatternHistory.load(.rename)

    /// Eine Zeile der Vorschau; die Quelle ist je Eintrag eindeutig.
    private struct Row: Identifiable {
        let item: FileRenamer.Item
        var id: String { item.source }
        var oldName: String { URL(fileURLWithPath: item.source).lastPathComponent }
    }

    private var compiled: Result<FilenamePattern, Error> {
        Result { try FilenamePattern(patternText) }
    }

    private var plan: FileRenamer.Plan? {
        guard case .success(let pattern) = compiled else { return nil }
        return model.renamePlan(for: entries, pattern: pattern)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Umbenennen aus Tags")
                .font(.title3.weight(.semibold))
            Text("Die Dateien bleiben in ihrem Ordner; nur der Name ändert sich, die Endung bleibt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PatternInputField(text: $patternText, history: history)
            if case .failure(let error) = compiled {
                Label(patternErrorText(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            previewTable
            HStack {
                if let plan {
                    Text(summary(plan))
                        .font(.caption)
                        .foregroundStyle(plan.hasConflicts ? Color.red : Color.secondary)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Umbenennen") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || plan?.hasConflicts == true || plan?.renames.isEmpty == true)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 420)
    }

    private var previewTable: some View {
        let rows = (plan?.items ?? []).map(Row.init)
        return Table(rows) {
            TableColumn("Bisher") { row in
                Text(row.oldName).lineLimit(1)
            }
            TableColumn("Neu") { row in
                Text(row.item.target.isEmpty ? "—" : row.item.target)
                    .lineLimit(1)
                    .foregroundStyle(row.item.status == .unchanged ? .secondary : .primary)
            }
            TableColumn("Status") { row in
                switch row.item.status {
                case .rename:
                    Label("Umbenennen", systemImage: "arrow.right")
                case .unchanged:
                    Label("Unverändert", systemImage: "equal")
                        .foregroundStyle(.secondary)
                case .conflict:
                    Label(row.item.reason ?? String(localized: "Konflikt"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .width(min: 160)
        }
        .frame(minHeight: 200)
    }

    private func summary(_ plan: FileRenamer.Plan) -> String {
        let unchanged = plan.items.count - plan.renames.count - plan.conflicts.count
        return String(localized:
            "\(plan.renames.count) umbenennen · \(unchanged) unverändert · \(plan.conflicts.count) Konflikte")
    }

    private func rename() {
        guard case .success(let pattern) = compiled else { return }
        PatternHistory.remember(patternText, .rename)
        let targets = entries
        dismiss()
        Task { await model.renameFiles(targets, pattern: pattern) }
    }
}

// MARK: - Tags aus Dateiname

struct TagsFromFilenameSheet: View {
    let entries: [FileEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var patternText = PatternHistory.initialPattern(.parse)
    @State private var history = PatternHistory.load(.parse)

    private struct Row: Identifiable {
        let url: URL
        /// nil = Muster passt nicht.
        let fields: [String: String]?
        var id: URL { url }
        var assignments: String {
            guard let fields else { return "" }
            return fields.sorted { $0.key < $1.key }
                .map { "\($0.key) = \($0.value)" }
                .joined(separator: " · ")
        }
    }

    private var compiled: Result<FilenamePattern, Error> {
        Result { try FilenamePattern(patternText) }
    }

    private var rows: [Row] {
        guard case .success(let pattern) = compiled else { return [] }
        return entries.filter(\.supportsFilenamePatterns).map { entry in
            Row(url: entry.url,
                fields: pattern.extract(fromStem: entry.url.deletingPathExtension().lastPathComponent))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags aus Dateiname")
                .font(.title3.weight(.semibold))
            Text("Die gelesenen Werte landen in den Feldern; geschrieben wird erst beim Speichern.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PatternInputField(text: $patternText, history: history)
            if case .failure(let error) = compiled {
                Label(patternErrorText(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Table(rows) {
                TableColumn("Datei") { row in
                    Text(row.url.lastPathComponent).lineLimit(1)
                }
                TableColumn("Gelesene Felder") { row in
                    if row.fields == nil {
                        Label("Muster passt nicht", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text(row.assignments).lineLimit(1)
                    }
                }
                .width(min: 300)
            }
            .frame(minHeight: 200)
            HStack {
                let matched = rows.filter { $0.fields != nil }.count
                Text("\(matched) von \(rows.count) Dateien passen")
                    .font(.caption)
                    .foregroundStyle(matched == rows.count ? Color.secondary : Color.red)
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matched == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 420)
    }

    private func apply() {
        guard case .success(let pattern) = compiled else { return }
        PatternHistory.remember(patternText, .parse)
        model.applyFileNamePattern(pattern, to: entries)
        dismiss()
    }
}

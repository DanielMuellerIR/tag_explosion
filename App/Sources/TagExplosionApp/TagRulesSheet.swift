// Dialog „Regeln anwenden …": Regelliste (hinzufügen, entfernen, umsortieren),
// Formular je Regel, Laden/Speichern als JSON, Vorlagen und zuletzt benutzte
// Dateien, Vorschautabelle (Datei, Feld, alt → neu) und der Anwenden-Knopf.
// Die Regel-Logik liegt im Core (`TagRules.swift`); hier steht nur die Anzeige.
import AppKit
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

/// Knopf im Batch-Editor, der den Regel-Dialog öffnet.
struct TagRulesButton: View {
    let entries: [FileEntry]
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Regeln anwenden …", systemImage: "list.bullet.rectangle")
        }
        .disabled(!entries.contains(where: \.supportsFilenamePatterns))
        .help("Regeln wie Titel-Schreibweise, Trimmen oder Feld-Kopien auf alle ausgewählten Dateien anwenden")
        .sheet(isPresented: $showSheet) { TagRulesSheet(entries: entries) }
    }
}

/// Eine Regel in der Liste braucht eine stabile Identität — der Core-Typ
/// hat bewusst keine (zwei gleiche Regeln sind dort gleich).
struct EditableRule: Identifiable, Equatable {
    let id: UUID
    var rule: TagRule

    init(_ rule: TagRule) {
        self.id = UUID()
        self.rule = rule
    }
}

// MARK: - Anzeigenamen

/// Deutsche/englische Namen der Aktionen, Schreibweisen, Bedingungen und
/// Medienarten (die JSON-Schreibweise bleibt englisch).
enum RuleLabels {
    static func action(_ action: TagRule.Action) -> String {
        switch action {
        case .set: return String(localized: "Setzen")
        case .copy: return String(localized: "Kopieren")
        case .replace: return String(localized: "Ersetzen")
        case .case: return String(localized: "Schreibweise")
        case .trim: return String(localized: "Trimmen")
        case .remove: return String(localized: "Entfernen")
        case .number: return String(localized: "Nummerieren")
        }
    }

    static func mode(_ mode: TagRule.CaseMode) -> String {
        switch mode {
        case .upper: return String(localized: "GROSSBUCHSTABEN")
        case .lower: return String(localized: "kleinbuchstaben")
        case .title: return String(localized: "Titel-Schreibweise")
        case .sentence: return String(localized: "Satz-Schreibweise")
        }
    }

    static func test(_ test: TagRuleCondition.Test) -> String {
        switch test {
        case .empty: return String(localized: "ist leer")
        case .notEmpty: return String(localized: "ist nicht leer")
        case .equals: return String(localized: "ist gleich")
        case .contains: return String(localized: "enthält")
        case .matches: return String(localized: "passt auf Regex")
        }
    }

    static func kind(_ kind: MediaFormats.Kind?) -> String {
        switch kind {
        case nil: return String(localized: "Alle Medienarten")
        case .audio: return String(localized: "Audio/Video")
        case .image: return String(localized: "Bilder")
        case .ebook: return String(localized: "E-Books")
        case .document: return String(localized: "Dokumente")
        case .sidecar: return String(localized: "NFO")
        case .invoice, .playlist: return kind?.rawValue ?? ""
        }
    }

    static func template(_ template: TagRuleTemplate) -> String {
        switch template {
        case .titleCase: return String(localized: "Titel-Schreibweise für Titel und Album")
        case .trimWhitespace: return String(localized: "Leerzeichen in allen Feldern trimmen")
        case .albumArtistFromArtist: return String(localized: "Albumkünstler aus Künstler (wenn leer)")
        case .renumberTracks: return String(localized: "Tracks nach Dateiname nummerieren")
        }
    }

    /// Medienarten, die eine Regel filtern kann (Rechnungen und Playlists
    /// haben keine Regel-Felder).
    static let selectableKinds: [MediaFormats.Kind?] = [nil, .audio, .image, .ebook, .document, .sidecar]

    /// Kurzbeschreibung einer Regel für die Liste, z.B. "Ersetzen · TITLE · „_" → „ "".
    static func summary(_ rule: TagRule) -> String {
        var parts = [action(rule.action), rule.field]
        switch rule.action {
        case .set: parts.append("= \(rule.value ?? "")")
        case .copy: parts.append("← \(rule.from ?? "")")
        case .replace: parts.append("„\(rule.search ?? "")“ → „\(rule.replacement ?? "")“")
        case .case: parts.append(mode(rule.mode ?? .title))
        case .trim, .remove: break
        case .number: parts.append(rule.total == true ? "n/\(String(localized: "gesamt"))" : "n")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dialog

struct TagRulesSheet: View {
    let entries: [FileEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [EditableRule] = TagRuleTemplate.titleCase.document.rules.map(EditableRule.init)
    @State private var selectedRuleID: UUID?
    @State private var history = RuleFileHistory.load()
    @State private var fileError: String?
    @State private var isApplying = false

    /// Eine Zeile der Vorschau: ein Feld einer Datei.
    private struct PreviewRow: Identifiable {
        let file: String
        let change: TagFieldChange
        var id: String { "\(file)\u{0}\(change.field)" }
    }

    /// Das Dokument, wie es Engine und Speichern sehen (Feldnamen kanonisch).
    private var document: TagRuleDocument {
        TagRuleDocument(rules: rules.map(\.rule).map(Self.normalized))
    }

    private var planResult: Result<[TagRulePlan], Error> {
        Result { try model.rulePlan(for: entries, document: document) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Regeln anwenden")
                .font(.title3.weight(.semibold))
            Text("Die Regeln laufen der Reihe nach über alle ausgewählten Dateien. Anwenden schreibt die Änderungen über den gewohnten Speichern-Weg (Sicherung, atomarer Austausch).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            fileToolbar
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 12) {
                rulesList
                    .frame(width: 300)
                ruleForm
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 220)
            previewTable
            footer
        }
        .padding(20)
        .frame(minWidth: 860, idealWidth: 940, minHeight: 640)
        .onAppear {
            if selectedRuleID == nil { selectedRuleID = rules.first?.id }
        }
    }

    // MARK: Datei-Leiste

    private var fileToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TagRuleTemplate.allCases, id: \.self) { template in
                    Button(RuleLabels.template(template)) { load(template.document) }
                }
            } label: {
                Label("Vorlagen", systemImage: "doc.on.clipboard")
            }
            .fixedSize()
            Menu {
                if history.isEmpty {
                    Text("Noch keine Regeldatei benutzt")
                }
                ForEach(history, id: \.self) { url in
                    Button(url.lastPathComponent) { load(from: url) }
                }
            } label: {
                Label("Zuletzt benutzt", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize()
            Button("Laden …") { openRulesFile() }
            Button("Speichern …") { saveRulesFile() }
                .disabled(rules.isEmpty)
            Spacer()
        }
    }

    // MARK: Regelliste

    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selectedRuleID) {
                ForEach(rules) { item in
                    Text(RuleLabels.summary(item.rule))
                        .lineLimit(1)
                        .tag(item.id)
                }
                .onMove { source, destination in
                    rules.move(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(minHeight: 160)
            HStack(spacing: 6) {
                Menu {
                    ForEach(TagRule.Action.allCases, id: \.self) { action in
                        Button(RuleLabels.action(action)) { add(action) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Regel hinzufügen")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selectedRuleID == nil)
                    .help("Regel entfernen")
                Button { moveSelected(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(selectedIndex.map { $0 == 0 } ?? true)
                    .help("Regel nach oben")
                Button { moveSelected(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(selectedIndex.map { $0 == rules.count - 1 } ?? true)
                    .help("Regel nach unten")
                Spacer()
            }
        }
    }

    private var selectedIndex: Int? {
        rules.firstIndex { $0.id == selectedRuleID }
    }

    private func add(_ action: TagRule.Action) {
        let rule: TagRule
        switch action {
        case .set: rule = TagRule(action: .set, field: "ALBUMARTIST", value: "%{artist}")
        case .copy: rule = TagRule(action: .copy, field: "ALBUMARTIST", from: "ARTIST", onlyIfEmpty: true)
        case .replace: rule = TagRule(action: .replace, field: "TITLE", search: "_", replacement: " ")
        case .case: rule = TagRule(action: .case, field: "TITLE", mode: .title)
        case .trim: rule = TagRule(action: .trim, field: "*")
        case .remove: rule = TagRule(action: .remove, field: "COMMENT")
        case .number: rule = TagRule(action: .number, sortBy: "filename", total: true)
        }
        let item = EditableRule(rule)
        if let index = selectedIndex {
            rules.insert(item, at: index + 1)
        } else {
            rules.append(item)
        }
        selectedRuleID = item.id
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        rules.remove(at: index)
        selectedRuleID = rules.indices.contains(index) ? rules[index].id : rules.last?.id
    }

    private func moveSelected(by offset: Int) {
        guard let index = selectedIndex, rules.indices.contains(index + offset) else { return }
        rules.swapAt(index, index + offset)
    }

    // MARK: Formular

    @ViewBuilder
    private var ruleForm: some View {
        if let index = selectedIndex {
            RuleForm(rule: $rules[index].rule)
        } else {
            Text("Regel auswählen oder mit + hinzufügen.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Vorschau

    private var previewTable: some View {
        let rows: [PreviewRow]
        var planError: String?
        switch planResult {
        case .success(let plans):
            rows = plans.flatMap { plan in
                plan.changes.map { PreviewRow(file: plan.url.lastPathComponent, change: $0) }
            }
        case .failure(let error):
            rows = []
            planError = error.localizedDescription
        }
        return VStack(alignment: .leading, spacing: 6) {
            if let planError {
                Label(planError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Table(rows) {
                TableColumn("Datei") { row in
                    Text(row.file).lineLimit(1)
                }
                TableColumn("Feld") { row in
                    Text(row.change.field).font(.body.monospaced())
                }
                .width(min: 90, ideal: 120)
                TableColumn("Bisher") { row in
                    Text(row.change.oldDisplay.isEmpty ? "—" : row.change.oldDisplay)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                TableColumn("Neu") { row in
                    Text(row.change.newDisplay.isEmpty ? String(localized: "(entfernen)") : row.change.newDisplay)
                        .lineLimit(1)
                }
            }
            .frame(minHeight: 160)
        }
    }

    private var footer: some View {
        HStack {
            if case .success(let plans) = planResult {
                let changes = plans.reduce(0) { $0 + $1.changes.count }
                Text("\(changes) Änderungen in \(plans.count) Dateien")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abbrechen") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Anwenden") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || !hasChanges)
        }
    }

    private var hasChanges: Bool {
        if case .success(let plans) = planResult { return !plans.isEmpty }
        return false
    }

    private func apply() {
        let targets = entries
        let document = document
        isApplying = true
        Task {
            await model.applyRules(document, to: targets)
            isApplying = false
            dismiss()
        }
    }

    // MARK: Laden/Speichern

    /// Feldnamen kanonisieren (der Nutzer tippt "title", die Engine will
    /// "TITLE") — über den Core-Initialisierer, der das für alle Felder tut.
    private static func normalized(_ rule: TagRule) -> TagRule {
        TagRule(action: rule.action, field: rule.field, value: rule.value, from: rule.from,
                onlyIfEmpty: rule.onlyIfEmpty, search: rule.search, replacement: rule.replacement,
                regex: rule.regex, ignoreCase: rule.ignoreCase, mode: rule.mode,
                smallWords: rule.smallWords, sortBy: rule.sortBy, start: rule.start,
                total: rule.total, width: rule.width, kinds: rule.kinds,
                when: rule.when.map { TagRuleCondition(field: $0.field, test: $0.test,
                                                       value: $0.value, ignoreCase: $0.ignoreCase) },
                comment: rule.comment)
    }

    private func load(_ document: TagRuleDocument) {
        rules = document.rules.map(EditableRule.init)
        selectedRuleID = rules.first?.id
        fileError = nil
    }

    private func load(from url: URL) {
        do {
            load(try TagRulesIO.load(url))
            RuleFileHistory.remember(url)
            history = RuleFileHistory.load()
        } catch {
            fileError = String(localized: "Regeldatei konnte nicht geladen werden:") + " " + error.localizedDescription
        }
    }

    private func openRulesFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Regeldatei (JSON) öffnen")
        if panel.runModal() == .OK, let url = panel.url {
            load(from: url)
        }
    }

    private func saveRulesFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tag-rules.json"
        panel.message = String(localized: "Regeln als JSON sichern")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TagRulesIO.save(document, to: url)
            RuleFileHistory.remember(url)
            history = RuleFileHistory.load()
            fileError = nil
        } catch {
            fileError = String(localized: "Regeldatei konnte nicht gesichert werden:") + " " + error.localizedDescription
        }
    }
}

// MARK: - Formular je Regel

/// Eingabefelder einer Regel: Aktion, Feld, aktionsabhängige Parameter,
/// Medienart-Filter und Feld-Bedingung.
private struct RuleForm: View {
    @Binding var rule: TagRule

    var body: some View {
        Form {
            Picker("Aktion", selection: $rule.action) {
                ForEach(TagRule.Action.allCases, id: \.self) { action in
                    Text(RuleLabels.action(action)).tag(action)
                }
            }
            TextField("Feld", text: $rule.field, prompt: Text(verbatim: "TITLE"))
                .font(.body.monospaced())
            if [.replace, .case, .trim].contains(rule.action) {
                Text("* steht für alle Felder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            actionFields
            Section("Nur wenn") {
                Picker("Medienart", selection: kindBinding) {
                    ForEach(RuleLabels.selectableKinds, id: \.self) { kind in
                        Text(RuleLabels.kind(kind)).tag(kind)
                    }
                }
                Toggle("Feld-Bedingung", isOn: conditionEnabled)
                if rule.when != nil {
                    TextField("Feld", text: conditionField, prompt: Text(verbatim: "ALBUMARTIST"))
                        .font(.body.monospaced())
                    Picker("Prüfung", selection: conditionTest) {
                        ForEach(TagRuleCondition.Test.allCases, id: \.self) { test in
                            Text(RuleLabels.test(test)).tag(test)
                        }
                    }
                    if rule.when?.test != .empty, rule.when?.test != .notEmpty {
                        TextField("Wert", text: conditionValue)
                        Toggle("Groß-/Kleinschreibung ignorieren", isOn: conditionIgnoreCase)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var actionFields: some View {
        switch rule.action {
        case .set:
            TextField("Wert", text: optional(\.value), prompt: Text(verbatim: "%{artist}"))
            // Platzhalterliste wörtlich anhängen: "%{" darf nie durch die
            // Format-Auswertung lokalisierter Texte laufen.
            Text(verbatim: String(localized: "Platzhalter wie in Dateinamen-Mustern, zum Beispiel")
                 + " %{artist}, %{track:2}, %{year}.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .copy:
            TextField("Aus Feld", text: optional(\.from), prompt: Text(verbatim: "ARTIST"))
                .font(.body.monospaced())
            Toggle("Nur wenn das Ziel leer ist", isOn: optional(\.onlyIfEmpty))
        case .replace:
            TextField("Suchen", text: optional(\.search))
            TextField("Ersetzen durch", text: optional(\.replacement))
            Toggle("Regulärer Ausdruck (Gruppen als $1, $2 …)", isOn: optional(\.regex))
            Toggle("Groß-/Kleinschreibung ignorieren", isOn: optional(\.ignoreCase))
        case .case:
            Picker("Schreibweise", selection: modeBinding) {
                ForEach(TagRule.CaseMode.allCases, id: \.self) { mode in
                    Text(RuleLabels.mode(mode)).tag(mode)
                }
            }
            if rule.mode == .title {
                TextField("Kleine Wörter", text: smallWordsBinding,
                          prompt: Text(verbatim: TagRule.defaultSmallWords.prefix(6).joined(separator: ", ") + " …"))
                Text("Kommagetrennt; leer = Standardliste (Englisch und Deutsch).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .trim:
            Text("Entfernt Leerzeichen und Steuerzeichen am Rand und zieht Mehrfach-Leerzeichen zusammen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .remove:
            Text("Löscht das Feld in jeder passenden Datei.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .number:
            TextField("Sortieren nach", text: optional(\.sortBy), prompt: Text(verbatim: "filename"))
                .font(.body.monospaced())
            Text("„filename“ (natürlich sortiert) oder ein Feld wie TRACKNUMBER.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Erste Nummer", value: $rule.start, format: .number, prompt: Text(verbatim: "1"))
            Toggle("Gesamtzahl anhängen (3/12)", isOn: optional(\.total))
            TextField("Mindestbreite (führende Nullen)", value: $rule.width, format: .number,
                      prompt: Text(verbatim: "—"))
        }
    }

    // Bindings für optionale Parameter: leer/aus heißt „nicht gesetzt".

    private func optional(_ keyPath: WritableKeyPath<TagRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: keyPath] ?? "" },
                set: { rule[keyPath: keyPath] = $0 })
    }

    private func optional(_ keyPath: WritableKeyPath<TagRule, Bool?>) -> Binding<Bool> {
        Binding(get: { rule[keyPath: keyPath] ?? false },
                set: { rule[keyPath: keyPath] = $0 ? true : nil })
    }

    private var modeBinding: Binding<TagRule.CaseMode> {
        Binding(get: { rule.mode ?? .title }, set: { rule.mode = $0 })
    }

    private var smallWordsBinding: Binding<String> {
        Binding(get: { rule.smallWords?.joined(separator: ", ") ?? "" },
                set: { text in
                    let words = text.splitCommaList()
                    rule.smallWords = words.isEmpty ? nil : words
                })
    }

    private var kindBinding: Binding<MediaFormats.Kind?> {
        Binding(get: { rule.kinds?.first }, set: { rule.kinds = $0.map { [$0] } })
    }

    private var conditionEnabled: Binding<Bool> {
        Binding(get: { rule.when != nil },
                set: { on in
                    rule.when = on ? (rule.when ?? TagRuleCondition(field: rule.field == "*" ? "TITLE" : rule.field,
                                                                     test: .empty)) : nil
                })
    }

    private var conditionField: Binding<String> {
        Binding(get: { rule.when?.field ?? "" }, set: { rule.when?.field = $0 })
    }

    private var conditionTest: Binding<TagRuleCondition.Test> {
        Binding(get: { rule.when?.test ?? .empty }, set: { rule.when?.test = $0 })
    }

    private var conditionValue: Binding<String> {
        Binding(get: { rule.when?.value ?? "" }, set: { rule.when?.value = $0 })
    }

    private var conditionIgnoreCase: Binding<Bool> {
        Binding(get: { rule.when?.ignoreCase ?? false }, set: { rule.when?.ignoreCase = $0 ? true : nil })
    }
}

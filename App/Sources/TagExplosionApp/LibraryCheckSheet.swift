// Konsistenzprüfung in der App: Knopf „Prüfen …" (Batch-Editor: die Auswahl,
// Werkzeugleiste: alle geladenen Dateien) und das Ergebnis-Sheet mit den
// Befunden je Album/Ordner. Die Regeln liegen im Core (`LibraryCheck`);
// hier stehen nur Anzeige, Übersetzung der Regelnamen und die Sprungfunktion
// zur Datei. Es wird nichts automatisch korrigiert.
import AppKit
import SwiftUI
import TagExplosionCore

extension FileEntry {
    /// Prüf-Item aus dem Bearbeitungspuffer: Geprüft wird, was gerade in den
    /// Feldern steht (wie die Vorschau beim Umbenennen). nil = Medienart wird
    /// nicht geprüft (Rechnung, Playlist, NFO/Untertitel) oder Container ohne
    /// Tag-Leser.
    var libraryCheckItem: LibraryCheck.Item? {
        switch kind {
        case .audio:
            guard !isReadOnly else { return nil }
            let embeds = MediaFormats.supportsEmbeddedArtwork(url)
            return LibraryCheck.Item(
                url: url, kind: .audio, properties: properties,
                covers: embeds ? artworks.map(LibraryCheck.CoverSummary.init) : nil,
                durationMilliseconds: audio?.lengthMilliseconds,
                title: firstValue("TITLE"), patternFields: patternFields)
        case .image:
            return LibraryCheck.Item(url: url, image: imageFields)
        case .ebook:
            // Ein im Puffer gewähltes neues Cover zählt schon als vorhanden.
            let hasCover = (ebookCoverReplacement ?? ebookOriginalCover) != nil
            return LibraryCheck.Item(url: url, ebook: ebookFields,
                                     hasCover: EbookTool.supportsCover(url: url) ? hasCover : nil)
        case .document:
            return LibraryCheck.Item(url: url, document: documentFields)
        case .invoice, .playlist, .sidecar:
            return nil
        }
    }
}

extension AppModel {
    /// Führt die Prüfung über die Puffer der Einträge aus (rein lesend).
    func libraryCheckReport(for targets: [FileEntry], pattern: FilenamePattern?) -> LibraryCheck.Report {
        LibraryCheck.run(targets.compactMap(\.libraryCheckItem), pattern: pattern)
    }
}

/// Knopf „Prüfen …" für den Batch-Editor: öffnet das Sheet für die Auswahl.
struct LibraryCheckButton: View {
    @Environment(AppModel.self) private var model
    let entries: [FileEntry]

    var body: some View {
        Button {
            model.libraryCheckTargets = entries
        } label: {
            Label("Prüfen …", systemImage: "checkmark.seal")
        }
        .disabled(entries.isEmpty)
        .help("Die ausgewählten Dateien auf Konsistenz prüfen (Cover, Album-Interpret, Tracknummern, leere Felder, Dubletten)")
    }
}

/// Deutsche Regelnamen (die Core-Texte sind englisch, CLI-Konvention).
func libraryCheckRuleTitle(_ code: LibraryCheck.RuleCode) -> String {
    switch code {
    case .unreadable: return String(localized: "Datei konnte nicht gelesen werden")
    case .missingCover: return String(localized: "Kein Cover")
    case .coverInconsistent: return String(localized: "Cover-Größe oder -Format im Album uneinheitlich")
    case .albumArtistInconsistent: return String(localized: "Album-Interpret im Album uneinheitlich")
    case .albumArtistMissing: return String(localized: "Mehrere Interpreten, aber kein Album-Interpret")
    case .trackMissing: return String(localized: "Tracknummer fehlt oder ist keine Zahl")
    case .trackInvalid: return String(localized: "Tracknummer ist 0 oder negativ")
    case .trackGap: return String(localized: "Lücken in der Tracknummerierung")
    case .trackDuplicate: return String(localized: "Tracknummer mehrfach vergeben")
    case .trackTotalMissing: return String(localized: "Gesamtzahl der Tracks fehlt")
    case .trackExceedsTotal: return String(localized: "Tracknummer größer als die Gesamtzahl")
    case .discGap: return String(localized: "Lücken in der Disc-Nummerierung")
    case .discInvalid: return String(localized: "Disc-Nummer ist 0 oder negativ")
    case .discTotalMissing: return String(localized: "Gesamtzahl der Discs fehlt")
    case .discExceedsTotal: return String(localized: "Disc-Nummer größer als die Gesamtzahl")
    case .dateInconsistent: return String(localized: "Jahr/Datum im Album uneinheitlich")
    case .genreInconsistent: return String(localized: "Genre im Album uneinheitlich")
    case .albumTitleInconsistent: return String(localized: "Album-Titel unterschiedlich geschrieben")
    case .emptyTitle: return String(localized: "Titel ist leer")
    case .emptyArtist: return String(localized: "Interpret ist leer")
    case .emptyAlbum: return String(localized: "Album ist leer")
    case .duplicateTitle: return String(localized: "Gleicher Titel, Interpret und Dauer")
    case .filenameMismatch: return String(localized: "Dateiname passt nicht zum Muster")
    }
}

/// Ergebnis-Sheet: Befunde gruppiert nach Album/Ordner, darunter die Regel
/// mit den betroffenen Dateien. Klick auf eine Datei wählt sie in der Liste
/// aus; „Bericht kopieren" legt den Klartext in die Zwischenablage.
struct LibraryCheckSheet: View {
    let entries: [FileEntry]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var checkNames = false
    @State private var patternText = PatternHistory.initialPattern(.rename)
    @State private var check = LibraryCheckState()
    private var report: LibraryCheck.Report? { check.report }
    private var request: LibraryCheckRequest {
        LibraryCheckRequest(items: entries.compactMap(\.libraryCheckItem), checkNames: checkNames, pattern: patternText)
    }

    /// Eine Gruppe (Album/Ordner) mit ihren Befunden für die Anzeige.
    private struct Section: Identifiable {
        let id: String
        let title: String
        let fileCount: Int
        let findings: [LibraryCheck.Finding]
    }

    private var sections: [Section] {
        guard let report else { return [] }
        var result: [Section] = report.groups.compactMap { group in
            let findings = report.findings(in: group.label)
            guard !findings.isEmpty else { return nil }
            // Ordnergruppen tragen den vollen Pfad; sichtbar reicht der Name.
            let title = group.label.hasPrefix("/")
                ? String(localized: "Ordner \(URL(fileURLWithPath: group.label).lastPathComponent)")
                : group.label
            return Section(id: group.label, title: title, fileCount: group.files.count, findings: findings)
        }
        let acrossAll = report.findings(in: "")
        if !acrossAll.isEmpty {
            result.append(Section(id: "", title: String(localized: "Über alle Dateien"),
                                  fileCount: report.checkedFiles, findings: acrossAll))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konsistenzprüfung")
                .font(.title3.weight(.semibold))
            if let report {
                Text(summary(report))
                    .font(.caption)
                    .foregroundStyle(report.hasFindings(atLeast: .warning) ? Color.orange : Color.secondary)
            }
            if check.isChecking { ProgressView("Prüfe …") }
            patternRow
            List(sections) { section in
                SwiftUI.Section {
                    ForEach(Array(section.findings.enumerated()), id: \.offset) { _, finding in
                        FindingRow(finding: finding) { url in
                            model.selection = [url]
                        }
                    }
                } header: {
                    Text("\(section.title) · \(section.fileCount) Dateien")
                }
            }
            .overlay {
                if let report, report.findings.isEmpty {
                    ContentUnavailableView(
                        "Keine Befunde",
                        systemImage: "checkmark.seal",
                        description: Text("Alle geprüften Dateien sind in Ordnung."))
                }
            }
            HStack {
                Button("Bericht kopieren") { copyReport() }
                    .disabled(report == nil)
                Spacer()
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 680, idealWidth: 780, minHeight: 460, idealHeight: 560)
        .onChange(of: request, initial: true) { _, request in check.submit(request) }
        .onDisappear { check.cancel() }
    }

    /// Schalter und Musterfeld für die optionale Dateinamenprüfung.
    private var patternRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Dateinamen gegen Muster prüfen", isOn: $checkNames)
                // Prompt verbatim: "%{" darf nie durch die Format-Auswertung
                // lokalisierter Texte laufen.
                TextField("Muster", text: $patternText,
                          prompt: Text(verbatim: "%{track:2} - %{artist} - %{title}"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(!checkNames)
                Menu {
                    ForEach(PatternHistory.presets, id: \.self) { pattern in
                        Button(pattern) { patternText = pattern }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!checkNames)
                .help("Vorgaben für das Muster")
            }
            if let error = check.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func summary(_ report: LibraryCheck.Report) -> String {
        if report.findings.isEmpty {
            return String(localized: "Keine Befunde in \(report.checkedFiles) Dateien")
        }
        return String(localized:
            "\(report.checkedFiles) Dateien geprüft · \(report.warningCount) Warnungen · \(report.hintCount) Hinweise")
    }

    private func copyReport() {
        guard let report else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report.plainText(ruleTitle: libraryCheckRuleTitle), forType: .string)
    }
}

/// Ein Befund: Schweregrad-Symbol, Regelname, Detail und die Dateien als
/// anklickbare Zeilen (Klick wählt die Datei in der Liste aus).
private struct FindingRow: View {
    let finding: LibraryCheck.Finding
    let select: (URL) -> Void
    @State private var expanded: Bool

    init(finding: LibraryCheck.Finding, select: @escaping (URL) -> Void) {
        self.finding = finding
        self.select = select
        // Kurze Listen offen zeigen, lange (ganzes Album) eingeklappt.
        _expanded = State(initialValue: finding.files.count <= 3)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(finding.files, id: \.self) { path in
                Button {
                    select(URL(fileURLWithPath: path))
                } label: {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(path)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finding.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(finding.severity == .warning ? Color.orange : Color.secondary)
                Text(libraryCheckRuleTitle(finding.code))
                    .fontWeight(.medium)
                if !finding.message.isEmpty {
                    Text(finding.message)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(finding.files.count) Dateien")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

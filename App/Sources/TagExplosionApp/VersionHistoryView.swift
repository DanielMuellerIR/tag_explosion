// „Versionen …": Die Papierkorb-Sicherungen einer Datei als Liste, mit
// Feld-Vergleich zur gewählten Version und „Diese Version wiederherstellen".
// Eine gemeinsame kleine View für alle Einzel-Editoren (Audio, Bild, E-Book,
// Dokument); die Logik liegt in BackupHistory (Core) und
// AppModel.restoreVersion.
import SwiftUI
import TagExplosionCore

/// Knopf im Editor-Kopf; öffnet das Versionen-Blatt.
struct VersionHistoryButton: View {
    @Environment(AppModel.self) private var model
    let entry: FileEntry
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Versionen …", systemImage: "clock.arrow.circlepath")
        }
        .help("Sicherungen dieser Datei aus dem Papierkorb anzeigen und zurückholen")
        .disabled(entry.isSaving || model.isDestructiveActionLocked)
        .sheet(isPresented: $isPresented) {
            VersionHistorySheet(entry: entry)
                .environment(model)
        }
    }
}

/// Das Blatt: links die Versionen, rechts der Feld-Vergleich.
struct VersionHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: FileEntry

    @State private var versions: [BackupVersion] = []
    @State private var selectedID: String?
    @State private var changes: [BackupFieldChange] = []
    @State private var diffError: String?
    @State private var isLoadingDiff = false
    @State private var isRestoring = false

    private var selectedVersion: BackupVersion? {
        versions.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Versionen von \(entry.url.lastPathComponent)")
                .font(.title3.weight(.semibold))
            Text("Jede Zeile ist eine Kopie aus dem Papierkorb, die vor einer Änderung entstand. Wiederherstellen kopiert den jetzigen Stand vorher ebenfalls in den Papierkorb.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if versions.isEmpty {
                ContentUnavailableView(
                    "Keine Sicherungen",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Für diese Datei liegt keine Kopie im Papierkorb — oder der Papierkorb wurde geleert."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    versionList
                        .frame(minWidth: 280, idealWidth: 320)
                    diffPane
                        .frame(minWidth: 320)
                }
            }

            HStack {
                Button("Papierkorb-Kopie im Finder zeigen") {
                    if let version = selectedVersion {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: version.entry.backupPath)])
                    }
                }
                .disabled(selectedVersion == nil)
                Spacer()
                Button("Schließen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Diese Version wiederherstellen") { restoreSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedVersion == nil || isRestoring || isLoadingDiff
                              || entry.isSaving || model.isDestructiveActionLocked)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 440)
        .onAppear { reloadVersions() }
        .onChange(of: selectedID) { reloadDiff() }
    }

    private var versionList: some View {
        List(versions, selection: $selectedID) { version in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("#\(version.number)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(VersionHistoryFormat.date(version.entry.date))
                }
                Text("\(VersionHistoryFormat.reason(version.entry.reason)) · \(VersionHistoryFormat.size(version.entry.size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(version.id)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if selectedVersion == nil {
            Text("Version auswählen, um die Unterschiede zu sehen.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingDiff {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diffError {
            Label(diffError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        } else if changes.isEmpty {
            Text("Keine Unterschiede in den Metadaten — die Datei entspricht dieser Version.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(changes) {
                TableColumn("Feld") { change in
                    Text(change.key).font(.body.monospaced())
                }
                .width(min: 90, ideal: 140)
                TableColumn("Diese Version") { change in
                    Text(change.version ?? "—")
                        .foregroundStyle(change.version == nil ? .secondary : .primary)
                }
                TableColumn("Jetzt") { change in
                    Text(change.current ?? "—")
                        .foregroundStyle(change.current == nil ? .secondary : .primary)
                }
            }
        }
    }

    private func reloadVersions() {
        let url = entry.url
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                BackupHistory.versions(of: url)
            }.value
            versions = found
            if selectedID == nil { selectedID = found.first?.id }
        }
    }

    /// Feld-Vergleich im Hintergrund lesen (TagLib/exiftool sind nicht
    /// gratis); eine inzwischen andere Auswahl verwirft das Ergebnis.
    private func reloadDiff() {
        guard let version = selectedVersion else {
            changes = []
            diffError = nil
            return
        }
        let url = entry.url
        isLoadingDiff = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BackupHistory.diff(current: url, against: version) }
            }.value
            guard selectedID == version.id else { return }
            switch result {
            case .success(let found):
                changes = found
                diffError = nil
            case .failure(let error):
                changes = []
                diffError = error.localizedDescription
            }
            isLoadingDiff = false
        }
    }

    private func restoreSelected() {
        guard let version = selectedVersion else { return }
        guard AppModel.confirmRestore(of: version, for: entry) else { return }
        isRestoring = true
        Task {
            let ok = await model.restoreVersion(version, for: entry)
            isRestoring = false
            if ok { dismiss() }
        }
    }
}

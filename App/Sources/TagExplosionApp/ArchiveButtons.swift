// Export-/Import-Buttons für die Batch-Editoren: Tags der ausgewählten
// Dateien als selbständige JSON-Datei sichern bzw. aus einer Export-/
// Backup-JSON zurückschreiben (siehe TagArchiveIO im Core).
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct ArchiveButtons: View {
    @Environment(AppModel.self) private var model
    let entries: [FileEntry]

    var body: some View {
        GroupBox("Export/Backup") {
            HStack(spacing: 12) {
                Button {
                    presentExportPanel()
                } label: {
                    Label("Tags als JSON exportieren …", systemImage: "square.and.arrow.up")
                }
                .help("Alle Tags (inkl. Cover) der Auswahl in eine JSON-Datei schreiben")

                Button {
                    presentImportPanel()
                } label: {
                    Label("Tags aus JSON importieren …", systemImage: "square.and.arrow.down")
                }
                .help("Export-/Backup-JSON auf die Dateien anwenden (Match über relative Pfade)")

                Spacer()
            }
            .padding(8)
        }
    }

    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tags-\(Self.dateStamp).json"
        if let folder = entries.first?.url.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.message = String(localized: "Tags der \(entries.count) ausgewählten Dateien exportieren")
        if panel.runModal() == .OK, let url = panel.url {
            let selected = entries
            Task { await model.exportEntries(selected, to: url) }
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if let folder = entries.first?.url.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.message = String(localized: "Export-/Backup-JSON auswählen")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importArchive(from: url) }
        }
    }

    private static var dateStamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

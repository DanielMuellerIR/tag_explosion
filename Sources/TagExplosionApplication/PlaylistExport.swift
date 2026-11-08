import Foundation
import TagExplosionCore

extension AppModel {
    /// Schreibt die Playlist im Hintergrund; das Speichern-Panel hat ein
    /// Überschreiben schon bestätigt.
    public func exportPlaylist(files: [URL], to url: URL, format: PlaylistFormat,
                        absolutePaths: Bool, title: String) async {
        await exportPlaylist(files: files, to: url, format: format,
                             absolutePaths: absolutePaths, title: title) {
            try PlaylistExporter.export(files: $0, to: $1, format: format,
                                        absolutePaths: absolutePaths, title: title,
                                        overwrite: true).untagged
        }
    }

    /// Variante mit austauschbarem Schreiber für headless Tests — dieselbe
    /// Form wie `exportData` und `exportEntries`.
    ///
    /// Eine vorhandene Playlist wird zuerst in den Papierkorb gesichert und
    /// dann atomar ersetzt. Ohne Anmeldung sieht `hasUnfinishedWork` bei
    /// sauberen Puffern nichts, und ⌘Q beendet die App genau zwischen
    /// Sicherung und Austausch (Review-Fund 2026-09-10).
    public func exportPlaylist(
        files: [URL], to url: URL, format: PlaylistFormat,
        absolutePaths: Bool, title: String,
        write: @escaping @Sendable ([URL], URL) throws -> [URL]
    ) async {
        guard beginExport() else { return }
        defer { endExport() }
        do {
            // Rückgabe ist die Liste der Dateien ohne lesbare Tags; nur sie
            // wird angezeigt.
            let untagged = try await Task.detached(priority: .userInitiated) {
                try write(files, url)
            }.value
            if !untagged.isEmpty {
                alertMessage = String(localized: "Playlist geschrieben; ohne lesbare Tags (Dateiname als Titel):")
                    + "\n" + untagged.map(\.lastPathComponent).joined(separator: "\n")
            }
        } catch {
            alertMessage = String(localized: "Playlist-Export fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }
}

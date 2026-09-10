// „Playlist exportieren …" im Batch-Editor: schreibt die ausgewählten Dateien
// in Listenreihenfolge als m3u8, m3u, pls oder xspf. Pfade sind relativ zur
// Playlist-Datei (Schalter für absolute Pfade); Titel, Interpret, Album und
// Spielzeit kommen aus den Dateien (PlaylistExporter im Core).
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

struct PlaylistExportMenu: View {
    @Environment(AppModel.self) private var model
    let entries: [FileEntry]
    @AppStorage("playlistExportAbsolutePaths") private var absolutePaths = false

    private static let formats: [PlaylistFormat] = [.m3u8, .m3u, .pls, .xspf]

    var body: some View {
        Menu {
            ForEach(Self.formats, id: \.rawValue) { format in
                Button(format.rawValue.uppercased()) { presentSavePanel(format: format) }
            }
            Divider()
            Toggle("Absolute Pfade", isOn: $absolutePaths)
        } label: {
            Label("Playlist exportieren …", systemImage: "list.bullet.rectangle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Die Auswahl in Listenreihenfolge als Playlist-Datei sichern")
    }

    /// Gemeinsames Album der Auswahl als Vorschlag für Dateiname und Titel.
    private var commonAlbum: String {
        let albums = Set(entries.map { $0.firstValue("ALBUM") })
        return albums.count == 1 ? (albums.first ?? "") : ""
    }

    private func presentSavePanel(format: PlaylistFormat) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.rawValue) {
            panel.allowedContentTypes = [type]
        }
        let stem = commonAlbum.isEmpty ? "playlist" : commonAlbum
        panel.nameFieldStringValue = "\(stem).\(format.rawValue)"
        if let folder = entries.first?.url.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.message = String(localized: "Playlist mit \(entries.count) Einträgen exportieren")
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Das Panel lässt die Endung weg, wenn der Typ unbekannt ist.
        if url.pathExtension.lowercased() != format.rawValue {
            url = url.appendingPathExtension(format.rawValue)
        }
        let files = entries.map(\.url)
        let title = commonAlbum
        let absolute = absolutePaths
        Task {
            await model.exportPlaylist(files: files, to: url, format: format,
                                       absolutePaths: absolute, title: title)
        }
    }
}

extension AppModel {
    /// Schreibt die Playlist im Hintergrund; das Speichern-Panel hat ein
    /// Überschreiben schon bestätigt.
    func exportPlaylist(files: [URL], to url: URL, format: PlaylistFormat,
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
    func exportPlaylist(
        files: [URL], to url: URL, format: PlaylistFormat,
        absolutePaths: Bool, title: String,
        write: @escaping @Sendable ([URL], URL) throws -> [URL]
    ) async {
        beginExport()
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

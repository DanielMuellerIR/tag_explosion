// Zentrales App-Modell: geladene Dateien, Auswahl, Laden/Speichern.
// UI-State läuft auf dem MainActor; Datei-IO in Hintergrund-Tasks.
import AppKit
import Observation
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

/// Audio-Endungen, die wir öffnen (deckt die TagLib-Formate ab).
let audioExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "m4r", "mp4", "aac",
    "flac", "ogg", "oga", "opus", "spx",
    "wav", "aiff", "aif", "wv", "ape", "mpc",
    "tta", "dsf", "dff", "wma", "asf",
]

/// Bild-Endungen (Metadaten via exiftool).
let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
    "webp", "dng", "gif",
]

/// Art der geladenen Datei — bestimmt Editor und Speicherweg.
enum MediaKind: Sendable {
    case audio
    case image

    static func forURL(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        return nil
    }
}

/// Eine geladene Datei mit Original-Zustand und Bearbeitungspuffer.
@Observable
@MainActor
final class FileEntry: Identifiable {
    nonisolated let url: URL
    nonisolated let kind: MediaKind
    nonisolated var id: URL { url }

    /// Zustand wie zuletzt von der Platte gelesen (Audio).
    private(set) var original: TagData
    /// Bearbeitungspuffer — das, was die UI anzeigt und ändert (Audio).
    var properties: [TagProperty]
    var artworks: [Artwork]

    /// Original und Bearbeitungspuffer für Bilder (nur bei kind == .image).
    private(set) var imageOriginal: ImageCoreFields
    var imageFields: ImageCoreFields

    /// Fehlertext des letzten Speicherversuchs (nil = ok).
    var lastError: String?

    init(url: URL, data: TagData) {
        self.url = url
        self.kind = .audio
        self.original = data
        self.properties = data.properties
        self.artworks = data.artworks
        self.imageOriginal = ImageCoreFields()
        self.imageFields = ImageCoreFields()
    }

    init(url: URL, image: ImageCoreFields) {
        self.url = url
        self.kind = .image
        self.original = TagData(properties: [], artworks: [], audio: nil)
        self.properties = []
        self.artworks = []
        self.imageOriginal = image
        self.imageFields = image
    }

    var audio: AudioInfo? { original.audio }
    var isReadOnly: Bool { kind == .audio && original.isReadOnly }

    var isDirty: Bool {
        switch kind {
        case .audio:
            return properties != original.properties || artworks != original.artworks
        case .image:
            return imageFields != imageOriginal
        }
    }

    /// Verwirft alle ungespeicherten Änderungen.
    func revert() {
        properties = original.properties
        artworks = original.artworks
        imageFields = imageOriginal
        lastError = nil
    }

    /// Nach erfolgreichem Speichern/Neuladen den Originalzustand ersetzen.
    func acceptNewOriginal(_ data: TagData) {
        original = data
        properties = data.properties
        artworks = data.artworks
        lastError = nil
    }

    /// Bild-Pendant zu `acceptNewOriginal`.
    func acceptNewImageOriginal(_ fields: ImageCoreFields) {
        imageOriginal = fields
        imageFields = fields
        lastError = nil
    }

    // Bequeme Zugriffe für die UI ------------------------------------------

    /// Erster Wert eines Schlüssels (für Einfach-Felder).
    func firstValue(_ key: String) -> String {
        properties.first { $0.key == key }?.value ?? ""
    }

    /// Setzt einen Schlüssel auf genau einen Wert (leer = Feld entfernen).
    func setSingleValue(_ key: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = properties.firstIndex(where: { $0.key == key }) {
            if trimmed.isEmpty {
                properties.removeAll { $0.key == key }
            } else {
                // Ersten Eintrag ändern, weitere gleichnamige entfernen
                properties[index].value = trimmed
                var seen = false
                properties.removeAll { prop in
                    if prop.key == key {
                        if seen { return true }
                        seen = true
                    }
                    return false
                }
            }
        } else if !trimmed.isEmpty {
            properties.append(TagProperty(key: key, value: trimmed))
        }
    }

    var displayTitle: String {
        let title = kind == .image ? imageFields.title : firstValue("TITLE")
        return title.isEmpty ? url.lastPathComponent : title
    }

    var displaySubtitle: String {
        switch kind {
        case .audio:
            return [firstValue("ARTIST"), firstValue("ALBUM")]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        case .image:
            return imageFields.keywords.joined(separator: ", ")
        }
    }
}

/// Frisch gelesener Datei-Zustand (Audio oder Bild).
enum LoadedData: Sendable {
    case audio(TagData)
    case image(ImageCoreFields)
}

/// Globaler App-Zustand.
@Observable
@MainActor
final class AppModel {
    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    /// Läuft gerade ein Ladevorgang? (Fortschritt in der Sidebar)
    var isLoading = false
    /// Fehlermeldung für Alert-Anzeige.
    var alertMessage: String?

    /// Die ausgewählten Einträge in Listenreihenfolge.
    var selectedEntries: [FileEntry] {
        entries.filter { selection.contains($0.url) }
    }

    /// Genau ein ausgewählter Eintrag (Einzel-Editor), sonst nil.
    var selectedEntry: FileEntry? {
        let selected = selectedEntries
        return selected.count == 1 ? selected.first : nil
    }

    var hasDirtyEntries: Bool {
        entries.contains { $0.isDirty }
    }

    // MARK: - Öffnen

    /// Öffnen-Dialog (Dateien und Ordner).
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Audiodateien oder Ordner auswählen"
        if panel.runModal() == .OK {
            Task { await self.open(urls: panel.urls) }
        }
    }

    /// Lädt Dateien/Ordner (rekursiv), liest Tags im Hintergrund.
    func open(urls: [URL]) async {
        isLoading = true
        defer { isLoading = false }

        // Verzeichnisse expandieren und auf Audio-Endungen filtern (Hintergrund).
        let candidates = await Task.detached(priority: .userInitiated) {
            Self.expandToMediaFiles(urls)
        }.value

        // Bereits geladene überspringen
        let existing = Set(entries.map(\.url))
        let newFiles = candidates.filter { !existing.contains($0) }
        guard !newFiles.isEmpty else { return }

        // Tags parallel lesen (begrenzte Nebenläufigkeit, damit auch riesige
        // Ordner nicht zu viele offene Dateien erzeugen), Reihenfolge stabil.
        let results = await Task.detached(priority: .userInitiated) {
            await withTaskGroup(
                of: (Int, URL, Result<LoadedData, Error>).self,
                returning: [(URL, Result<LoadedData, Error>)].self
            ) { group in
                let maxConcurrent = 8
                var nextIndex = 0
                func addNext() {
                    guard nextIndex < newFiles.count else { return }
                    let i = nextIndex
                    let url = newFiles[i]
                    nextIndex += 1
                    group.addTask {
                        do {
                            switch MediaKind.forURL(url) {
                            case .image:
                                return (i, url, .success(.image(try ExifTool.readCoreFields(url: url))))
                            default:
                                return (i, url, .success(.audio(try TagFile.read(at: url))))
                            }
                        } catch {
                            return (i, url, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(maxConcurrent, newFiles.count) { addNext() }
                var buffer: [(Int, URL, Result<LoadedData, Error>)] = []
                for await item in group {
                    buffer.append(item)
                    addNext()
                }
                buffer.sort { $0.0 < $1.0 }
                return buffer.map { ($0.1, $0.2) }
            }
        }.value

        var failures: [String] = []
        for (url, result) in results {
            switch result {
            case .success(.audio(let data)):
                entries.append(FileEntry(url: url, data: data))
            case .success(.image(let fields)):
                entries.append(FileEntry(url: url, image: fields))
            case .failure:
                failures.append(url.lastPathComponent)
            }
        }
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
        if !failures.isEmpty {
            alertMessage = "Nicht lesbar (Format unbekannt?):\n" + failures.joined(separator: "\n")
        }
    }

    /// Verzeichnisse rekursiv auflösen, nur Medien-Dateien behalten, sortiert.
    nonisolated static func expandToMediaFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let child as URL in iterator {
                        if MediaKind.forURL(child) != nil {
                            files.append(child)
                        }
                    }
                }
            } else if MediaKind.forURL(url) != nil {
                files.append(url)
            }
        }
        // Stabile, menschliche Sortierung (Finder-artig)
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // MARK: - Speichern

    /// Speichert alle ausgewählten Dateien mit Änderungen.
    func saveSelected() async {
        for entry in selectedEntries where entry.isDirty {
            await save(entry: entry)
        }
    }

    /// Verwirft Änderungen aller ausgewählten Dateien.
    func revertSelected() {
        for entry in selectedEntries { entry.revert() }
    }

    var selectionIsDirty: Bool {
        selectedEntries.contains { $0.isDirty }
    }

    func saveAll() async {
        for entry in entries where entry.isDirty {
            await save(entry: entry)
        }
    }

    /// Schreibt den Bearbeitungspuffer einer Datei und liest sie neu ein.
    func save(entry: FileEntry) async {
        let url = entry.url
        do {
            switch entry.kind {
            case .audio:
                let properties = entry.properties
                let artworks = entry.artworks
                let reloaded = try await Task.detached(priority: .userInitiated) {
                    try TagFile.write(properties: properties, artworks: artworks, to: url)
                    return try TagFile.read(at: url)
                }.value
                entry.acceptNewOriginal(reloaded)
            case .image:
                let fields = entry.imageFields
                let original = entry.imageOriginal
                let reloaded = try await Task.detached(priority: .userInitiated) {
                    try ExifTool.writeCoreFields(url: url, fields: fields, original: original)
                    return try ExifTool.readCoreFields(url: url)
                }.value
                entry.acceptNewImageOriginal(reloaded)
            }
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = "Speichern fehlgeschlagen: \(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    // MARK: - Liste verwalten

    func remove(urls: [URL]) {
        entries.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
    }
}

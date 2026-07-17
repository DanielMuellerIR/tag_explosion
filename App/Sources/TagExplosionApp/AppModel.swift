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

/// Eine geladene Datei mit Original-Zustand und Bearbeitungspuffer.
@Observable
@MainActor
final class FileEntry: Identifiable {
    nonisolated let url: URL
    nonisolated var id: URL { url }

    /// Zustand wie zuletzt von der Platte gelesen.
    private(set) var original: TagData
    /// Bearbeitungspuffer — das, was die UI anzeigt und ändert.
    var properties: [TagProperty]
    var artworks: [Artwork]

    /// Fehlertext des letzten Speicherversuchs (nil = ok).
    var lastError: String?

    init(url: URL, data: TagData) {
        self.url = url
        self.original = data
        self.properties = data.properties
        self.artworks = data.artworks
    }

    var audio: AudioInfo? { original.audio }
    var isReadOnly: Bool { original.isReadOnly }

    var isDirty: Bool {
        properties != original.properties || artworks != original.artworks
    }

    /// Verwirft alle ungespeicherten Änderungen.
    func revert() {
        properties = original.properties
        artworks = original.artworks
        lastError = nil
    }

    /// Nach erfolgreichem Speichern/Neuladen den Originalzustand ersetzen.
    func acceptNewOriginal(_ data: TagData) {
        original = data
        properties = data.properties
        artworks = data.artworks
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
        let title = firstValue("TITLE")
        return title.isEmpty ? url.lastPathComponent : title
    }

    var displaySubtitle: String {
        [firstValue("ARTIST"), firstValue("ALBUM")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Globaler App-Zustand.
@Observable
@MainActor
final class AppModel {
    var entries: [FileEntry] = []
    var selection: URL?
    /// Läuft gerade ein Ladevorgang? (Fortschritt in der Sidebar)
    var isLoading = false
    /// Fehlermeldung für Alert-Anzeige.
    var alertMessage: String?

    var selectedEntry: FileEntry? {
        guard let selection else { return nil }
        return entries.first { $0.url == selection }
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
            Self.expandToAudioFiles(urls)
        }.value

        // Bereits geladene überspringen
        let existing = Set(entries.map(\.url))
        let newFiles = candidates.filter { !existing.contains($0) }
        guard !newFiles.isEmpty else { return }

        // Tags parallel lesen (begrenzte Nebenläufigkeit, damit auch riesige
        // Ordner nicht zu viele offene Dateien erzeugen), Reihenfolge stabil.
        let results = await Task.detached(priority: .userInitiated) {
            await withTaskGroup(
                of: (Int, URL, Result<TagData, Error>).self,
                returning: [(URL, Result<TagData, Error>)].self
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
                            return (i, url, .success(try TagFile.read(at: url)))
                        } catch {
                            return (i, url, .failure(error))
                        }
                    }
                }
                for _ in 0..<min(maxConcurrent, newFiles.count) { addNext() }
                var buffer: [(Int, URL, Result<TagData, Error>)] = []
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
            case .success(let data):
                entries.append(FileEntry(url: url, data: data))
            case .failure:
                failures.append(url.lastPathComponent)
            }
        }
        if selection == nil { selection = entries.first?.url }
        if !failures.isEmpty {
            alertMessage = "Nicht lesbar (Format unbekannt?):\n" + failures.joined(separator: "\n")
        }
    }

    /// Verzeichnisse rekursiv auflösen, nur Audio-Dateien behalten, sortiert.
    nonisolated static func expandToAudioFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let child as URL in iterator {
                        if audioExtensions.contains(child.pathExtension.lowercased()) {
                            files.append(child)
                        }
                    }
                }
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        // Stabile, menschliche Sortierung (Finder-artig)
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    // MARK: - Speichern

    func saveSelected() async {
        guard let entry = selectedEntry else { return }
        await save(entry: entry)
    }

    func saveAll() async {
        for entry in entries where entry.isDirty {
            await save(entry: entry)
        }
    }

    /// Schreibt den Bearbeitungspuffer einer Datei und liest sie neu ein.
    func save(entry: FileEntry) async {
        let url = entry.url
        let properties = entry.properties
        let artworks = entry.artworks
        do {
            let reloaded = try await Task.detached(priority: .userInitiated) {
                try TagFile.write(properties: properties, artworks: artworks, to: url)
                return try TagFile.read(at: url)
            }.value
            entry.acceptNewOriginal(reloaded)
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = "Speichern fehlgeschlagen: \(url.lastPathComponent)\n\(error.localizedDescription)"
        }
    }

    // MARK: - Liste verwalten

    func remove(urls: [URL]) {
        entries.removeAll { urls.contains($0.url) }
        if let selection, urls.contains(selection) {
            self.selection = entries.first?.url
        }
    }
}

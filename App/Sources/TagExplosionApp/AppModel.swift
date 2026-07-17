// Zentrales App-Modell: geladene Dateien, Auswahl, Laden/Speichern.
// UI-State läuft auf dem MainActor; Datei-IO in Hintergrund-Tasks.
import AppKit
import Observation
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

// Endungs-Sets kommen zentral aus dem Core (MediaFormats), damit App, CLI
// und Export/Import dieselbe Dateierkennung nutzen.
let audioExtensions = MediaFormats.audio
let imageExtensions = MediaFormats.image
let videoExtensions = MediaFormats.video
let ebookExtensions = MediaFormats.ebook

/// Art der geladenen Datei — bestimmt Editor und Speicherweg.
enum MediaKind: Sendable {
    case audio
    case image
    case ebook

    static func forURL(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .image }
        if ebookExtensions.contains(ext) { return .ebook }
        // Video läuft über denselben TagLib-Weg wie Audio (PropertyMap);
        // was TagLib nicht schreiben kann, wird read-only angezeigt.
        if videoExtensions.contains(ext) { return .audio }
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

    /// Original und Bearbeitungspuffer für E-Books (nur bei kind == .ebook).
    private(set) var ebookOriginal: EbookCoreFields
    var ebookFields: EbookCoreFields
    /// Neues Cover, das beim Speichern geschrieben wird (nil = unverändert).
    var ebookCoverReplacement: Data?

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
        self.ebookOriginal = EbookCoreFields()
        self.ebookFields = EbookCoreFields()
    }

    init(url: URL, image: ImageCoreFields) {
        self.url = url
        self.kind = .image
        self.original = TagData(properties: [], artworks: [], audio: nil)
        self.properties = []
        self.artworks = []
        self.imageOriginal = image
        self.imageFields = image
        self.ebookOriginal = EbookCoreFields()
        self.ebookFields = EbookCoreFields()
    }

    init(url: URL, ebook: EbookCoreFields) {
        self.url = url
        self.kind = .ebook
        self.original = TagData(properties: [], artworks: [], audio: nil)
        self.properties = []
        self.artworks = []
        self.imageOriginal = ImageCoreFields()
        self.imageFields = ImageCoreFields()
        self.ebookOriginal = ebook
        self.ebookFields = ebook
    }

    var audio: AudioInfo? { original.audio }
    var isReadOnly: Bool { kind == .audio && original.isReadOnly }

    var isDirty: Bool {
        switch kind {
        case .audio:
            return properties != original.properties || artworks != original.artworks
        case .image:
            return imageFields != imageOriginal
        case .ebook:
            return ebookFields != ebookOriginal || ebookCoverReplacement != nil
        }
    }

    /// Verwirft alle ungespeicherten Änderungen.
    func revert() {
        properties = original.properties
        artworks = original.artworks
        imageFields = imageOriginal
        ebookFields = ebookOriginal
        ebookCoverReplacement = nil
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

    /// E-Book-Pendant zu `acceptNewOriginal`.
    func acceptNewEbookOriginal(_ fields: EbookCoreFields) {
        ebookOriginal = fields
        ebookFields = fields
        ebookCoverReplacement = nil
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
        let title: String
        switch kind {
        case .audio: title = firstValue("TITLE")
        case .image: title = imageFields.title
        case .ebook: title = ebookFields.title
        }
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
        case .ebook:
            return ebookFields.authors.joined(separator: ", ")
        }
    }
}

/// Frisch gelesener Datei-Zustand (Audio, Bild oder E-Book).
enum LoadedData: Sendable {
    case audio(TagData)
    case image(ImageCoreFields)
    case ebook(EbookCoreFields)
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
        panel.message = String(localized: "Mediendateien (Audio, Bild, Video, E-Book) oder Ordner auswählen")
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
                            case .ebook:
                                return (i, url, .success(.ebook(try EbookTool.readCoreFields(url: url))))
                            default:
                                do {
                                    return (i, url, .success(.audio(try TagFile.read(at: url))))
                                } catch {
                                    // TagLib kennt den Container nicht (z.B. avi/mov):
                                    // trotzdem anzeigen (Technik-Tab via mediainfo),
                                    // aber als schreibgeschützt markieren.
                                    let fallback = TagData(properties: [], artworks: [],
                                                           audio: nil, isReadOnly: true)
                                    return (i, url, .success(.audio(fallback)))
                                }
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
            case .success(.ebook(let fields)):
                entries.append(FileEntry(url: url, ebook: fields))
            case .failure:
                failures.append(url.lastPathComponent)
            }
        }
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
        if !failures.isEmpty {
            alertMessage = String(localized: "Nicht lesbar (Format unbekannt?):") + "\n" + failures.joined(separator: "\n")
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

    /// Schlüssel der Auto-Backup-Einstellung (Toggle in den Einstellungen).
    static let autoBackupDefaultsKey = "autoBackupBeforeBatchSave"

    /// Auto-Backup vor Batch-Speichern? (Default: an)
    static var autoBackupEnabled: Bool {
        UserDefaults.standard.object(forKey: autoBackupDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: autoBackupDefaultsKey)
    }

    /// Speichert alle ausgewählten Dateien mit Änderungen.
    func saveSelected() async {
        let dirty = selectedEntries.filter(\.isDirty)
        guard await backupIfNeeded(before: dirty) else { return }
        for entry in dirty {
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
        let dirty = entries.filter(\.isDirty)
        guard await backupIfNeeded(before: dirty) else { return }
        for entry in dirty {
            await save(entry: entry)
        }
    }

    /// Schreibt vor einem Batch-Speichern (mehr als eine Datei) je betroffenem
    /// Ordner ein `tags-backup-<Zeitstempel>.json` mit dem aktuellen
    /// Platten-Zustand (Wiederherstellen = derselbe Import-Weg).
    /// false = Backup fehlgeschlagen, Speichern wird abgebrochen.
    private func backupIfNeeded(before dirtyEntries: [FileEntry]) async -> Bool {
        guard Self.autoBackupEnabled, dirtyEntries.count > 1 else { return true }
        // Zeitstempel ohne Doppelpunkte (Dateiname), ISO-8601-sortierbar.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())

        let byFolder = Dictionary(grouping: dirtyEntries.map(\.url)) {
            $0.deletingLastPathComponent()
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                for (folder, urls) in byFolder {
                    let target = folder.appendingPathComponent("tags-backup-\(stamp).json")
                    try TagArchiveIO.export(files: urls, to: target, includeCovers: true)
                }
            }.value
            return true
        } catch {
            alertMessage = String(localized: "Auto-Backup fehlgeschlagen — Speichern abgebrochen.")
                + "\n" + error.localizedDescription
            return false
        }
    }

    // MARK: - Export/Import (JSON)

    /// Exportiert die Tags der Einträge als selbständige JSON-Datei.
    func exportEntries(_ exportEntries: [FileEntry], to url: URL) async {
        let files = exportEntries.map(\.url)
        do {
            try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.export(files: files, to: url, includeCovers: true)
            }.value
        } catch {
            alertMessage = String(localized: "Export fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Wendet eine Export-/Backup-JSON auf die Platte an und lädt betroffene,
    /// bereits geöffnete Dateien neu.
    func importArchive(from url: URL) async {
        do {
            let report = try await Task.detached(priority: .userInitiated) {
                let archive = try TagArchiveIO.load(url)
                return TagArchiveIO.apply(
                    archive, relativeTo: url.deletingLastPathComponent(), dryRun: false)
            }.value

            // Geänderte, geladene Einträge neu von der Platte lesen.
            let base = url.deletingLastPathComponent()
            let changedPaths = Set(report.applied.map {
                TagArchiveIO.resolve(path: $0, in: base).path
            })
            for entry in entries where changedPaths.contains(entry.url.standardizedFileURL.path) {
                await reload(entry: entry)
            }

            var summary = String(localized: "Import: \(report.applied.count) geändert, \(report.unchanged.count) unverändert")
            if !report.missing.isEmpty { summary += String(localized: ", \(report.missing.count) fehlend") }
            if !report.extra.isEmpty { summary += String(localized: ", \(report.extra.count) nicht im Archiv") }
            if !report.failed.isEmpty {
                summary += "\n" + String(localized: "Fehlgeschlagen:") + "\n" + report.failed
                    .map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            }
            alertMessage = summary
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Liest eine Datei neu von der Platte und ersetzt den Originalzustand.
    private func reload(entry: FileEntry) async {
        let url = entry.url
        do {
            switch entry.kind {
            case .audio:
                let data = try await Task.detached(priority: .userInitiated) {
                    try TagFile.read(at: url)
                }.value
                entry.acceptNewOriginal(data)
            case .image:
                let fields = try await Task.detached(priority: .userInitiated) {
                    try ExifTool.readCoreFields(url: url)
                }.value
                entry.acceptNewImageOriginal(fields)
            case .ebook:
                let fields = try await Task.detached(priority: .userInitiated) {
                    try EbookTool.readCoreFields(url: url)
                }.value
                entry.acceptNewEbookOriginal(fields)
            }
        } catch {
            entry.lastError = error.localizedDescription
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
            case .ebook:
                let fields = entry.ebookFields
                let original = entry.ebookOriginal
                let newCover = entry.ebookCoverReplacement
                let reloaded = try await Task.detached(priority: .userInitiated) {
                    try EbookTool.writeCoreFields(url: url, fields: fields, original: original)
                    if let newCover {
                        try EbookTool.writeCover(url: url, data: newCover)
                    }
                    return try EbookTool.readCoreFields(url: url)
                }.value
                entry.acceptNewEbookOriginal(reloaded)
            }
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Speichern fehlgeschlagen: \(url.lastPathComponent)")
                + "\n" + error.localizedDescription
        }
    }

    // MARK: - Liste verwalten

    func remove(urls: [URL]) {
        entries.removeAll { urls.contains($0.url) }
        selection.subtract(urls)
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
    }
}

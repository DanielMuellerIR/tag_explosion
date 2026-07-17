// Batch-Export/-Import und Tag-Backup als eine selbständige JSON-Datei.
// Schema je Datei: relativer Pfad (zur JSON-Datei) + je nach Medienart die
// vollständige PropertyMap (mehrwertige Schlüssel als Arrays) bzw. die
// Kernfelder, Cover Base64-eingebettet. Ausschließlich JSONEncoder/JSONDecoder
// (korrektes Escaping garantiert).
import Foundation

/// Der Inhalt einer Export-/Backup-Datei.
public struct TagArchive: Codable, Sendable, Equatable {
    public var version: Int
    /// Erstellungszeitpunkt, ISO 8601.
    public var created: String
    public var files: [Entry]

    public struct Entry: Codable, Sendable, Equatable {
        /// Pfad relativ zum Speicherort der JSON-Datei (POSIX-Separatoren).
        public var path: String
        public var kind: MediaFormats.Kind
        /// Audio/Video: vollständige PropertyMap.
        public var properties: [String: [String]]?
        /// Cover (Audio/Video mehrere, E-Book eins); Data → Base64 im JSON.
        public var artworks: [Artwork]?
        /// Bilder: Kernfelder statt PropertyMap.
        public var image: ImageCoreFields?
        /// E-Books: Kernfelder.
        public var ebook: EbookCoreFields?
    }

    public init(version: Int = 1, created: String, files: [Entry]) {
        self.version = version
        self.created = created
        self.files = files
    }
}

/// Ergebnis eines Imports (bzw. einer --dry-run-Vorschau).
public struct TagArchiveReport: Sendable, Equatable {
    /// Dateien, die geändert wurden (bzw. würden).
    public var applied: [String] = []
    /// Dateien, die bereits dem Archiv entsprechen.
    public var unchanged: [String] = []
    /// Archiv-Einträge ohne existierende Datei.
    public var missing: [String] = []
    /// Mediendateien unter dem JSON-Ordner, die nicht im Archiv stehen.
    public var extra: [String] = []
    /// Dateien, bei denen das Schreiben fehlschlug (Pfad + Fehlertext).
    public var failed: [(String, String)] = []

    public static func == (lhs: TagArchiveReport, rhs: TagArchiveReport) -> Bool {
        lhs.applied == rhs.applied && lhs.unchanged == rhs.unchanged
            && lhs.missing == rhs.missing && lhs.extra == rhs.extra
            && lhs.failed.map(\.0) == rhs.failed.map(\.0)
    }
}

public enum TagArchiveIO {

    // MARK: - Exportieren

    /// Liest die Dateien und baut das Archiv (Pfade relativ zu `baseDirectory`,
    /// dem späteren Speicherort der JSON-Datei).
    public static func build(files: [URL], baseDirectory: URL,
                             includeCovers: Bool) throws -> TagArchive {
        var entries: [TagArchive.Entry] = []
        for url in files {
            guard let kind = MediaFormats.kind(of: url) else { continue }
            var entry = TagArchive.Entry(
                path: relativePath(of: url, to: baseDirectory), kind: kind)
            switch kind {
            case .audio:
                let data = try TagFile.read(at: url)
                entry.properties = propertyMap(data.properties)
                if includeCovers, !data.artworks.isEmpty {
                    entry.artworks = data.artworks
                }
            case .image:
                entry.image = try ExifTool.readCoreFields(url: url)
            case .ebook:
                entry.ebook = try EbookTool.readCoreFields(url: url)
                if includeCovers, let cover = try? EbookTool.readCover(url: url) {
                    entry.artworks = [cover]
                }
            }
            entries.append(entry)
        }
        let created = ISO8601DateFormatter().string(from: Date())
        return TagArchive(created: created, files: entries)
    }

    /// Baut das Archiv und schreibt es atomar als JSON.
    public static func export(files: [URL], to jsonURL: URL, includeCovers: Bool) throws {
        let archive = try build(files: files,
                                baseDirectory: jsonURL.deletingLastPathComponent(),
                                includeCovers: includeCovers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(archive).write(to: jsonURL, options: .atomic)
    }

    // MARK: - Importieren

    public static func load(_ url: URL) throws -> TagArchive {
        try JSONDecoder().decode(TagArchive.self, from: Data(contentsOf: url))
    }

    /// Wendet ein Archiv auf die Platte an (bzw. zeigt mit `dryRun` nur, was
    /// passieren würde). Gematcht wird ausschließlich über den relativen Pfad
    /// zur JSON-Datei; fehlende und zusätzliche Dateien werden gemeldet statt
    /// zu raten.
    public static func apply(_ archive: TagArchive, relativeTo baseDirectory: URL,
                             dryRun: Bool) -> TagArchiveReport {
        var report = TagArchiveReport()
        for entry in archive.files {
            let url = resolve(path: entry.path, in: baseDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                report.missing.append(entry.path)
                continue
            }
            do {
                if try applyEntry(entry, to: url, dryRun: dryRun) {
                    report.applied.append(entry.path)
                } else {
                    report.unchanged.append(entry.path)
                }
            } catch {
                report.failed.append((entry.path, String(describing: error)))
            }
        }

        // Zusätzliche Mediendateien unterhalb des JSON-Ordners melden.
        let known = Set(archive.files.map { resolve(path: $0.path, in: baseDirectory).path })
        for url in MediaFormats.expandMediaFiles([baseDirectory])
        where !known.contains(url.standardizedFileURL.path) {
            report.extra.append(relativePath(of: url, to: baseDirectory))
        }
        return report
    }

    /// Wendet einen Eintrag an; true = Datei wurde (bzw. würde) geändert.
    private static func applyEntry(_ entry: TagArchive.Entry, to url: URL,
                                   dryRun: Bool) throws -> Bool {
        switch entry.kind {
        case .audio:
            let current = try TagFile.read(at: url)
            let targetProperties = entry.properties ?? [:]
            let targetArtworks = entry.artworks
            let propertiesDiffer = propertyMap(current.properties) != targetProperties
            // Ohne Cover im Archiv (--without-covers) bleiben Cover unangetastet.
            let artworksDiffer = targetArtworks.map { $0 != current.artworks } ?? false
            guard propertiesDiffer || artworksDiffer else { return false }
            if !dryRun {
                try TagFile.write(properties: propertyList(targetProperties),
                                  artworks: targetArtworks ?? current.artworks, to: url)
            }
            return true
        case .image:
            let current = try ExifTool.readCoreFields(url: url)
            guard let target = entry.image, target != current else { return false }
            if !dryRun {
                try ExifTool.writeCoreFields(url: url, fields: target, original: current)
            }
            return true
        case .ebook:
            let current = try EbookTool.readCoreFields(url: url)
            let target = entry.ebook ?? current
            let fieldsDiffer = target != current
            var coverDiffers = false
            if let cover = entry.artworks?.first, EbookTool.supportsCover(url: url) {
                coverDiffers = (try? EbookTool.readCover(url: url))?.data != cover.data
            }
            guard fieldsDiffer || coverDiffers else { return false }
            if !dryRun {
                if fieldsDiffer {
                    try EbookTool.writeCoreFields(url: url, fields: target, original: current)
                }
                if coverDiffers, let cover = entry.artworks?.first {
                    try EbookTool.writeCover(url: url, data: cover.data)
                }
            }
            return true
        }
    }

    // MARK: - Helfer

    /// [TagProperty] → PropertyMap-Wörterbuch (mehrwertig, Reihenfolge je
    /// Schlüssel bleibt erhalten).
    static func propertyMap(_ properties: [TagProperty]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for property in properties {
            map[property.key, default: []].append(property.value)
        }
        return map
    }

    /// PropertyMap-Wörterbuch → [TagProperty] (Schlüssel sortiert, damit das
    /// Ergebnis deterministisch ist).
    static func propertyList(_ map: [String: [String]]) -> [TagProperty] {
        map.keys.sorted().flatMap { key in
            map[key]!.map { TagProperty(key: key, value: $0) }
        }
    }

    /// Relativen Archiv-Pfad gegen das JSON-Verzeichnis auflösen.
    /// (Bewusst NICHT `URL(fileURLWithPath:relativeTo:)` — ohne Verzeichnis-
    /// Slash am Basis-URL landet der Pfad sonst NEBEN dem Ordner.)
    public static func resolve(path: String, in baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(path).standardizedFileURL
    }

    /// Relativer POSIX-Pfad von `base` zu `file` (mit ".." falls nötig).
    static func relativePath(of file: URL, to base: URL) -> String {
        let fileParts = file.standardizedFileURL.pathComponents
        let baseParts = base.standardizedFileURL.pathComponents
        var common = 0
        while common < min(fileParts.count, baseParts.count),
              fileParts[common] == baseParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        return (ups + fileParts[common...]).joined(separator: "/")
    }
}

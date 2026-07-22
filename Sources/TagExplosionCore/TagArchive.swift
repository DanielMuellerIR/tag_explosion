// Batch-Export/-Import und Tag-Backup als eine selbständige JSON-Datei.
// Schema je Datei: relativer Pfad (zur JSON-Datei) + je nach Medienart die
// vollständige PropertyMap (mehrwertige Schlüssel als Arrays) bzw. die
// Kernfelder, Cover Base64-eingebettet. Ausschließlich JSONEncoder/JSONDecoder
// (korrektes Escaping garantiert).
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

        public init(path: String, kind: MediaFormats.Kind,
                    properties: [String: [String]]? = nil,
                    artworks: [Artwork]? = nil,
                    image: ImageCoreFields? = nil,
                    ebook: EbookCoreFields? = nil) {
            self.path = path
            self.kind = kind
            self.properties = properties
            self.artworks = artworks
            self.image = image
            self.ebook = ebook
        }
    }

    public init(version: Int = 1, created: String, files: [Entry]) {
        self.version = version
        self.created = created
        self.files = files
    }
}

/// Fehler eines Archivs, die vor dem ersten Schreibzugriff erkannt werden.
/// Ein Archiv ist ein vollständiger Soll-Zustand. Deshalb ist es sicherer,
/// unvollständige Daten komplett abzulehnen als einzelne Dateien halb zu
/// importieren.
public enum TagArchiveError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedVersion(Int)
    case incompleteEntry(path: String, kind: MediaFormats.Kind, missing: String)
    case inconsistentEntry(path: String, detail: String)
    case externalTargetRequiresApproval(path: String, resolvedPath: String)
    case approvedTargetListChanged
    case exportDestinationMatchesInput(input: String, destination: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported tag archive version: \(version)"
        case .incompleteEntry(let path, let kind, let missing):
            return "Archive entry \(path) (\(kind.rawValue)) is missing required \(missing) data"
        case .inconsistentEntry(let path, let detail):
            return "Archive entry \(path) is inconsistent: \(detail)"
        case .externalTargetRequiresApproval(let path, let resolvedPath):
            return "Archive entry \(path) resolves outside the archive directory to \(resolvedPath). Explicit approval is required."
        case .approvedTargetListChanged:
            return "Resolved archive targets changed after approval. Nothing was written."
        case .exportDestinationMatchesInput(let input, let destination):
            return "Export destination \(destination) matches input media file \(input). Choose a different --output path."
        }
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

    /// Aktuell versteht der Import ausschließlich das erste, veröffentlichte
    /// Archivschema. Neue Schemata dürfen nicht versehentlich wie alte gelesen
    /// werden, weil dabei Felder verloren gehen könnten.
    private static let supportedVersions: Set<Int> = [1]

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
                if includeCovers {
                    let data = try TagFile.read(at: url)
                    entry.properties = propertyMap(data.properties)
                    // [] bedeutet bewusst: Es wurde nach Covern gesucht, aber
                    // keines gefunden. nil bleibt für --without-covers reserviert.
                    entry.artworks = data.artworks
                } else {
                    // Ohne Cover reicht die PropertyMap — erspart das
                    // Extrahieren aller eingebetteten Bilder.
                    let file = try TagFile(url: url)
                    defer { file.close() }
                    entry.properties = propertyMap(try file.properties())
                }
            case .image:
                entry.image = try ExifTool.readCoreFields(url: url)
            case .ebook:
                entry.ebook = try EbookTool.readCoreFields(url: url)
                if includeCovers, EbookTool.supportsCover(url: url) {
                    // Lesefehler nicht als "kein Cover" umdeuten: Sonst könnte
                    // ein späterer Import ein vorhandenes Cover löschen.
                    entry.artworks = try EbookTool.readCover(url: url).map { [$0] } ?? []
                }
            }
            entries.append(entry)
        }
        let created = ISO8601DateFormatter().string(from: Date())
        return TagArchive(created: created, files: entries)
    }

    /// Baut das Archiv und schreibt es atomar als JSON.
    public static func export(files: [URL], to jsonURL: URL, includeCovers: Bool) throws {
        try validateExportDestination(files: files, destination: jsonURL)
        let archive = try build(files: files,
                                baseDirectory: jsonURL.deletingLastPathComponent(),
                                includeCovers: includeCovers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(archive).write(to: jsonURL, options: .atomic)
    }

    /// Schreibt je betroffenem Ordner ein `tags-backup-<Zeitstempel>.json` mit
    /// dem aktuellen Platten-Zustand der Dateien (bewusst frisch gelesen, nicht
    /// aus Puffern — das Backup soll den echten Dateizustand sichern).
    /// Wiederherstellen = derselbe Import-Weg, auch per `tagx import`.
    @discardableResult
    public static func writeBackups(files: [URL]) throws -> [URL] {
        // Zeitstempel ohne Doppelpunkte (Dateiname), ISO-8601-sortierbar.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: Date())

        var written: [URL] = []
        for (folder, urls) in Dictionary(grouping: files, by: { $0.deletingLastPathComponent() }) {
            let target = folder.appendingPathComponent("tags-backup-\(stamp).json")
            try export(files: urls, to: target, includeCovers: true)
            written.append(target)
        }
        return written
    }

    // MARK: - Importieren

    public static func load(_ url: URL) throws -> TagArchive {
        let archive = try JSONDecoder().decode(TagArchive.self, from: Data(contentsOf: url))
        try validate(archive)
        return archive
    }

    /// Wendet ein Archiv auf die Platte an (bzw. zeigt mit `dryRun` nur, was
    /// passieren würde). Gematcht wird ausschließlich über den relativen Pfad
    /// zur JSON-Datei; fehlende und zusätzliche Dateien werden gemeldet statt
    /// zu raten.
    public static func apply(_ archive: TagArchive, relativeTo baseDirectory: URL,
                             dryRun: Bool, approvedTargets: [URL]? = nil) throws
    -> TagArchiveReport {
        // Die gesamte Datei wird vor der Schleife geprüft. Damit kann kein
        // fehlerhafter Eintrag nach einer schon geschriebenen Datei auffallen.
        // Ein zuvor in CLI/App angezeigter externer Pfad wird hier unmittelbar
        // vor den Mutationen nochmals vollständig aufgelöst und geprüft.
        let targets = try validatedTargets(
            archive, relativeTo: baseDirectory,
            allowExternalTargets: approvedTargets != nil
        )
        if let approvedTargets {
            let approved = approvedTargets.map(MediaFormats.canonicalFileURL)
            guard approved == targets else {
                throw TagArchiveError.approvedTargetListChanged
            }
        }
        var report = TagArchiveReport()
        for (entry, url) in zip(archive.files, targets) {
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
        // `expandMediaFiles` liefert kanonische URLs. Auch die Archiv-Ziele
        // müssen daher vor dem Vergleich Symlinks auflösen, sonst würde eine
        // bereits bekannte Datei fälschlich als zusätzlicher Fund erscheinen.
        let known = Set(targets.map(\.path))
        for url in MediaFormats.expandMediaFiles([baseDirectory])
        where !known.contains(MediaFormats.canonicalFileURL(url).path) {
            report.extra.append(relativePath(of: url, to: baseDirectory))
        }
        return report
    }

    /// Prüft ein Archiv vollständig und liefert seine Ziel-URLs in einer
    /// einheitlichen Form. Die App kann damit vor dem ersten Schreibzugriff
    /// feststellen, welche bereits geöffneten Editoren betroffen wären.
    /// Auch fehlende Ziele stehen in der Liste: Sie sind Teil des Archivs,
    /// können aber naturgemäß keinem geöffneten Eintrag entsprechen.
    public static func validatedTargets(_ archive: TagArchive,
                                        relativeTo baseDirectory: URL,
                                        allowExternalTargets: Bool = false) throws -> [URL] {
        try validate(archive)
        return try validateResolvedEntries(
            archive, relativeTo: baseDirectory,
            allowExternalTargets: allowExternalTargets
        )
    }

    /// Aus einer bereits vollständig aufgelösten Zielliste die Ziele außerhalb
    /// des Archivordners bestimmen. CLI/App zeigen diese Liste vor der Freigabe.
    public static func externalTargets(_ targets: [URL],
                                       relativeTo baseDirectory: URL) -> [URL] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        return targets.filter { !isDescendant($0, of: canonicalBase) }
    }

    /// Wendet einen Eintrag an; true = Datei wurde (bzw. würde) geändert.
    private static func applyEntry(_ entry: TagArchive.Entry, to url: URL,
                                   dryRun: Bool) throws -> Bool {
        switch entry.kind {
        case .audio:
            let current = try TagFile.read(at: url)
            // validate(_:) garantiert diese Pflichtangabe. Das unwrap verhindert
            // trotzdem, dass ein späterer Refactor nil als "alle Tags löschen"
            // missversteht.
            guard let targetProperties = entry.properties else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "properties")
            }
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
            guard let target = entry.ebook else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "ebook")
            }
            let fieldsDiffer = target != current
            let targetArtworks = EbookTool.supportsCover(url: url) ? entry.artworks : nil
            let targetCover = targetArtworks?.first
            let currentCover = targetArtworks == nil ? nil : try EbookTool.readCover(url: url)
            // nil: Cover wurden nicht archiviert und bleiben deshalb unangetastet.
            // []: Das Archiv verlangt ausdrücklich, ein vorhandenes Cover zu entfernen.
            let coverDiffers = targetArtworks.map { _ in
                currentCover?.data != targetCover?.data
            } ?? false
            guard fieldsDiffer || coverDiffers else { return false }
            if !dryRun {
                let coverUpdate: EbookCoverUpdate
                if !coverDiffers {
                    coverUpdate = .unchanged
                } else if let targetCover {
                    coverUpdate = .set(targetCover.data)
                } else {
                    coverUpdate = .remove
                }
                try EbookTool.write(
                    url: url, fields: target, original: current,
                    coverUpdate: coverUpdate)
            }
            return true
        }
    }

    // MARK: - Helfer

    /// Prüft das Schema unabhängig vom späteren Zielordner. Die Prüfung muss
    /// auch in apply(_:) liegen, weil die App/Tests Archive direkt erzeugen
    /// können und damit load(_:) umgehen würden.
    public static func validate(_ archive: TagArchive) throws {
        guard supportedVersions.contains(archive.version) else {
            throw TagArchiveError.unsupportedVersion(archive.version)
        }

        var paths: Set<String> = []
        for entry in archive.files {
            guard !entry.path.isEmpty else {
                throw TagArchiveError.inconsistentEntry(path: entry.path, detail: "path is empty")
            }
            guard paths.insert(entry.path).inserted else {
                throw TagArchiveError.inconsistentEntry(path: entry.path, detail: "path appears more than once")
            }

            switch entry.kind {
            case .audio:
                guard entry.properties != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "properties")
                }
                guard entry.image == nil, entry.ebook == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "audio entries may not contain image or ebook data")
                }
            case .image:
                guard entry.image != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "image")
                }
                guard entry.properties == nil, entry.ebook == nil, entry.artworks == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "image entries may only contain image data")
                }
            case .ebook:
                guard entry.ebook != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "ebook")
                }
                guard entry.properties == nil, entry.image == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "ebook entries may not contain properties or image data")
                }
                guard (entry.artworks?.count ?? 0) <= 1 else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "ebook entries may contain at most one cover")
                }
            }
        }
    }

    /// Prüft zusätzlich den bereits vorhandenen Zielbestand. Erst hier ist
    /// erkennbar, ob ein E-Book-Eintrag auf ein PDF zeigt: PDFs besitzen keine
    /// Cover, daher wäre selbst ein leeres Cover-Array dort widersprüchlich.
    /// Diese Vorprüfung bleibt vor der Import-Schleife und damit vor jeder Mutation.
    private static func validateResolvedEntries(
        _ archive: TagArchive,
        relativeTo baseDirectory: URL,
        allowExternalTargets: Bool
    ) throws -> [URL] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        var identities: [FileIdentity] = []
        var targets: [URL] = []
        for entry in archive.files {
            let url = MediaFormats.canonicalFileURL(
                resolve(path: entry.path, in: baseDirectory)
            )
            guard allowExternalTargets || isDescendant(url, of: canonicalBase) else {
                throw TagArchiveError.externalTargetRequiresApproval(
                    path: entry.path, resolvedPath: url.path)
            }
            targets.append(url)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard MediaFormats.kind(of: url) == entry.kind else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "target media type does not match the archive entry")
            }
            // Zwei verschiedene Archivpfade können über Symlinks auf dieselbe
            // Datei zeigen. Vor der ersten Mutation muss deshalb die zentrale
            // kanonische Dateidentität verglichen werden, nicht nur der Text
            // des jeweiligen relativen Pfads.
            let identity = FileIdentity(url)
            guard !identities.contains(where: { $0.matches(identity) }) else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "different paths resolve to the same target")
            }
            identities.append(identity)
            if entry.kind == .ebook, let artworks = entry.artworks {
                guard EbookTool.supportsCover(url: url) else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "the target ebook format does not support covers")
                }
                guard !artworks.isEmpty || EbookTool.supportsCoverRemoval(url: url) else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path,
                        detail: "the target ebook backend cannot safely remove covers")
                }
            }
        }
        return targets
    }

    private static func isDescendant(_ target: URL, of base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return target.standardizedFileURL.path.hasPrefix(prefix)
    }

    /// Stellt vor dem Lesen sicher, dass das atomar geschriebene JSON nicht
    /// dieselbe Datei wie ein Eingabemedium ersetzt. Kanonische Pfade decken
    /// relative Pfade und Symlinks ab; dev/inode erkennt vorhandene Hardlinks.
    public static func validateExportDestination(files: [URL], destination: URL) throws {
        let destinationIdentity = FileIdentity(destination)
        for file in files {
            if destinationIdentity.matches(FileIdentity(file)) {
                throw TagArchiveError.exportDestinationMatchesInput(
                    input: file.path, destination: destination.path)
            }
        }
    }

    /// Identität einer Datei ohne Dateiinhalte zu lesen. Ein nicht vorhandenes
    /// Ziel hat nur einen kanonischen Pfad; ein Hardlink kann erst verglichen
    /// werden, wenn beide Pfade bereits existieren.
    private struct FileIdentity {
        let canonicalPath: String
        let device: UInt64?
        let inode: UInt64?

        init(_ url: URL) {
            canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            var status = stat()
            if stat(url.path, &status) == 0 {
                device = UInt64(status.st_dev)
                inode = UInt64(status.st_ino)
            } else {
                device = nil
                inode = nil
            }
        }

        func matches(_ other: FileIdentity) -> Bool {
            if canonicalPath == other.canonicalPath { return true }
            return device != nil && device == other.device && inode != nil && inode == other.inode
        }
    }

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

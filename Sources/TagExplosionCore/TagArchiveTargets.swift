import Foundation

extension TagArchiveIO {
    /// Quelldateien bleiben den Archiveinträgen zugeordnet; die Zugriffsliste
    /// enthält zusätzlich Sidecars und dient Freigabe und Konfliktschutz.
    public struct TargetPlan: Sendable {
        public let sourcesByArchivePath: [String: URL]
        public let accessURLsByArchivePath: [String: [URL]]
        public let accessURLs: [URL]
    }

    /// Prüft ein Archiv vollständig und liefert seine Ziel-URLs in einer
    /// einheitlichen Form. Die App kann damit vor dem ersten Schreibzugriff
    /// feststellen, welche bereits geöffneten Editoren betroffen wären.
    /// Auch fehlende Ziele stehen in der Liste: Sie sind Teil des Archivs,
    /// können aber naturgemäß keinem geöffneten Eintrag entsprechen.
    public static func validatedTargets(_ archive: TagArchive,
                                        relativeTo baseDirectory: URL,
                                        allowExternalTargets: Bool = false) throws -> [URL] {
        try validatedTargetPlan(archive, relativeTo: baseDirectory,
                                allowExternalTargets: allowExternalTargets).accessURLs
    }

    public static func validatedTargetPlan(_ archive: TagArchive,
                                           relativeTo baseDirectory: URL,
                                           allowExternalTargets: Bool = false) throws -> TargetPlan {
        try validate(archive)
        let targets = try validateResolvedEntries(
            archive, relativeTo: baseDirectory,
            allowExternalTargets: allowExternalTargets
        )
        return TargetPlan(
            sourcesByArchivePath: Dictionary(uniqueKeysWithValues: zip(archive.files.map(\.path), targets.map(\.url))),
            accessURLsByArchivePath: Dictionary(uniqueKeysWithValues: zip(archive.files.map(\.path), targets.map(\.accessURLs))),
            accessURLs: targets.flatMap(\.accessURLs))
    }

    /// Aus einer bereits vollständig aufgelösten Zielliste die Ziele außerhalb
    /// des Archivordners bestimmen. CLI/App zeigen diese Liste vor der Freigabe.
    public static func externalTargets(_ targets: [URL],
                                       relativeTo baseDirectory: URL) -> [URL] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        return targets.filter { !isDescendant($0, of: canonicalBase) }
    }

    /// Prüft zusätzlich den bereits vorhandenen Zielbestand. Erst hier ist
    /// erkennbar, ob ein E-Book-Eintrag auf ein PDF zeigt: PDFs besitzen keine
    /// Cover, daher wäre selbst ein leeres Cover-Array dort widersprüchlich.
    /// Diese Vorprüfung bleibt vor der Import-Schleife und damit vor jeder Mutation.
    static func validateResolvedEntries(
        _ archive: TagArchive,
        relativeTo baseDirectory: URL,
        allowExternalTargets: Bool,
        validateCapabilities: Bool = true
    ) throws -> [ValidatedTarget] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        var canonicalPaths: Set<String> = []
        var diskIdentities: Set<DiskIdentity> = []
        // Auch fehlende Ziele haben einen Pfad; bei vorhandenen Dateien
        // fängt die zweite Menge zusätzlich Hardlinks ab.
        func insertTargetIdentity(_ identity: FileIdentity) -> Bool {
            let uniquePath = canonicalPaths.insert(identity.canonicalPath).inserted
            let uniqueFile = identity.diskIdentity.map { diskIdentities.insert($0).inserted } ?? true
            return uniquePath && uniqueFile
        }

        var targets: [ValidatedTarget] = []
        for entry in archive.files {
            let url = MediaFormats.canonicalFileURL(
                resolve(path: entry.path, in: baseDirectory)
            )
            guard allowExternalTargets || isDescendant(url, of: canonicalBase) else {
                throw TagArchiveError.externalTargetRequiresApproval(
                    path: entry.path, resolvedPath: url.path)
            }
            let exists = FileManager.default.fileExists(atPath: url.path)
            let stamp = exists ? FileStamp.current(of: url) : nil
            if exists && stamp == nil { throw TagError.cannotOpen(path: url.path) }

            // Pfad und Identität werden in derselben Validierungsrunde erfasst
            // und gemeinsam bis zum Schreibweg getragen. Ein später frisch
            // erhobener Stempel könnte bereits zu einer untergeschobenen Datei
            // gehören und wäre als Ausgangsbeweis wertlos.
            guard insertTargetIdentity(FileIdentity(url, validatedStamp: stamp)) else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "different paths resolve to the same target")
            }
            var destination: ImageWriteDestination?
            var destinationState: FileState = .unknown
            if entry.kind == .image, exists {
                let chosen = ExifTool.writeDestination(for: url, preferSidecar: false)
                let canonical = MediaFormats.canonicalFileURL(chosen.url)
                destinationState = FileState.current(of: chosen.url)
                guard allowExternalTargets || isDescendant(canonical, of: canonicalBase) else {
                    throw TagArchiveError.externalTargetRequiresApproval(path: entry.path, resolvedPath: canonical.path)
                }
                destination = ImageWriteDestination(url: canonical, reason: chosen.reason)
                if canonical != url, !insertTargetIdentity(FileIdentity(canonical)) {
                    throw TagArchiveError.inconsistentEntry(path: entry.path, detail: "different entries share a write target")
                }
            }
            targets.append(ValidatedTarget(url: url, stamp: stamp, destination: destination, destinationState: destinationState))

            guard exists && validateCapabilities else { continue }
            guard MediaFormats.kind(of: url) == entry.kind else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "target media type does not match the archive entry")
            }
            if entry.kind == .audio {
                let file = try TagFile(url: url)
                defer { file.close() }
                if entry.chapters != nil, !file.supportsChapters { throw TagError.chaptersUnsupported(path: url.path) }
                if entry.syncedLyrics != nil || entry.lyricsLanguage != nil || entry.syncedLyricsLanguage != nil,
                   !file.supportsSyncedLyrics { throw TagError.syncedLyricsUnsupported(path: url.path) }
            }
            if entry.kind == .ebook, let artworks = entry.artworks {
                guard EbookTool.supportsCover(url: url) else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "the target ebook format does not support covers")
                }
                // Ein bereits coverfreies Buch erfüllt den leeren Sollzustand.
                // Nur eine tatsächlich erforderliche Löschung braucht Backend-Unterstützung.
                if artworks.isEmpty, !EbookTool.supportsCoverRemoval(url: url),
                   try EbookTool.readCover(url: url) != nil {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path,
                        detail: "the target ebook backend cannot safely remove covers")
                }
            }
            // PDF und AZW3 haben keinen verlässlich schreibbaren Serien-Ort.
            // Ein Archiv mit Serienwunsch für diese Formate würde deshalb
            // "Erfolg" melden, ohne den Wert zu schreiben — besser vorab
            // ablehnen (dieselbe Regel wie `tagx ebook set`).
            if entry.kind == .ebook, let ebook = entry.ebook,
               !EbookTool.supportsSeries(url: url),
               !ebook.series.isEmpty || !ebook.seriesIndex.isEmpty {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path,
                    detail: "the target ebook format cannot store a series")
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
            if destinationIdentity.resolvesToSameTarget(as: FileIdentity(file)) {
                throw TagArchiveError.exportDestinationMatchesInput(
                    input: file.path, destination: destination.path)
            }
        }
    }

    struct ValidatedTarget {
        let url: URL
        /// nil bedeutet: Das Ziel fehlte während der vollständigen Vorprüfung.
        let stamp: FileStamp?
        let destination: ImageWriteDestination?
        let destinationState: FileState

        var accessURLs: [URL] {
            guard let destination, destination.url != url else { return [url] }
            return [url, destination.url]
        }

        func requireCurrentDestination() throws {
            guard let destination else { return }
            let current = ExifTool.writeDestination(for: url, preferSidecar: false)
            guard current.reason == destination.reason,
                  MediaFormats.canonicalFileURL(current.url) == destination.url else {
                throw TagArchiveError.targetChangedAfterValidation(path: url.path)
            }
            try destinationState.requireUnchanged(at: current.url)
        }
    }

    private struct DiskIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// Ein fehlendes Ziel hat nur einen Pfad. Hardlinks lassen sich erst
    /// vergleichen, wenn beide Dateien existieren.
    private struct FileIdentity {
        let canonicalPath: String
        let stamp: FileStamp?

        var diskIdentity: DiskIdentity? {
            guard let device = stamp?.device, let inode = stamp?.inode else { return nil }
            return DiskIdentity(device: device, inode: inode)
        }

        init(_ url: URL) {
            canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            stamp = FileStamp.current(of: url)
        }

        init(_ url: URL, validatedStamp: FileStamp?) {
            canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
            stamp = validatedStamp
        }

        /// Zwei Pfade bezeichnen dasselbe Ziel, wenn ihr kanonischer Pfad
        /// gleich ist ODER beide vorhandenen Dateien dieselbe Inode besitzen.
        /// Diese Ziel-Deduplizierung ist bewusst etwas anderes als die Frage,
        /// ob eine Datei seit der Prüfung unverändert blieb: Dort darf derselbe
        /// Pfad niemals eine neue Inode legitimieren.
        func resolvesToSameTarget(as other: FileIdentity) -> Bool {
            if canonicalPath == other.canonicalPath { return true }
            guard let stamp, let otherStamp = other.stamp else { return false }
            return stamp.hasSameFileIdentity(as: otherStamp)
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

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
    case targetChangedAfterValidation(path: String)
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
        case .targetChangedAfterValidation(let path):
            return "Archive target \(path) is no longer the file that was checked. It was not written."
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
                    let data = try FileSnapshot.capture(at: url) {
                        try TagFile.read(at: url)
                    }.value
                    entry.properties = propertyMap(data.properties)
                    // [] bedeutet bewusst: Es wurde nach Covern gesucht, aber
                    // keines gefunden. nil bleibt für --without-covers reserviert.
                    entry.artworks = data.artworks
                } else {
                    // Ohne Cover reicht die PropertyMap — erspart das
                    // Extrahieren aller eingebetteten Bilder.
                    entry.properties = try FileSnapshot.capture(at: url) {
                        let file = try TagFile(url: url)
                        defer { file.close() }
                        return propertyMap(try file.properties())
                    }.value
                }
            case .image:
                entry.image = try ExifTool.readCoreFieldsSnapshot(url: url).value
            case .ebook:
                let readsCover = includeCovers && EbookTool.supportsCover(url: url)
                let snapshot = try EbookTool.readSnapshot(
                    url: url, includeCover: readsCover)
                entry.ebook = snapshot.value.fields
                if readsCover {
                    // Lesefehler nicht als "kein Cover" umdeuten: Sonst könnte
                    // ein späterer Import ein vorhandenes Cover löschen.
                    entry.artworks = snapshot.value.cover.map { [$0] } ?? []
                }
            case .invoice:
                // E-Rechnungen sind reine Anzeige — es gibt keine editierbaren
                // Tags, die ein Archiv sichern oder wiederherstellen könnte.
                continue
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
        // Ein Archiv, das der eigene Import nicht mehr annimmt, wäre als
        // Sicherung wertlos. Deshalb hier dieselbe strukturelle Prüfung wie
        // beim Laden: lieber laut scheitern als eine nicht wiederherstellbare
        // Sicherung anlegen. Bewusst nur STRUKTURELL: Fachfremde Bestandswerte
        // (etwa eine exiftool-lesbare GPS-Koordinate 91/181) gehören mit ins
        // Backup; ob sie in ein ZIEL geschrieben werden dürfen, entscheidet
        // erst der Import gegen dessen tatsächlichen Zustand.
        try validate(archive)
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
            // Der Zeitstempel ist nur sekundengenau: Zwei Backups desselben
            // Ordners innerhalb einer Sekunde wählen sonst denselben Namen und
            // der atomare Export überschriebe still den ersten Stand. Deshalb
            // wird der Name exklusiv reserviert (O_EXCL) und bei Kollision
            // hochgezählt.
            let target = try reserveBackupFile(in: folder, stamp: stamp)
            do {
                try export(files: urls, to: target, includeCovers: true)
            } catch {
                // Die leere Reservierung wieder entfernen — eine 0-Byte-Datei
                // wäre sonst ein scheinbares, aber unbrauchbares Backup.
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            written.append(target)
        }
        return written
    }

    /// Reserviert exklusiv einen freien Backup-Dateinamen im Ordner
    /// (`tags-backup-<stamp>.json`, bei Kollision `…-2.json`, `…-3.json` …).
    private static func reserveBackupFile(in folder: URL, stamp: String) throws -> URL {
        var counter = 1
        while counter <= 1000 {
            let name = counter == 1
                ? "tags-backup-\(stamp).json"
                : "tags-backup-\(stamp)-\(counter).json"
            let candidate = folder.appendingPathComponent(name)
            do {
                // .withoutOverwriting = O_EXCL: legt die Datei nur an, wenn es
                // sie noch nicht gibt — atomar, auch gegenüber Fremdprozessen.
                try Data().write(to: candidate, options: .withoutOverwriting)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                counter += 1
            }
        }
        throw TagError.saveFailed(path: folder.path)
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
    ///
    /// `approvedTargets` muss unverändert die Ausgabe von `validatedTargets`
    /// sein — die Liste, mit der der Aufrufer gearbeitet hat (angezeigte
    /// Freigabe in CLI/App, Ermittlung betroffener offener Editoren). Sie wird
    /// hier wörtlich mit den frisch aufgelösten Zielen verglichen. Auch ein
    /// Import ganz ohne externe Ziele sollte sie mitgeben: Sonst kann ein
    /// zwischenzeitlich umgebogener Symlink auf eine andere, nie geprüfte
    /// Datei zeigen und der Import schriebe sie trotzdem.
    ///
    /// `allowExternalTargets` bleibt davon unabhängig: Ziele außerhalb des
    /// Archivordners brauchen weiterhin eine ausdrückliche Freigabe.
    public static func apply(_ archive: TagArchive, relativeTo baseDirectory: URL,
                             dryRun: Bool, approvedTargets: [URL]? = nil,
                             allowExternalTargets: Bool = false) throws
    -> TagArchiveReport {
        try apply(
            archive, relativeTo: baseDirectory, dryRun: dryRun,
            approvedTargets: approvedTargets,
            allowExternalTargets: allowExternalTargets, afterValidation: {},
            beforeNoopReturn: { _ in })
    }

    /// Testbarer Kern: Der Hook liegt exakt nach Ziel-/Identitätsprüfung und
    /// vor dem ersten Read. Produktive Aufrufer verwenden den öffentlichen
    /// Overload ohne Hook.
    static func apply(
        _ archive: TagArchive,
        relativeTo baseDirectory: URL,
        dryRun: Bool,
        approvedTargets: [URL]? = nil,
        allowExternalTargets: Bool = false,
        afterValidation: () throws -> Void,
        beforeNoopReturn: (URL) throws -> Void = { _ in }
    ) throws -> TagArchiveReport {
        // Die gesamte Datei wird vor der Schleife geprüft. Damit kann kein
        // fehlerhafter Eintrag nach einer schon geschriebenen Datei auffallen.
        // Ein zuvor in CLI/App angezeigter externer Pfad wird hier unmittelbar
        // vor den Mutationen nochmals vollständig aufgelöst und geprüft.
        try validate(archive)
        let validated = try validateResolvedEntries(
            archive, relativeTo: baseDirectory,
            allowExternalTargets: allowExternalTargets
        )
        let targets = validated.map(\.url)
        if let approvedTargets {
            // Bewusst KEINE erneute Kanonisierung der freigegebenen Pfade: Sie
            // sind der beim Bestätigen angezeigte, bereits vollständig
            // aufgelöste Stand (Ausgabe von `validatedTargets`). Würde man sie
            // hier nochmals auflösen, könnte ein zwischenzeitlich
            // untergeschobener Symlink beide Seiten auf DASSELBE neue Ziel
            // ziehen — die Gleichheitsprüfung wäre dann wirkungslos und ein
            // nie angezeigtes Ziel würde überschrieben.
            guard approvedTargets == targets else {
                throw TagArchiveError.approvedTargetListChanged
            }
        }
        try afterValidation()

        var report = TagArchiveReport()
        for (entry, target) in zip(archive.files, validated) {
            let url = target.url
            guard let validatedStamp = target.stamp else {
                report.missing.append(entry.path)
                continue
            }
            do {
                guard let current = FileStamp.current(of: url),
                      current.hasSameFileIdentity(as: validatedStamp) else {
                    // Bewusst nur dieser Eintrag: Die übrigen Ziele werden
                    // einzeln genauso geprüft, und der Bericht soll weiterhin
                    // zeigen, was tatsächlich geschrieben wurde.
                    throw TagArchiveError.targetChangedAfterValidation(path: entry.path)
                }
                if try applyEntry(
                    entry, to: url, dryRun: dryRun, expecting: validatedStamp,
                    beforeNoopReturn: beforeNoopReturn) {
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
        ).map(\.url)
    }

    /// Aus einer bereits vollständig aufgelösten Zielliste die Ziele außerhalb
    /// des Archivordners bestimmen. CLI/App zeigen diese Liste vor der Freigabe.
    public static func externalTargets(_ targets: [URL],
                                       relativeTo baseDirectory: URL) -> [URL] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        return targets.filter { !isDescendant($0, of: canonicalBase) }
    }

    /// Wendet einen Eintrag an; true = Datei wurde (bzw. würde) geändert.
    private static func applyEntry(
        _ entry: TagArchive.Entry,
        to url: URL,
        dryRun: Bool,
        expecting stamp: FileStamp,
        beforeNoopReturn: (URL) throws -> Void
    ) throws -> Bool {
        switch entry.kind {
        case .audio:
            let snapshot = try FileSnapshot.capture(at: url, expecting: stamp) {
                try TagFile.read(at: url)
            }
            let current = snapshot.value
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
            guard propertiesDiffer || artworksDiffer else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try TrashBackup.shared.backUp(url)
                try TagFile.write(properties: propertyList(targetProperties),
                                  artworks: targetArtworks ?? current.artworks, to: url,
                                  expecting: snapshot.stamp)
            }
            return true
        case .image:
            let snapshot = try ExifTool.readCoreFieldsSnapshot(
                url: url, expecting: stamp)
            let current = snapshot.value
            guard let target = entry.image, target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Zielbezogene Wertprüfung VOR Dry-run-Antwort und Sicherung:
            // Fachfremde Bestandswerte (z.B. GPS 91/181) sind erlaubt, solange
            // dieser Import sie nicht ändert. Eine echte Änderung auf
            // ungültige Werte scheitert damit im Dry-run und im Import gleich —
            // und ohne dass vorher eine Papierkorb-Sicherung entsteht.
            try ExifTool.requireValidCoreFields(target, original: current)
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try TrashBackup.shared.backUp(url)
                try ExifTool.writeCoreFields(url: url, fields: target, original: current,
                                             expecting: snapshot.stamp)
            }
            return true
        case .ebook:
            guard let target = entry.ebook else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "ebook")
            }
            let targetArtworks = EbookTool.supportsCover(url: url) ? entry.artworks : nil
            let snapshot = try EbookTool.readSnapshot(
                url: url, includeCover: targetArtworks != nil, expecting: stamp)
            let current = snapshot.value.fields
            let fieldsDiffer = target != current
            let targetCover = targetArtworks?.first
            let currentCover = snapshot.value.cover
            // nil: Cover wurden nicht archiviert und bleiben deshalb unangetastet.
            // []: Das Archiv verlangt ausdrücklich, ein vorhandenes Cover zu entfernen.
            let coverDiffers = targetArtworks.map { _ in
                currentCover?.data != targetCover?.data
            } ?? false
            guard fieldsDiffer || coverDiffers else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Wie beim Bild: Was das Ziel-Backend nicht schreiben kann
            // (Serienindex ohne Serie außerhalb von EPUB, Coverformat außerhalb
            // des Backend-Vertrags), scheitert für Dry-run und Import gleich —
            // vor der Papierkorb-Sicherung, nicht erst mitten im Schreibweg.
            try EbookTool.requireStorableSeries(target, original: current, url: url)
            if coverDiffers, let targetCover {
                try EbookTool.requireSupportedCover(targetCover.data, for: url)
            }
            if !dryRun {
                let coverUpdate: EbookCoverUpdate
                if !coverDiffers {
                    coverUpdate = .unchanged
                } else if let targetCover {
                    coverUpdate = .set(targetCover.data)
                } else {
                    coverUpdate = .remove
                }
                try snapshot.requireCurrent(at: url)
                try TrashBackup.shared.backUp(url)
                try EbookTool.write(
                    url: url, fields: target, original: current,
                    coverUpdate: coverUpdate, expecting: snapshot.stamp)
            }
            return true
        case .invoice:
            // Export erzeugt solche Einträge nie (build überspringt sie);
            // ein handgebautes Archiv mit Rechnungseintrag ist fehlerhaft.
            throw TagArchiveError.inconsistentEntry(
                path: entry.path, detail: "invoices are display-only and cannot be archived")
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
                guard let properties = entry.properties else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "properties")
                }
                // Eine vollständige PropertyMap stellt ein fehlendes Feld dar,
                // indem der Schlüssel gar nicht vorkommt. Eine vorhandene,
                // aber leere Wertliste kann `propertyList` nicht schreiben und
                // würde deshalb bei jedem späteren Import erneut als Änderung
                // erscheinen. Solche Archive vor der ersten Batch-Mutation
                // ablehnen statt einen unerreichbaren Soll-Zustand zu dulden.
                if let emptyKey = properties.keys.sorted().first(
                    where: { properties[$0]?.isEmpty == true }
                ) {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path,
                        detail: "audio property \(emptyKey) has no values")
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
                // Wertebereiche (Bewertung, GPS) werden hier bewusst NICHT
                // geprüft: exiftool liest auch fachlich unmögliche Werte wie
                // GPS 91/181 aus bestehenden Bildern, und ein Backup muss
                // genau diesen Bestand sichern können — sonst bricht das
                // Auto-Backup jeden Batch-Save ab. Ob ein Wert ins ZIEL
                // geschrieben werden darf, prüft der Import je Eintrag gegen
                // den vorher gelesenen Zielstand (applyEntry), bevor eine
                // Sicherung entsteht.
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
                // Ein Serienindex ohne Serie wird hier bewusst NICHT abgelehnt:
                // Bestehende EPUBs können genau diesen Zustand tragen
                // (calibre:series_index ohne Serie), Export muss ihn sichern
                // können, ältere v1-Archive enthalten ihn bereits — und der
                // EPUB-Schreibweg kann ihn wiederherstellen. Nur für Ziele
                // ohne diesen Speicherort (mobi/azw3/fb2) meldet der Import
                // ihn je Eintrag als Fehler (EbookTool.requireStorableSeries),
                // nie still verloren.
                //
                // Cover werden vor dem ersten Schreibzugriff an ihrer Signatur
                // geprüft — sonst landete beliebiger Inhalt als angebliches
                // Bild im E-Book. Zugelassen ist jedes erkennbare Bildformat:
                // EPUBs können z.B. gültige GIF-Cover enthalten, die Export
                // und ältere v1-Archive erhalten müssen. Was das ZIEL-Backend
                // beim tatsächlichen Cover-SETZEN annimmt, prüft der Import je
                // Eintrag (EbookTool.requireSupportedCover, backendbezogen).
                if let cover = entry.artworks?.first {
                    guard Artwork.sniffMimeType(from: cover.data) != nil else {
                        throw TagArchiveError.inconsistentEntry(
                            path: entry.path,
                            detail: "ebook cover data is not a recognizable image")
                    }
                }
            case .invoice:
                // Der Export erzeugt solche Einträge nie; ein Archiv, das
                // welche enthält, ist von Hand gebaut und fehlerhaft.
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path,
                    detail: "invoices are display-only and cannot be archived")
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
    ) throws -> [ValidatedTarget] {
        let canonicalBase = MediaFormats.canonicalFileURL(baseDirectory)
        var identities: [FileIdentity] = []
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
            let identity = FileIdentity(url, validatedStamp: stamp)
            guard !identities.contains(where: { $0.resolvesToSameTarget(as: identity) }) else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "different paths resolve to the same target")
            }
            identities.append(identity)
            targets.append(ValidatedTarget(url: url, stamp: stamp))

            guard exists else { continue }
            guard MediaFormats.kind(of: url) == entry.kind else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "target media type does not match the archive entry")
            }
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
            // PDF kennt keinen Serien-Ort; das Backend ignoriert Serienfelder
            // still. Ein Archiv mit Serienwunsch für ein PDF würde deshalb
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

    /// Identität einer Datei ohne Dateiinhalte zu lesen. Ein nicht vorhandenes
    /// Ziel hat nur einen kanonischen Pfad; ein Hardlink kann erst verglichen
    /// werden, wenn beide Pfade bereits existieren.
    private struct ValidatedTarget {
        let url: URL
        /// nil bedeutet: Das Ziel fehlte während der vollständigen Vorprüfung.
        let stamp: FileStamp?
    }

    private struct FileIdentity {
        let canonicalPath: String
        let stamp: FileStamp?

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

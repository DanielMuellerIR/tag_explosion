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
        /// Dokumente (Office, OpenDocument, CBZ, Markdown): Kernfelder. Das
        /// CBZ-Cover ist reine Anzeige und wird nicht archiviert.
        public var document: DocumentCoreFields?
        /// Kodi-/Jellyfin-NFO (`kind: sidecar`): Felder der NFO. Untertitel
        /// und Nur-URL-NFOs haben keine archivierbaren Felder und fehlen.
        public var nfo: NFOFields?

        public init(path: String, kind: MediaFormats.Kind,
                    properties: [String: [String]]? = nil,
                    artworks: [Artwork]? = nil,
                    image: ImageCoreFields? = nil,
                    ebook: EbookCoreFields? = nil,
                    document: DocumentCoreFields? = nil,
                    nfo: NFOFields? = nil) {
            self.path = path
            self.kind = kind
            self.properties = properties
            self.artworks = artworks
            self.image = image
            self.ebook = ebook
            self.document = document
            self.nfo = nfo
        }
    }

    /// Aktuelles Schema. 2 unterscheidet beim Bild-Rating „kein Tag" (Feld
    /// fehlt beziehungsweise null) von „Tag mit dem Wert −1"; in Schema 1
    /// stand −1 für beides. 3 ergänzt Dokument-Einträge (`kind: document`,
    /// Feld `document`) — ältere Programmstände lehnen ein solches Archiv
    /// damit mit einer klaren Versionsmeldung ab statt mit einem Decodierfehler.
    /// 4 ergänzt NFO-Einträge (`kind: sidecar`, Feld `nfo`).
    public static let currentVersion = 4

    public init(version: Int = TagArchive.currentVersion, created: String, files: [Entry]) {
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

    /// Verstandene Archivschemata. Neue Schemata dürfen nicht versehentlich
    /// wie alte gelesen werden, weil dabei Felder verloren gehen könnten.
    /// Schema 1 wird weiterhin importiert und beim Lesen umgerechnet, siehe
    /// `normalizingLegacyValues`; Schema 2 unterscheidet sich von 3 nur durch
    /// das Fehlen von Dokument-Einträgen und wird unverändert gelesen.
    private static let supportedVersions: Set<Int> = [1, 2, 3, TagArchive.currentVersion]

    /// Rechnet ein Archiv des alten Schemas auf die heutige Bedeutung um.
    ///
    /// Schema 1 kannte für das Bild-Rating nur `Int`, und −1 hieß dort „die
    /// Datei trug gar kein Rating-Tag" — ein echtes Rating −1 („abgelehnt")
    /// konnte gar nicht im Archiv landen, weil schon die Leseseite beides auf
    /// −1 abbildete. Genau so wird es deshalb wiederhergestellt; ohne diese
    /// Umrechnung schriebe ein alter Bestand plötzlich ein −1-Tag in Dateien,
    /// die vorher keines hatten (Review-Fund 2026-08-20).
    static func normalizingLegacyValues(_ archive: TagArchive) -> TagArchive {
        guard archive.version == 1 else { return archive }
        var archive = archive
        for index in archive.files.indices where archive.files[index].image?.rating == -1 {
            archive.files[index].image?.rating = nil
        }
        return archive
    }

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
                // Gesichert wird der zusammengeführte Stand (Sidecar überlagert
                // eingebettete Werte) — genau das, was die Oberfläche zeigt.
                entry.image = try ExifTool.readCoreFieldsSnapshot(url: url).value.fields
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
            case .document:
                // Ohne Cover: Das CBZ-Cover ist die erste Seite und hat keinen
                // Schreibweg — ein Archiv könnte es nie wiederherstellen.
                entry.document = try DocumentTool.readSnapshot(
                    url: url, includeCover: false).value.fields
            case .sidecar:
                // Nur NFO-Felder; Untertitel und Nur-URL-NFOs tragen nichts,
                // was ein Archiv wiederherstellen könnte (Regel: isArchivable(url:)).
                guard SidecarTool.isNFO(url) else { continue }
                let contents = try KodiNFOFile.readSnapshot(url: url).value
                guard !contents.isURLOnly else { continue }
                entry.nfo = contents.fields
            case .invoice, .playlist:
                // E-Rechnungen sind reine Anzeige — es gibt keine editierbaren
                // Tags, die ein Archiv sichern oder wiederherstellen könnte.
                // Playlists beschriften fremde Dateien (siehe isArchivable).
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
        return normalizingLegacyValues(archive)
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
            beforeNoopReturn: { _ in },
            backUp: { try TrashBackup.shared.backUp($0) })
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
        beforeNoopReturn: (URL) throws -> Void = { _ in },
        backUp: (URL) throws -> Void = { try TrashBackup.shared.backUp($0) }
    ) throws -> TagArchiveReport {
        // Die gesamte Datei wird vor der Schleife geprüft. Damit kann kein
        // fehlerhafter Eintrag nach einer schon geschriebenen Datei auffallen.
        // Ein zuvor in CLI/App angezeigter externer Pfad wird hier unmittelbar
        // vor den Mutationen nochmals vollständig aufgelöst und geprüft.
        try validate(archive)
        // Auch hier umrechnen, nicht nur in `load`: App und Tests bauen Archive
        // direkt und umgehen `load` damit.
        let archive = normalizingLegacyValues(archive)
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
                    beforeNoopReturn: beforeNoopReturn, backUp: backUp) {
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
        beforeNoopReturn: (URL) throws -> Void,
        backUp: (URL) throws -> Void
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
                try backUp(url)
                try TagFile.write(properties: propertyList(targetProperties),
                                  artworks: targetArtworks ?? current.artworks, to: url,
                                  expecting: snapshot.stamp)
            }
            return true
        case .image:
            let snapshot = try ExifTool.readCoreFieldsSnapshot(
                url: url, expecting: stamp)
            let current = snapshot.value.fields
            guard let target = entry.image, target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Der Archivweg schreibt auch beim Dry-run zuerst auf eine
            // Geschwisterkopie und liest sie exakt zurück. Damit meldet er
            // Normalisierungen wie 48.1000 → 48.1 vor einer Sicherung. Beim
            // echten Lauf setzt der atomare Rahmen genau diese geprüfte Kopie
            // ein, statt exiftool ein zweites Mal auszuführen.
            // Kamera-RAW und Bilder mit vorhandener Sidecar schreibt der Import
            // in die Sidecar; gesichert wird dann diese, nicht das Bild.
            let destination = ExifTool.writeDestination(for: url, preferSidecar: false)
            try ExifTool.writeArchivedCoreFields(
                url: url, fields: target, original: current,
                expecting: snapshot.stamp, to: destination,
                sidecar: snapshot.value.sidecar, dryRun: dryRun,
                beforeReplace: { try backUp(destination.url) })
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
                try backUp(url)
                try EbookTool.write(
                    url: url, fields: target, original: current,
                    coverUpdate: coverUpdate, expecting: snapshot.stamp)
            }
            return true
        case .document:
            guard let target = entry.document else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "document")
            }
            let snapshot = try DocumentTool.readSnapshot(
                url: url, includeCover: false, expecting: stamp)
            let current = snapshot.value.fields
            guard target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Was das Zielformat nicht speichern kann (Feld ohne Speicherort,
            // Datumsform), scheitert für Dry-run und Import gleich — vor der
            // Papierkorb-Sicherung.
            try DocumentTool.requireWritable(target, original: current, url: url)
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try DocumentTool.write(url: url, fields: target, original: current,
                                       expecting: snapshot.stamp)
            }
            return true
        case .sidecar:
            guard let target = entry.nfo else {
                throw TagArchiveError.incompleteEntry(
                    path: entry.path, kind: entry.kind, missing: "nfo")
            }
            let snapshot = try KodiNFOFile.readSnapshot(url: url, expecting: stamp)
            guard !snapshot.value.isURLOnly else { throw TagError.urlOnlyNFO(path: url.path) }
            let current = snapshot.value.fields
            guard target != current else {
                try beforeNoopReturn(url)
                try snapshot.requireCurrent(at: url)
                return false
            }
            // Unbrauchbare Werte (Jahr, Zahlen) scheitern vor der Sicherung.
            try KodiNFOFile.validate(target, original: current)
            if !dryRun {
                try snapshot.requireCurrent(at: url)
                try backUp(url)
                try KodiNFOFile.write(url: url, fields: target, original: current,
                                      expecting: snapshot.stamp)
            }
            return true
        case .invoice, .playlist:
            // Export erzeugt solche Einträge nie (build überspringt sie);
            // ein handgebautes Archiv mit Rechnungs-/Playlist-Eintrag ist fehlerhaft.
            throw TagArchiveError.inconsistentEntry(
                path: entry.path, detail: "invoices and playlists cannot be archived")
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

            if entry.kind != .sidecar, entry.nfo != nil {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "nfo data requires a sidecar entry")
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
                guard entry.image == nil, entry.ebook == nil, entry.document == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "audio entries may not contain image, ebook or document data")
                }
            case .image:
                guard entry.image != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "image")
                }
                guard entry.properties == nil, entry.ebook == nil, entry.artworks == nil,
                      entry.document == nil else {
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
                guard entry.properties == nil, entry.image == nil, entry.document == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "ebook entries may not contain properties, image or document data")
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
            case .document:
                guard entry.document != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "document")
                }
                guard entry.properties == nil, entry.image == nil, entry.ebook == nil,
                      entry.artworks == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "document entries may only contain document data")
                }
                // Ob das ZIEL jedes Feld speichern kann, entscheidet erst der
                // Import je Eintrag (DocumentTool.requireWritable) — ein
                // Backup muss den Bestand jeder Datei sichern können.
            case .sidecar:
                guard entry.nfo != nil else {
                    throw TagArchiveError.incompleteEntry(
                        path: entry.path, kind: entry.kind, missing: "nfo")
                }
                guard entry.properties == nil, entry.image == nil, entry.ebook == nil,
                      entry.document == nil, entry.artworks == nil else {
                    throw TagArchiveError.inconsistentEntry(
                        path: entry.path, detail: "sidecar entries may only contain nfo data")
                }
            case .invoice, .playlist:
                // Der Export erzeugt solche Einträge nie; ein Archiv, das
                // welche enthält, ist von Hand gebaut und fehlerhaft.
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path,
                    detail: "invoices and playlists cannot be archived")
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
        var canonicalPaths: Set<String> = []
        var diskIdentities: Set<DiskIdentity> = []
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
            // Jede Identität nur einmal nachschlagen, statt alle bisherigen
            // Ziele erneut zu vergleichen. Auch fehlende Ziele haben einen Pfad.
            let uniquePath = canonicalPaths.insert(identity.canonicalPath).inserted
            let uniqueFile = identity.diskIdentity.map { diskIdentities.insert($0).inserted } ?? true
            guard uniquePath && uniqueFile else {
                throw TagArchiveError.inconsistentEntry(
                    path: entry.path, detail: "different paths resolve to the same target")
            }
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

    private struct DiskIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

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

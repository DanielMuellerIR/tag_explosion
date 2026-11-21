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
        /// Audio-Details ab Schema 5; nil lässt den nicht archivierten Zustand stehen.
        public var chapters: [Chapter]?
        public var syncedLyrics: [SyncedLyricLine]?
        public var lyricsLanguage: String?
        public var syncedLyricsLanguage: String?
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
                    nfo: NFOFields? = nil, chapters: [Chapter]? = nil,
                    syncedLyrics: [SyncedLyricLine]? = nil, lyricsLanguage: String? = nil,
                    syncedLyricsLanguage: String? = nil) {
            self.path = path
            self.kind = kind
            self.properties = properties
            self.artworks = artworks
            self.image = image
            self.ebook = ebook
            self.document = document
            self.nfo = nfo
            self.chapters = chapters
            self.syncedLyrics = syncedLyrics
            self.lyricsLanguage = lyricsLanguage
            self.syncedLyricsLanguage = syncedLyricsLanguage
        }
    }

    /// Aktuelles Schema. 2 unterscheidet beim Bild-Rating „kein Tag" (Feld
    /// fehlt beziehungsweise null) von „Tag mit dem Wert −1"; in Schema 1
    /// stand −1 für beides. 3 ergänzt Dokument-Einträge (`kind: document`,
    /// Feld `document`) — ältere Programmstände lehnen ein solches Archiv
    /// damit mit einer klaren Versionsmeldung ab statt mit einem Decodierfehler.
    /// 4 ergänzt NFO-Einträge (`kind: sidecar`, Feld `nfo`).
    /// 5 ergänzt Kapitel und Lyrics einschließlich getrennter USLT-/SYLT-Sprachen.
    public static let currentVersion = 5

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
    public struct Failure: Codable, Sendable, Equatable {
        public let path: String
        public let message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Dateien, die geändert wurden (bzw. würden).
    public var applied: [String] = []
    /// Dateien, die bereits dem Archiv entsprechen.
    public var unchanged: [String] = []
    /// Archiv-Einträge ohne existierende Datei.
    public var missing: [String] = []
    /// Mediendateien unter dem JSON-Ordner, die nicht im Archiv stehen.
    public var extra: [String] = []
    /// Dateien, die nach der Vorprüfung nicht verarbeitet werden konnten.
    public var failed: [Failure] = []
}

public enum TagArchiveIO {
    /// Verstandene Archivschemata. Neue Schemata dürfen nicht versehentlich
    /// wie alte gelesen werden, weil dabei Felder verloren gehen könnten.
    /// Schema 1 wird weiterhin importiert und beim Lesen umgerechnet, siehe
    /// `normalizingLegacyValues`; Schema 2 unterscheidet sich von 3 nur durch
    /// das Fehlen von Dokument-Einträgen und wird unverändert gelesen.
    private static let supportedVersions: Set<Int> = [1, 2, 3, 4, TagArchive.currentVersion]

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

    public static func load(_ url: URL) throws -> TagArchive {
        let archive = try JSONDecoder().decode(TagArchive.self, from: Data(contentsOf: url))
        try validate(archive)
        return normalizingLegacyValues(archive)
    }

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

            let hasAudioDetails = entry.chapters != nil || entry.syncedLyrics != nil
                || entry.lyricsLanguage != nil || entry.syncedLyricsLanguage != nil
            if hasAudioDetails, entry.kind != .audio || archive.version < 5 {
                throw TagArchiveError.inconsistentEntry(path: entry.path, detail: "chapter and lyrics data requires an audio entry in schema 5")
            }
            for (key, values) in entry.properties ?? [:] {
                try FixedFields.validateText(key, field: "tag key")
                for value in values { try FixedFields.validateText(value, field: key) }
            }
            if entry.kind == .audio {
                for artwork in entry.artworks ?? [] {
                    try FixedFields.validateText(artwork.description, field: "artwork description")
                    try FixedFields.validateText(artwork.mimeType, field: "artwork MIME type")
                    try FixedFields.validateText(artwork.pictureType, field: "artwork type")
                }
            }
            if let chapters = entry.chapters {
                try ChapterList.validateStoredTimes(chapters)
                for chapter in chapters { try FixedFields.validateText(chapter.title, field: "chapter title") }
            }
            if let lines = entry.syncedLyrics {
                try LRC.validate(lines)
                for line in lines { try FixedFields.validateText(line.text, field: "synced lyrics") }
            }
            for language in [entry.lyricsLanguage, entry.syncedLyricsLanguage].compactMap({ $0 }) {
                guard FixedFields.isValidLanguage(language) else {
                    throw TagArchiveError.inconsistentEntry(path: entry.path, detail: "invalid lyrics language")
                }
            }
            // Kapitel-Zeitverläufe und leere SYLT-Frames sind lesbare Bestände.
            // Das Archiv muss sie sichern und wiederherstellen können; die
            // normale Bearbeitung prüft neue Kapitel weiterhin in TagFile.write.

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
}

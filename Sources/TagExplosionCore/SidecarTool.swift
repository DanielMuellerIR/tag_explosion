// Video-Sidecars als eigene Medienart (`MediaFormats.Kind.sidecar`): Kodi-/
// Jellyfin-NFO (KodiNFOFile) und Untertitel srt/vtt (SubtitleFile). Diese
// Datei bündelt den Lese- und Schreibweg für App, CLI und Archiv und die
// Kopplung zwischen Video und `<name>.nfo`.
//
// Warum keine Zuordnung zu `.document`: Der gemeinsame Dokument-Feldsatz
// (Titel, Autoren, Thema, Verlag …) passt weder zu Regie/Studio/Staffel noch
// zu Cue-Anzahl und Zeichensatz eines Untertitels; die Felder hätten im
// Dokument-Editor falsche Beschriftungen bekommen.
import Foundation

/// Bearbeitungspuffer je Sidecar-Art.
public enum SidecarFields: Sendable, Equatable {
    case nfo(NFOFields)
    case subtitle(SubtitleEditableFields)
}

/// Gelesener Inhalt einer Sidecar-Datei.
public enum SidecarContents: Sendable, Equatable {
    case nfo(NFOContents)
    case subtitle(SubtitleContents)

    /// Der editierbare Teil als gemeinsamer Puffer.
    public var fields: SidecarFields {
        switch self {
        case .nfo(let contents): return .nfo(contents.fields)
        case .subtitle(let contents): return .subtitle(contents.fields)
        }
    }
}

public enum SidecarTool {

    public static let nfoExtension = "nfo"

    /// Alle Sidecar-Endungen.
    public static let extensions: Set<String> = SubtitleFile.extensions.union([nfoExtension])

    public static func isNFO(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == nfoExtension
    }

    public static func isSubtitle(_ url: URL) -> Bool {
        SubtitleFile.extensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Lesen

    public static func read(url: URL) throws -> SidecarContents {
        if isNFO(url) { return .nfo(try KodiNFOFile.read(url: url)) }
        if isSubtitle(url) { return .subtitle(try SubtitleFile.read(url: url)) }
        throw TagError.cannotOpen(path: url.path)
    }

    public static func readSnapshot(url: URL, expecting stamp: FileStamp? = nil)
        throws -> FileSnapshot<SidecarContents> {
        try FileSnapshot.capture(at: url, expecting: stamp) { try read(url: url) }
    }

    // MARK: - Schreiben

    /// Ablehnung VOR Sicherung und Schreibweg: Nur-URL-NFO, SRT-Felder,
    /// unbrauchbare Werte. Öffentlich, damit App, CLI und Archiv dieselbe
    /// Regel benutzen.
    public static func requireWritable(_ fields: SidecarFields, original: SidecarFields,
                                       url: URL) throws {
        switch (fields, original) {
        case (.nfo(let new), .nfo(let old)):
            guard isNFO(url) else { throw TagError.cannotOpen(path: url.path) }
            try KodiNFOFile.validate(new, original: old)
        case (.subtitle(let new), .subtitle(let old)):
            try SubtitleFile.requireWritable(new, original: old, url: url)
        default:
            throw TagError.saveFailed(path: url.path)
        }
    }

    /// Schreibt die Unterschiede atomar; die Papierkorb-Sicherung macht der
    /// Aufrufer vorher (`TrashBackup.shared.backUp`).
    public static func write(url: URL, fields: SidecarFields, original: SidecarFields,
                             expecting stamp: FileStamp? = nil) throws {
        try requireWritable(fields, original: original, url: url)
        switch (fields, original) {
        case (.nfo(let new), .nfo(let old)):
            try KodiNFOFile.write(url: url, fields: new, original: old, expecting: stamp)
        case (.subtitle(let new), .subtitle(let old)):
            try SubtitleFile.write(url: url, fields: new, original: old, expecting: stamp)
        default:
            throw TagError.saveFailed(path: url.path)
        }
    }
}

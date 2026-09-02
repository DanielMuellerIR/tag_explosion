// Datenmodell des Cores — bewusst reine Werttypen (Sendable, Codable),
// damit GUI, CLI und Tests dieselben Strukturen nutzen können.
import Foundation

/// Ein einzelnes Tag-Feld. Mehrwertige Felder (z.B. zwei Genres) erscheinen
/// als mehrere `TagProperty` mit gleichem `key`.
public struct TagProperty: Sendable, Codable, Equatable, Hashable {
    /// Normalisierter Schlüssel wie von TagLib geliefert, z.B. "ARTIST".
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Ein eingebettetes Bild (Cover, Booklet …).
public struct Artwork: Sendable, Codable, Equatable {
    public var data: Data
    /// MIME-Type; leer, wenn in der Datei keiner hinterlegt ist.
    public var mimeType: String
    /// Bildtyp wie "Front Cover"; leer = unbekannt.
    public var pictureType: String
    public var description: String

    public init(data: Data, mimeType: String = "", pictureType: String = "", description: String = "") {
        self.data = data
        self.mimeType = mimeType
        self.pictureType = pictureType
        self.description = description
    }

    /// MIME-Type aus den Magic Bytes ableiten, falls keiner gesetzt ist
    /// (kommt in freier Wildbahn vor, z.B. fre:ac-getaggte MP3s).
    public var resolvedMimeType: String {
        if !mimeType.isEmpty { return mimeType }
        return Artwork.sniffMimeType(from: data) ?? ""
    }

    /// Erkennt gängige Bildformate an ihrer Signatur.
    public static func sniffMimeType(from data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if bytes.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        // WebP: "RIFF....WEBP"
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }
}

/// Technische Audio-Eigenschaften (von TagLib ermittelt).
public struct AudioInfo: Sendable, Codable, Equatable {
    public var lengthMilliseconds: Int
    public var bitrateKbps: Int
    public var sampleRateHz: Int
    public var channels: Int

    public init(lengthMilliseconds: Int, bitrateKbps: Int, sampleRateHz: Int, channels: Int) {
        self.lengthMilliseconds = lengthMilliseconds
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.channels = channels
    }
}

/// Ein Kapitel (Hörbuch, Podcast): Titel plus Beginn und Ende in Millisekunden.
///
/// Die JSON-Form ist bewusst kurz (`title`, `start`, `end`), damit sie von
/// Hand und aus anderen Kapitel-Werkzeugen leicht zu erzeugen ist.
public struct Chapter: Sendable, Codable, Equatable, Hashable {
    public var title: String
    /// Beginn in Millisekunden ab Dateianfang.
    public var startMilliseconds: Int
    /// Ende in Millisekunden. MP4 speichert nur Startzeiten; dort ergibt sich
    /// das Ende beim Lesen aus dem nächsten Kapitelbeginn bzw. der Spielzeit.
    public var endMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case title
        case startMilliseconds = "start"
        case endMilliseconds = "end"
    }

    public init(title: String, startMilliseconds: Int, endMilliseconds: Int) {
        self.title = title
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

/// Art einer Tag-Schicht. Manche Container tragen mehrere Schichten
/// nebeneinander (MP3: ID3v1 am Ende, ID3v2 am Anfang, selten APEv2; WAV:
/// ID3v2 + RIFF INFO; FLAC: Vorbis + selten ID3). Die Roh-Werte sind zugleich
/// die CLI-Schreibweise (`tagx layers strip --layer id3v1`).
public enum TagLayerKind: String, Sendable, Codable, CaseIterable, Hashable {
    case id3v1
    case id3v2
    case ape
    /// RIFF INFO (WAV)
    case info
    /// Vorbis Comment (FLAC)
    case vorbis

    /// Bit im Shim (`tx_layer_kind`).
    var shimMask: Int32 {
        switch self {
        case .id3v1: return 1
        case .id3v2: return 2
        case .ape: return 4
        case .info: return 8
        case .vorbis: return 16
        }
    }

    static func fromShim(_ value: Int32) -> TagLayerKind? {
        allCases.first { $0.shimMask == value }
    }
}

/// Eine Tag-Schicht einer Datei: ob sie vorhanden ist, welche Version sie hat
/// und welche Felder sie trägt. Formate ohne Schichtenmodell (MP4, Ogg,
/// Matroska …) liefern gar keine `TagLayer`.
public struct TagLayer: Sendable, Codable, Equatable, Hashable {
    public var kind: TagLayerKind
    /// ID3v2: 2/3/4 (Major-Version), ID3v1: 1, APE: 1/2; 0 = keine Angabe
    /// (RIFF INFO, Vorbis) oder Schicht fehlt.
    public var version: Int
    public var present: Bool
    /// Ob `TagFile.stripLayers` diese Schicht entfernen kann.
    public var strippable: Bool
    /// Property-Schlüssel der Schicht (z.B. "TITLE"); leer, wenn sie fehlt.
    public var fields: [String]

    public init(kind: TagLayerKind, version: Int, present: Bool, strippable: Bool, fields: [String]) {
        self.kind = kind
        self.version = version
        self.present = present
        self.strippable = strippable
        self.fields = fields
    }

    /// Anzeigename mit Version, z.B. "ID3v2.4", "ID3v1", "APEv2", "RIFF INFO".
    public var displayName: String {
        switch kind {
        case .id3v1: return "ID3v1"
        case .id3v2: return version > 0 ? "ID3v2.\(version)" : "ID3v2"
        case .ape: return version > 0 ? "APEv\(version)" : "APE"
        case .info: return "RIFF INFO"
        case .vorbis: return "Vorbis Comment"
        }
    }
}

/// ID3v2-Version beim Schreiben. Voreinstellung ist v2.4; v2.3 ist für alte
/// Player und Autoradios gedacht, die v2.4 nicht lesen. Grenzen von v2.3:
/// kein UTF-8 (TagLib schreibt UTF-16) und keine TDRC-/TDOR-Frames (TagLib
/// wandelt das Datum in TYER/TDAT). Details: knowledge/id3-schichten.md.
public enum ID3Version: String, Sendable, Codable, CaseIterable {
    case v24
    case v23

    /// Major-Version, wie der Shim sie erwartet (`tx_save_id3v2`).
    var shimValue: Int32 {
        switch self {
        case .v24: return 4
        case .v23: return 3
        }
    }
}

/// Vollständiger Tag-Zustand einer Datei — das, was gelesen/geschrieben wird.
public struct TagData: Sendable, Codable, Equatable {
    public var properties: [TagProperty]
    public var artworks: [Artwork]
    public var audio: AudioInfo?
    public var isReadOnly: Bool
    /// Kapitel in Abspielreihenfolge; leer bei Formaten ohne Kapitel.
    public var chapters: [Chapter]
    /// Ob das Format Kapitel lesen und schreiben kann (MP3, MP4, Matroska).
    /// Nur dann zeigt der Editor den Kapitel-Abschnitt.
    public var supportsChapters: Bool
    /// Tag-Schichten (ID3v1/ID3v2/APE …), auch fehlende mit `present == false`;
    /// leer bei Formaten ohne Schichtenmodell. Nur dann zeigt der Editor den
    /// Abschnitt „Tag-Schichten".
    public var layers: [TagLayer]

    public init(properties: [TagProperty], artworks: [Artwork], audio: AudioInfo?,
                isReadOnly: Bool = false, chapters: [Chapter] = [], supportsChapters: Bool = false,
                layers: [TagLayer] = []) {
        self.properties = properties
        self.artworks = artworks
        self.audio = audio
        self.isReadOnly = isReadOnly
        self.chapters = chapters
        self.supportsChapters = supportsChapters
        self.layers = layers
    }

    /// Alle Werte zu einem Schlüssel (Reihenfolge wie gelesen).
    public func values(for key: String) -> [String] {
        properties.filter { $0.key == key }.map(\.value)
    }

    /// Erster Wert zu einem Schlüssel oder nil.
    public func firstValue(for key: String) -> String? {
        properties.first { $0.key == key }?.value
    }
}

public extension String {
    /// "a, b ,c" → ["a", "b", "c"] — die gemeinsame Regel für kommagetrennte
    /// Listenfelder (App, CLI und Backends müssen identisch splitten).
    func splitCommaList() -> [String] {
        split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Fehler des Cores mit verständlicher Beschreibung.
public enum TagError: Error, LocalizedError, Sendable, Equatable {
    case cannotOpen(path: String)
    case saveFailed(path: String)
    case readOnly(path: String)
    case propertiesRejected(count: Int)
    case toolNotFound(name: String)
    case toolFailed(name: String, exitCode: Int32, stderr: String)
    /// Auf dem Datenträger ist zu wenig Platz für die Sicherheitskopie, die
    /// jedem Schreibvorgang vorausgeht.
    case notEnoughSpace(path: String, needBytes: Int64, freeBytes: Int64)
    /// Die Sicherungskopie in den Papierkorb ist fehlgeschlagen. Im
    /// abgesicherten Modus wird dann bewusst gar nicht geschrieben.
    case backupFailed(path: String, reason: String)
    /// Die Datei hat sich seit dem Öffnen auf der Platte verändert; ein
    /// Speichern würde fremde Änderungen überschreiben.
    case fileChangedOnDisk(path: String)
    /// Die angebotenen Coverdaten sind kein Bild, das ein E-Book tragen kann.
    /// Erkannt wird das an der Dateisignatur (Magic Bytes), nicht an der
    /// Endung — ein Textschnipsel darf nicht als JPEG deklariert werden.
    case unsupportedCoverData
    /// Ein Serienindex ohne Serie hat in keinem Format einen Speicherort.
    /// Ohne diese Ablehnung meldete das Schreiben Erfolg, obwohl der Index
    /// nirgends landet.
    case seriesIndexWithoutSeries
    /// Das Format der Datei kennt keine Kapitel (nur MP3, MP4 und Matroska).
    case chaptersUnsupported(path: String)
    /// Eine Kapitelliste ist in sich unstimmig (Ende vor Beginn, Überlappung,
    /// negative Zeit) oder eine Import-Datei ließ sich nicht lesen.
    case invalidChapters(reason: String)
    /// Ein Dokumentfeld (oder Zusatzschlüssel), das dieses Dateiformat nicht
    /// speichern kann — wird vor jeder Mutation abgelehnt statt still verworfen.
    case unsupportedDocumentField(name: String)
    /// Ein Wert, den das Zielformat so nicht ablegen kann (z.B. ein Datum
    /// außerhalb von ISO 8601 oder ein Trennzeichen im Autorennamen).
    case invalidDocumentValue(field: String, reason: String)
    /// Die Datei kennt die genannte Tag-Schicht nicht, sie fehlt, oder das
    /// Format kann sie nicht entfernen (z.B. `info` bei einer MP3).
    case layerUnsupported(path: String, layer: String)

    // Fehlertexte englisch (Open-Source-/CLI-Konvention); die App stellt ihnen
    // deutsche Kontextzeilen voran.
    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path):
            return "Cannot read file as a media file: \(path)"
        case .saveFailed(let path):
            return "Changes could not be saved: \(path)"
        case .readOnly(let path):
            return "File is read-only: \(path)"
        case .propertiesRejected(let count):
            return "\(count) tag field(s) are not supported by this format"
        case .toolNotFound(let name):
            return "External program not found: \(name)"
        case .toolFailed(let name, let code, let stderr):
            return "\(name) failed (exit code \(code)): \(stderr)"
        case .notEnoughSpace(let path, let need, let free):
            return "Not enough free space for a safety copy of \(path) "
                + "(needs \(need) bytes, \(free) bytes available)"
        case .backupFailed(let path, let reason):
            return "Safety copy failed, nothing was written: \(path) (\(reason))"
        case .fileChangedOnDisk(let path):
            return "File changed on disk since it was opened: \(path)"
        case .unsupportedCoverData:
            return "Cover data is not a supported image (JPEG or PNG expected)"
        case .seriesIndexWithoutSeries:
            return "A series index cannot be stored without a series name"
        case .chaptersUnsupported(let path):
            return "Chapters are not supported for this file format (MP3, MP4, Matroska only): \(path)"
        case .invalidChapters(let reason):
            return "Invalid chapter list: \(reason)"
        case .unsupportedDocumentField(let name):
            return "This document format cannot store the field: \(name)"
        case .invalidDocumentValue(let field, let reason):
            return "Invalid value for \(field): \(reason)"
        case .layerUnsupported(let path, let layer):
            return "Tag layer '\(layer)' is not present or cannot be removed in this file: \(path)"
        }
    }
}

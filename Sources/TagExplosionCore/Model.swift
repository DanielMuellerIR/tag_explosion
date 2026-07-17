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

/// Vollständiger Tag-Zustand einer Datei — das, was gelesen/geschrieben wird.
public struct TagData: Sendable, Codable, Equatable {
    public var properties: [TagProperty]
    public var artworks: [Artwork]
    public var audio: AudioInfo?
    public var isReadOnly: Bool

    public init(properties: [TagProperty], artworks: [Artwork], audio: AudioInfo?, isReadOnly: Bool = false) {
        self.properties = properties
        self.artworks = artworks
        self.audio = audio
        self.isReadOnly = isReadOnly
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

/// Fehler des Cores mit verständlicher Beschreibung.
public enum TagError: Error, LocalizedError, Sendable, Equatable {
    case cannotOpen(path: String)
    case saveFailed(path: String)
    case readOnly(path: String)
    case propertiesRejected(count: Int)
    case toolNotFound(name: String)
    case toolFailed(name: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path):
            return "Datei kann nicht als Mediendatei gelesen werden: \(path)"
        case .saveFailed(let path):
            return "Änderungen konnten nicht gespeichert werden: \(path)"
        case .readOnly(let path):
            return "Datei ist schreibgeschützt: \(path)"
        case .propertiesRejected(let count):
            return "\(count) Tag-Feld(er) werden von diesem Format nicht unterstützt"
        case .toolNotFound(let name):
            return "Externes Programm nicht gefunden: \(name)"
        case .toolFailed(let name, let code, let stderr):
            return "\(name) schlug fehl (Exit-Code \(code)): \(stderr)"
        }
    }
}

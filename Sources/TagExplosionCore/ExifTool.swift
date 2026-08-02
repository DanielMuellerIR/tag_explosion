// Wrapper um das externe Programm `exiftool` (Artistic License, nur aufgerufen).
// Liest und schreibt Bild-Metadaten: EXIF, IPTC, XMP.
//
// Für die editierbaren Kernfelder nutzen wir die MWG-Komposit-Tags
// (Metadata Working Group): die schreiben EXIF/IPTC/XMP synchron, so wie es
// professionelle Werkzeuge (u.a. Apple Fotos sinngemäß) tun.
import Foundation

/// Eine Metadaten-Gruppe (EXIF, IPTC, XMP, Composite …) mit ihren Feldern.
public struct MetadataGroup: Sendable, Codable, Equatable {
    public var name: String
    public var fields: [TagProperty]

    public init(name: String, fields: [TagProperty]) {
        self.name = name
        self.fields = fields
    }
}

/// Editierbare Kernfelder eines Bildes (MWG-harmonisiert).
public struct ImageCoreFields: Sendable, Codable, Equatable {
    public var title: String
    public var description: String
    /// Schlagwörter (mehrwertig)
    public var keywords: [String]
    public var creator: String
    public var copyright: String
    /// Aufnahmedatum als exiftool-String "YYYY:MM:DD HH:MM:SS" (ggf. mit Zone)
    public var dateTimeOriginal: String
    /// XMP-Bewertung 0–5; -1 = nicht gesetzt
    public var rating: Int
    /// GPS als Dezimalgrad-Strings; leer = nicht gesetzt
    public var gpsLatitude: String
    public var gpsLongitude: String

    public init(title: String = "", description: String = "", keywords: [String] = [],
                creator: String = "", copyright: String = "", dateTimeOriginal: String = "",
                rating: Int = -1, gpsLatitude: String = "", gpsLongitude: String = "") {
        self.title = title
        self.description = description
        self.keywords = keywords
        self.creator = creator
        self.copyright = copyright
        self.dateTimeOriginal = dateTimeOriginal
        self.rating = rating
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
    }
}

public enum ExifTool {

    public static let executableCandidates: [String] = [
        "exiftool",
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    public static func locateExecutable() throws -> String {
        try MediaInfoReader.locateTool(candidates: executableCandidates, name: "exiftool")
    }

    // MARK: - Lesen

    /// Alle Metadaten gruppiert (EXIF/IPTC/XMP/…), menschenlesbare Werte,
    /// Reihenfolge wie von exiftool geliefert.
    public static func readAllGroups(url: URL) throws -> [MetadataGroup] {
        let exe = try locateExecutable()
        // -G1 = Untergruppen (IFD0, ExifIFD, XMP-dc …), -s = Tag-Namen statt Beschreibungen
        let data = try MediaInfoReader.run(exe, ["-use", "MWG", "-j", "-G1", "-s", MediaInfoReader.toolArgument(for: url)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let dict = root.first
        else { return [] }

        let jsonText = MediaInfoReader.decodeLossy(data)
        // Gruppen in stabiler Reihenfolge des JSON-Textes aufbauen
        var groups: [String: [TagProperty]] = [:]
        var groupOrder: [String] = []
        var keyPositions: [(String, String.Index)] = []
        for key in dict.keys {
            if let range = jsonText.range(of: "\"\(key)\":") {
                keyPositions.append((key, range.lowerBound))
            } else {
                keyPositions.append((key, jsonText.endIndex))
            }
        }
        for (key, _) in keyPositions.sorted(by: { $0.1 < $1.1 }) {
            guard key.contains(":") else { continue } // SourceFile etc. überspringen
            let parts = key.split(separator: ":", maxSplits: 1)
            let group = String(parts[0])
            let tag = String(parts[1])
            let value = stringify(dict[key])
            if groups[group] == nil {
                groups[group] = []
                groupOrder.append(group)
            }
            groups[group]?.append(TagProperty(key: tag, value: value))
        }
        return groupOrder.map { MetadataGroup(name: $0, fields: groups[$0] ?? []) }
    }

    /// Roh-Metadaten mehrerer Bilder in EINEM exiftool-Aufruf, gedacht als
    /// Kopier-Quellen fürs Batch-Umkopieren: je Datei (Schlüssel = Pfad) ein
    /// Wörterbuch "Gruppe:Tag" → Textwert. Binärwerte werden ausgelassen —
    /// als Quelle für Textfelder taugen nur String-Werte (Typkompatibilität).
    public static func readRawStringTags(urls: [URL]) throws -> [String: [String: String]] {
        guard !urls.isEmpty else { return [:] }
        let exe = try locateExecutable()
        let data = try MediaInfoReader.run(
            exe, ["-use", "MWG", "-j", "-G1", "-s"] + urls.map { MediaInfoReader.toolArgument(for: $0) })
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }

        var result: [String: [String: String]] = [:]
        for dict in root {
            guard let source = dict["SourceFile"] as? String else { continue }
            var tags: [String: String] = [:]
            for (key, raw) in dict where key.contains(":") {
                let value = stringify(raw)
                if value.isEmpty || value.hasPrefix("(Binary data") { continue }
                tags[key] = value
            }
            result[source] = tags
        }
        return result
    }

    /// Editierbare Kernfelder lesen (MWG-harmonisiert, GPS numerisch).
    public static func readCoreFields(url: URL) throws -> ImageCoreFields {
        let exe = try locateExecutable()
        let args = ["-use", "MWG", "-j", "-n", "-XMP-dc:Title", "-MWG:Description", "-MWG:Keywords",
                    "-MWG:Creator", "-MWG:Copyright", "-MWG:DateTimeOriginal",
                    "-MWG:Rating", "-GPSLatitude", "-GPSLongitude",
                    MediaInfoReader.toolArgument(for: url)]
        let data = try MediaInfoReader.run(exe, args)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let dict = root.first
        else { return ImageCoreFields() }

        var fields = ImageCoreFields()
        fields.title = stringify(dict["Title"])
        fields.description = stringify(dict["Description"])
        if let list = dict["Keywords"] as? [Any] {
            fields.keywords = list.map { stringify($0) }
        } else if let single = dict["Keywords"] {
            fields.keywords = [stringify(single)]
        }
        fields.creator = stringify(dict["Creator"])
        fields.copyright = stringify(dict["Copyright"])
        fields.dateTimeOriginal = stringify(dict["DateTimeOriginal"])
        fields.rating = (dict["Rating"] as? NSNumber)?.intValue ?? -1
        if let lat = dict["GPSLatitude"] as? NSNumber { fields.gpsLatitude = lat.stringValue }
        if let lon = dict["GPSLongitude"] as? NSNumber { fields.gpsLongitude = lon.stringValue }
        return fields
    }

    // MARK: - Schreiben

    /// Schreibt die Kernfelder (nur die Unterschiede zu `original`).
    /// Leerer String löscht das jeweilige Feld.
    ///
    /// `expecting` (optional): Stempel des gelesenen Standes. exiftool ersetzt
    /// die Datei selbst atomar (Temp + Rename via `-overwrite_original`); die
    /// Prüfung hier verengt das Fenster für fremde Änderungen auf den Moment
    /// unmittelbar vor dem Werkzeuglauf — enger geht es ohne eigenen
    /// Schreibpfad für Bilder nicht.
    public static func writeCoreFields(
        url: URL, fields: ImageCoreFields, original: ImageCoreFields,
        expecting stamp: FileStamp? = nil
    ) throws {
        var args: [String] = []

        func assign(_ tag: String, _ new: String, _ old: String) {
            guard new != old else { return }
            args.append("-\(tag)=\(new)") // leerer Wert löscht den Tag
        }
        // MWG kennt kein Title-Tag; XMP-dc ist der Standard-Ort (so auch Apple Fotos)
        assign("XMP-dc:Title", fields.title, original.title)
        assign("MWG:Description", fields.description, original.description)
        assign("MWG:Creator", fields.creator, original.creator)
        assign("MWG:Copyright", fields.copyright, original.copyright)
        assign("MWG:DateTimeOriginal", fields.dateTimeOriginal, original.dateTimeOriginal)

        if fields.keywords != original.keywords {
            // Liste komplett ersetzen: erst löschen, dann alle Werte anhängen
            args.append("-MWG:Keywords=")
            for keyword in fields.keywords where !keyword.isEmpty {
                args.append("-MWG:Keywords+=\(keyword)")
            }
        }
        if fields.rating != original.rating {
            args.append(fields.rating >= 0 ? "-MWG:Rating=\(fields.rating)" : "-MWG:Rating=")
        }
        if fields.gpsLatitude != original.gpsLatitude || fields.gpsLongitude != original.gpsLongitude {
            if fields.gpsLatitude.isEmpty || fields.gpsLongitude.isEmpty {
                args.append("-GPSLatitude=")
                args.append("-GPSLongitude=")
                args.append("-GPSLatitudeRef=")
                args.append("-GPSLongitudeRef=")
            } else {
                // Vorzeichenbehaftete Dezimalgrade; Ref-Tags leiten sich daraus ab
                args.append("-GPSLatitude*=\(fields.gpsLatitude)")
                args.append("-GPSLongitude*=\(fields.gpsLongitude)")
            }
        }

        guard !args.isEmpty else { return } // nichts zu tun

        let exe = try locateExecutable()
        // So spät wie möglich prüfen: Danach übernimmt exiftool die Datei.
        try FileStamp.requireUnchanged(stamp, at: url)
        // -overwrite_original: kein "_original"-Duplikat; -m: kleinere Warnungen tolerieren
        _ = try MediaInfoReader.run(exe, ["-use", "MWG", "-overwrite_original", "-m"] + args + [MediaInfoReader.toolArgument(for: url)])
    }

    // MARK: - Intern

    static func stringify(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { stringify($0) }.joined(separator: ", ")
        default: return "\(value!)"
        }
    }

}

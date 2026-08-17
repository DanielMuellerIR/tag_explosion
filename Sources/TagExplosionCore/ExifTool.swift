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

/// Fachliche Wertebereichsfehler der editierbaren Bildfelder. Der gemeinsame
/// Typ hält Core, CLI, App und Archivimport auf derselben Regel.
public enum ImageMetadataValidationError: Error, LocalizedError, Sendable, Equatable {
    case ratingOutOfRange(Int)
    case incompleteGPS
    case invalidLatitude(String)
    case invalidLongitude(String)

    public var errorDescription: String? {
        switch self {
        case .ratingOutOfRange:
            return "image rating must be between -1 (unset) and 5"
        case .incompleteGPS:
            return "image GPS requires both latitude and longitude, or neither"
        case .invalidLatitude:
            return "image GPS latitude must be a finite decimal number between -90 and 90"
        case .invalidLongitude:
            return "image GPS longitude must be a finite decimal number between -180 and 180"
        }
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
    ///
    /// Die Schlüssel des Ergebnisses sind die Pfade der ÜBERGEBENEN URLs.
    /// exiftool bekommt den aufgelösten Pfad (Symlinks folgen) und meldet ihn
    /// als `SourceFile` zurück; ohne die Rückabbildung fände ein Aufrufer, der
    /// die Datei über eine Verknüpfung angegeben hat, seinen eigenen Eintrag
    /// nicht wieder.
    public static func readRawStringTags(urls: [URL]) throws -> [String: [String: String]] {
        guard !urls.isEmpty else { return [:] }
        // Mehrere Eingaben können auf dieselbe Datei zeigen (Verknüpfung +
        // Original). Alle bekommen dasselbe Tag-Wörterbuch.
        var inputsByToolPath: [String: [String]] = [:]
        for url in urls {
            inputsByToolPath[MediaInfoReader.toolArgument(for: url), default: []].append(url.path)
        }
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
            // Meldet exiftool wider Erwarten einen unbekannten Pfad, bleibt er
            // als Schlüssel erhalten, statt das Ergebnis stillschweigend zu
            // verlieren.
            for path in inputsByToolPath[source] ?? [source] {
                result[path] = tags
            }
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

    /// Kernfelder und zugehörigen Dateistempel als einen konsistenten
    /// Schnappschuss lesen. Eine Ersetzung während des exiftool-Aufrufs wird
    /// erkannt, auch wenn der Pfad gleich bleibt.
    public static func readCoreFieldsSnapshot(
        url: URL,
        expecting stamp: FileStamp? = nil
    ) throws -> FileSnapshot<ImageCoreFields> {
        try readCoreFieldsSnapshot(url: url, expecting: stamp, afterRead: {})
    }

    /// Testbarer Kern des Schnappschusses. `afterRead` erlaubt eine gezielte
    /// Dateiänderung genau zwischen Backend-Read und Abschlussprüfung.
    static func readCoreFieldsSnapshot(
        url: URL,
        expecting stamp: FileStamp? = nil,
        afterRead: () throws -> Void
    ) throws -> FileSnapshot<ImageCoreFields> {
        try FileSnapshot.capture(at: url, expecting: stamp) {
            let fields = try readCoreFields(url: url)
            try afterRead()
            return fields
        }
    }

    // MARK: - Schreiben

    /// Prüft die Fachwerte, bevor App/CLI eine Sicherung oder ein Batch eine
    /// erste Mutation anlegt. Mit `original` werden bereits vorhandene
    /// Fremdwerte toleriert, solange dieser Schreibvorgang sie nicht ändert.
    public static func requireValidCoreFields(
        _ fields: ImageCoreFields,
        original: ImageCoreFields? = nil
    ) throws {
        try requireWritableCoreFields(fields, original: original)

        // Ab hier die reinen WERTEBEREICHE der Oberflaeche. Sie gelten fuer
        // eine vom Nutzer gewuenschte Aenderung, NICHT fuer das
        // Wiederherstellen eines archivierten Bestandswerts: Ein Rating 6 oder
        // eine GPS-Koordinate 91/181 lag vor dem Backup wirklich in der Datei
        // und muss dorthin zurueckkoennen (Review-Fund 2026-08-17, siehe
        // knowledge/archiv-restore-vertrag.md).
        let ratingChanged = original.map { $0.rating != fields.rating } ?? true
        if ratingChanged {
            guard (-1...5).contains(fields.rating) else {
                throw ImageMetadataValidationError.ratingOutOfRange(fields.rating)
            }
        }

        let gpsChanged = original.map {
            $0.gpsLatitude != fields.gpsLatitude || $0.gpsLongitude != fields.gpsLongitude
        } ?? true
        guard gpsChanged, !fields.gpsLatitude.isEmpty, !fields.gpsLongitude.isEmpty else {
            return
        }
        guard let latitude = Double(fields.gpsLatitude), (-90...90).contains(latitude) else {
            throw ImageMetadataValidationError.invalidLatitude(fields.gpsLatitude)
        }
        guard let longitude = Double(fields.gpsLongitude), (-180...180).contains(longitude) else {
            throw ImageMetadataValidationError.invalidLongitude(fields.gpsLongitude)
        }
    }

    /// Nur die TECHNISCHE Schreibbarkeit — ohne die Wertebereiche der
    /// Oberflaeche.
    ///
    /// Getrennt von `requireValidCoreFields`, weil beides verschiedene Fragen
    /// beantwortet: „Darf der Nutzer das eingeben?" gegen „Kann exiftool das
    /// ueberhaupt schreiben?". Der Archiv-Import stellt einen Zustand wieder
    /// her, den die Datei nachweislich schon einmal hatte — dort zaehlt nur die
    /// zweite Frage. Vorher lehnte der Import genau die Bestandswerte ab, die
    /// der Export ausdruecklich sichern soll, sobald sich das Ziel inzwischen
    /// geaendert hatte (Review-Fund 2026-08-17).
    ///
    /// Geprueft wird: GPS nur vollstaendig oder gar nicht, und beide Werte
    /// muessen endliche Zahlen sein.
    public static func requireWritableCoreFields(
        _ fields: ImageCoreFields,
        original: ImageCoreFields? = nil
    ) throws {
        let gpsChanged = original.map {
            $0.gpsLatitude != fields.gpsLatitude || $0.gpsLongitude != fields.gpsLongitude
        } ?? true
        guard gpsChanged else { return }
        let latitudeEmpty = fields.gpsLatitude.isEmpty
        let longitudeEmpty = fields.gpsLongitude.isEmpty
        if latitudeEmpty && longitudeEmpty { return }
        guard !latitudeEmpty && !longitudeEmpty else {
            throw ImageMetadataValidationError.incompleteGPS
        }
        guard let latitude = Double(fields.gpsLatitude), latitude.isFinite else {
            throw ImageMetadataValidationError.invalidLatitude(fields.gpsLatitude)
        }
        guard let longitude = Double(fields.gpsLongitude), longitude.isFinite else {
            throw ImageMetadataValidationError.invalidLongitude(fields.gpsLongitude)
        }
        _ = (latitude, longitude)
    }

    /// Schreibt die Kernfelder (nur die Unterschiede zu `original`).
    /// Leerer String löscht das jeweilige Feld.
    ///
    /// `expecting` (optional): Stempel des gelesenen Standes. exiftool läuft
    /// bewusst NICHT auf dem Original, sondern auf der Geschwisterkopie des
    /// atomaren Rahmens: Sonst könnte eine fremde Änderung, die genau während
    /// des Werkzeuglaufs passiert, still verworfen werden. Erst unmittelbar
    /// vor dem eigenen Austausch wird der Stempel ein letztes Mal geprüft.
    /// `allowingArchivedValues`: Nur der Archiv-Restore setzt das. Dann gelten
    /// ausschliesslich die technischen Schranken — ein gesicherter
    /// Bestandswert (Rating 6, GPS 91/181) muss in die Datei zurueckkoennen,
    /// aus der er stammt (Review-Fund 2026-08-17). Fuer jeden anderen Aufrufer
    /// bleibt die Wertebereichspruefung als Sicherheitsnetz bestehen.
    public static func writeCoreFields(
        url: URL, fields: ImageCoreFields, original: ImageCoreFields,
        expecting stamp: FileStamp? = nil,
        allowingArchivedValues: Bool = false
    ) throws {
        if allowingArchivedValues {
            try requireWritableCoreFields(fields, original: original)
        } else {
            try requireValidCoreFields(fields, original: original)
        }
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

        guard !args.isEmpty else {
            // Auch ein No-op ist eine Aussage über den gelesenen Stand.
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }

        let exe = try locateExecutable()
        // Früh prüfen spart Kopie und Werkzeuglauf, wenn die Datei ohnehin
        // schon fremd verändert ist. Die verbindliche Prüfung macht der
        // atomare Rahmen unten direkt vor dem Austausch.
        try FileStamp.requireUnchanged(stamp, at: url)
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            // -overwrite_original: kein "_original"-Duplikat; -m: kleinere Warnungen tolerieren
            _ = try MediaInfoReader.run(
                exe,
                ["-use", "MWG", "-overwrite_original", "-m"] + args
                    + [MediaInfoReader.toolArgument(for: temp)])
        } validate: { temp in
            // exiftool bricht bei einem Bild, das es nicht versteht, selbst ab
            // (Exit-Code ungleich 0, oben als `toolFailed` sichtbar) und lässt
            // die Datei dann unverändert. Ein zweiter exiftool-Lauf nur zur
            // Kontrolle würde die Prozessanzahl je Bild verdoppeln — geprüft
            // wird deshalb nur, dass überhaupt eine nicht-leere Datei entstand.
            guard let size = VolumeSpace.fileSize(of: temp), size > 0 else {
                throw TagError.saveFailed(path: url.path)
            }
        }
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

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
    /// XMP-Bewertung 0–5; nil = die Datei trägt gar kein Rating-Tag.
    ///
    /// Als Optional, weil „kein Tag" und „Tag mit dem Wert −1" zwei
    /// verschiedene Zustände sind: −1 ist der von Adobe dokumentierte Wert für
    /// „abgelehnt" und wird von Bridge und Lightroom wirklich geschrieben. Mit
    /// −1 als Leerwert löschte ein Archiv-Restore genau dieses Tag, statt es
    /// zurückzuschreiben — und der Read-back konnte den Fehler nicht sehen,
    /// weil er dieselbe Mehrdeutigkeit las (Review-Fund 2026-08-20).
    public var rating: Int?
    /// GPS als Dezimalgrad-Strings; leer = nicht gesetzt
    public var gpsLatitude: String
    public var gpsLongitude: String

    public init(title: String = "", description: String = "", keywords: [String] = [],
                creator: String = "", copyright: String = "", dateTimeOriginal: String = "",
                rating: Int? = nil, gpsLatitude: String = "", gpsLongitude: String = "") {
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
            return "image rating must be between -1 (rejected) and 5, or absent"
        case .incompleteGPS:
            return "image GPS requires both latitude and longitude, or neither"
        case .invalidLatitude:
            return "image GPS latitude must be a finite decimal number between -90 and 90"
        case .invalidLongitude:
            return "image GPS longitude must be a finite decimal number between -180 and 180"
        }
    }
}

/// Die Kernfelder als Schlüssel — für die Herkunftsangabe je Feld
/// (Original oder Sidecar). GPS zählt als EIN Feld: Breite und Länge
/// gehören zusammen und stammen immer aus derselben Datei.
public enum ImageCoreFieldKey: String, Sendable, Codable, CaseIterable, Hashable {
    case title, description, keywords, creator, copyright, dateTimeOriginal, rating, gps
}

/// Ergebnis eines Lesevorgangs: die zusammengeführten Kernfelder plus die
/// Angabe, welche davon aus der Sidecar stammen. Sidecar-Werte überlagern
/// die eingebetteten Werte feldweise — so lesen auch Lightroom und Bridge.
public struct ImageCoreReading: Sendable, Equatable {
    /// Zusammengeführte Felder (Sidecar gewinnt, wo sie einen Wert trägt).
    public var fields: ImageCoreFields
    /// Pfad der vorhandenen Sidecar; nil = keine da (oder Datei ist selbst eine).
    public var sidecarURL: URL?
    public var sidecar: SidecarState
    /// Felder, deren Wert aus der Sidecar stammt.
    public var sidecarFields: Set<ImageCoreFieldKey>

    public init(fields: ImageCoreFields, sidecarURL: URL? = nil,
                sidecar: SidecarState = .absent,
                sidecarFields: Set<ImageCoreFieldKey> = []) {
        self.fields = fields
        self.sidecarURL = sidecarURL
        self.sidecar = sidecar
        self.sidecarFields = sidecarFields
    }

    /// Auch eine beim Lesen fehlende Sidecar gehört zum Lesestand des Bildes.
    public func requireUnchangedSidecar(for imageURL: URL) throws {
        guard !MediaFormats.isXMPSidecar(imageURL) else { return }
        try sidecar.requireUnchanged(at: MediaFormats.sidecarURL(for: imageURL))
    }
}

/// Wohin ein Schreibvorgang geht: in die Bilddatei selbst oder in die
/// XMP-Sidecar daneben. Entsteht nur über `ExifTool.writeDestination`, damit
/// die Regel „RAW nie direkt beschreiben" an genau einer Stelle liegt.
public struct ImageWriteDestination: Sendable, Equatable {
    public enum Reason: String, Sendable, Codable {
        /// Direkt in die Bilddatei (oder: die Datei ist selbst eine .xmp).
        case original
        /// Kamera-RAW — wird grundsätzlich nie direkt beschrieben.
        case rawFormat
        /// exiftool kann in dieses Format nicht schreiben (bmp, svg).
        case formatNotWritable
        /// Es gibt schon eine Sidecar; ihre Werte überlagern beim Lesen die
        /// eingebetteten. Ein Schreiben ins Original bliebe unsichtbar.
        case existingSidecar
        /// Einstellung „Sidecar statt Original schreiben".
        case setting
    }

    /// Datei, die tatsächlich verändert oder neu angelegt wird.
    public let url: URL
    public let reason: Reason
    public var isSidecar: Bool { reason != .original }
}

public enum ExifTool {

    public static let executableCandidates: [String] = [
        "exiftool",
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    public static func locateExecutable() throws -> String {
        try ExternalToolRunner.locateTool(candidates: executableCandidates, name: "exiftool")
    }

    // MARK: - Lesen

    /// Alle Metadaten gruppiert (EXIF/IPTC/XMP/…), menschenlesbare Werte,
    /// Reihenfolge wie von exiftool geliefert.
    public static func readAllGroups(url: URL) throws -> [MetadataGroup] {
        let exe = try locateExecutable()
        // -G1 = Untergruppen (IFD0, ExifIFD, XMP-dc …), -s = Tag-Namen statt Beschreibungen
        let data = try ExternalToolRunner.run(exe, ["-use", "MWG", "-j", "-G1", "-s", ExternalToolRunner.toolArgument(for: url)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let dict = root.first
        else { return [] }

        let jsonText = ExternalToolText.decodeLossyJSON(data)
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
            inputsByToolPath[ExternalToolRunner.toolArgument(for: url), default: []].append(url.path)
        }
        let exe = try locateExecutable()
        let data = try ExternalToolRunner.run(
            exe, ["-use", "MWG", "-j", "-G1", "-s"] + urls.map { ExternalToolRunner.toolArgument(for: $0) })
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
    /// Liegt neben dem Bild eine XMP-Sidecar, überlagern deren Werte die
    /// eingebetteten (siehe `readCoreReading`).
    public static func readCoreFields(url: URL) throws -> ImageCoreFields {
        try readCoreReading(url: url).fields
    }

    /// Kernfelder samt Sidecar-Zustand lesen. Eine `.xmp` hat keine eigene
    /// Sidecar — sie IST eine und wird direkt gelesen.
    public static func readCoreReading(url: URL) throws -> ImageCoreReading {
        let sidecarURL = MediaFormats.isXMPSidecar(url) ? nil : MediaFormats.sidecarURL(for: url)
        return try readCoreReading(url: url, sidecarURL: sidecarURL)
    }

    /// Kern des Zusammenführens; `sidecarURL` ist auch für den Read-back auf
    /// einer noch nicht eingesetzten Sidecar-Kopie frei wählbar.
    static func readCoreReading(url: URL, sidecarURL: URL?) throws -> ImageCoreReading {
        let embedded = try readCoreFieldsWithPresence(url: url)
        guard let sidecarURL, let sidecarStamp = FileStamp.current(of: sidecarURL) else {
            return ImageCoreReading(fields: embedded.fields)
        }
        let sidecar = try readCoreFieldsWithPresence(url: sidecarURL)
        try FileStamp.requireUnchanged(sidecarStamp, at: sidecarURL)
        var merged = embedded.fields
        for key in sidecar.present {
            merged.assign(key, from: sidecar.fields)
        }
        return ImageCoreReading(
            fields: merged, sidecarURL: sidecarURL,
            sidecar: .present(sidecarStamp), sidecarFields: sidecar.present)
    }

    /// Kernfelder EINER Datei plus die Menge der wirklich vorhandenen Tags.
    /// Der Unterschied „Tag fehlt" gegen „Tag leer" entscheidet beim
    /// Zusammenführen, ob die Sidecar ein Feld überlagert.
    private static func readCoreFieldsWithPresence(
        url: URL
    ) throws -> (fields: ImageCoreFields, present: Set<ImageCoreFieldKey>) {
        let exe = try locateExecutable()
        let args = ["-use", "MWG", "-j", "-n", "-XMP-dc:Title", "-MWG:Description", "-MWG:Keywords",
                    "-MWG:Creator", "-MWG:Copyright", "-MWG:DateTimeOriginal",
                    "-MWG:Rating", "-GPSLatitude", "-GPSLongitude",
                    ExternalToolRunner.toolArgument(for: url)]
        let data = try ExternalToolRunner.run(exe, args)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let dict = root.first
        else { return (ImageCoreFields(), []) }

        var present: Set<ImageCoreFieldKey> = []
        for (key, jsonKeys) in [
            (ImageCoreFieldKey.title, ["Title"]), (.description, ["Description"]),
            (.keywords, ["Keywords"]), (.creator, ["Creator"]), (.copyright, ["Copyright"]),
            (.dateTimeOriginal, ["DateTimeOriginal"]), (.rating, ["Rating"]),
            (.gps, ["GPSLatitude", "GPSLongitude"]),
        ] where jsonKeys.contains(where: { dict[$0] != nil }) {
            present.insert(key)
        }

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
        // Fehlt der Schlüssel, bleibt das Feld nil — „kein Tag". Ein
        // vorhandenes Tag behält seinen Wert, auch das negative −1.
        fields.rating = (dict["Rating"] as? NSNumber)?.intValue
        if let lat = dict["GPSLatitude"] as? NSNumber { fields.gpsLatitude = lat.stringValue }
        if let lon = dict["GPSLongitude"] as? NSNumber { fields.gpsLongitude = lon.stringValue }
        return (fields, present)
    }

    /// Kernfelder (samt Sidecar-Zustand) und Dateistempel des Bildes als einen
    /// konsistenten Schnappschuss lesen. Eine Ersetzung während des
    /// exiftool-Aufrufs wird erkannt, auch wenn der Pfad gleich bleibt.
    public static func readCoreFieldsSnapshot(
        url: URL,
        expecting stamp: FileStamp? = nil
    ) throws -> FileSnapshot<ImageCoreReading> {
        try readCoreFieldsSnapshot(url: url, expecting: stamp, afterRead: {})
    }

    /// Testbarer Kern des Schnappschusses. `afterRead` erlaubt eine gezielte
    /// Dateiänderung genau zwischen Backend-Read und Abschlussprüfung.
    static func readCoreFieldsSnapshot(
        url: URL,
        expecting stamp: FileStamp? = nil,
        afterRead: () throws -> Void
    ) throws -> FileSnapshot<ImageCoreReading> {
        try FileSnapshot.capture(at: url, expecting: stamp) {
            let reading = try readCoreReading(url: url)
            try afterRead()
            try reading.requireUnchangedSidecar(for: url)
            return reading
        }
    }

    // MARK: - Schreibziel

    /// Entscheidet, ob eine Änderung in die Bilddatei oder in die Sidecar
    /// `<name>.xmp` geht. Reihenfolge der Gründe: eine `.xmp` ist selbst das
    /// Ziel; Kamera-RAW nie direkt; Formate ohne exiftool-Schreibweg (bmp,
    /// svg) nie direkt; eine vorhandene Sidecar bleibt das Ziel, weil ihre
    /// Werte beim Lesen gewinnen; zuletzt die Einstellung `preferSidecar`.
    public static func writeDestination(for url: URL, preferSidecar: Bool) -> ImageWriteDestination {
        if MediaFormats.isXMPSidecar(url) {
            return ImageWriteDestination(url: url, reason: .original)
        }
        let sidecar = MediaFormats.sidecarURL(for: url)
        if MediaFormats.isRawImage(url) {
            return ImageWriteDestination(url: sidecar, reason: .rawFormat)
        }
        if MediaFormats.imageEmbeddedReadOnly.contains(url.pathExtension.lowercased()) {
            return ImageWriteDestination(url: sidecar, reason: .formatNotWritable)
        }
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return ImageWriteDestination(url: sidecar, reason: .existingSidecar)
        }
        if preferSidecar {
            return ImageWriteDestination(url: sidecar, reason: .setting)
        }
        return ImageWriteDestination(url: url, reason: .original)
    }

    /// Endungen, in die die installierte exiftool-Version schreiben kann
    /// (`exiftool -listwf`, kleingeschrieben). Für die Testsuite: Die
    /// statischen Listen in `MediaFormats` werden dagegen geprüft, nicht
    /// geraten.
    public static func writableExtensions() throws -> Set<String> {
        let exe = try locateExecutable()
        let data = try ExternalToolRunner.run(exe, ["-listwf"])
        let text = ExternalToolText.decodeLossyPlainText(data)
        var result: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            // Die erste Zeile ist eine Überschrift ("Writable file extensions:").
            if line.contains(":") { continue }
            for word in line.split(separator: " ") where !word.isEmpty {
                result.insert(word.lowercased())
            }
        }
        return result
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
        if ratingChanged, let rating = fields.rating {
            guard (-1...5).contains(rating) else {
                throw ImageMetadataValidationError.ratingOutOfRange(rating)
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
    /// ausschließlich die technischen Schranken — ein gesicherter
    /// Bestandswert (Rating 6, GPS 91/181) muss in die Datei zurückkönnen,
    /// aus der er stammt (Review-Fund 2026-08-17). Für jeden anderen Aufrufer
    /// bleibt die Wertebereichsprüfung als Sicherheitsnetz bestehen. Der
    /// Archivweg verlangt außerdem einen exakten Read-back auf der Temp-Datei;
    /// eine Normalisierung oder Ablehnung ersetzt dadurch nie das Original.
    /// `to`: Schreibziel aus `writeDestination`; nil = Regelentscheidung ohne
    /// Sidecar-Vorliebe (RAW und nicht schreibbare Formate landen trotzdem
    /// in der Sidecar). `sidecar`: Sidecar-Zustand aus dem Lesevorgang — nur
    /// damit erkennt der Schreibweg eine inzwischen fremd angelegte oder
    /// geänderte Sidecar. `url` ist immer das BILD; bei einem Sidecar-Ziel
    /// gilt `expecting` weiterhin dem Bild (dessen Werte wurden gelesen).
    public static func writeCoreFields(
        url: URL, fields: ImageCoreFields, original: ImageCoreFields,
        expecting stamp: FileStamp? = nil,
        to destination: ImageWriteDestination? = nil,
        sidecar: SidecarState = .unknown,
        allowingArchivedValues: Bool = false
    ) throws {
        try writeCoreFields(
            url: url, fields: fields, original: original, expecting: stamp,
            destination: destination ?? writeDestination(for: url, preferSidecar: false),
            sidecar: sidecar,
            allowingArchivedValues: allowingArchivedValues,
            replacingOriginal: true, beforeReplace: {})
    }

    /// Archivwerte werden auf einer Geschwisterkopie wirklich geschrieben
    /// und exakt zurückgelesen, bevor Dry-run oder Sicherung Erfolg melden.
    /// Der echte Import setzt anschließend genau diese geprüfte Kopie ein.
    static func writeArchivedCoreFields(
        url: URL, fields: ImageCoreFields, original: ImageCoreFields,
        expecting stamp: FileStamp, to destination: ImageWriteDestination,
        sidecar: SidecarState, dryRun: Bool,
        beforeReplace: () throws -> Void
    ) throws {
        try writeCoreFields(
            url: url, fields: fields, original: original, expecting: stamp,
            destination: destination, sidecar: sidecar,
            allowingArchivedValues: true, replacingOriginal: !dryRun,
            beforeReplace: beforeReplace)
    }

    private static func writeCoreFields(
        url: URL, fields: ImageCoreFields, original: ImageCoreFields,
        expecting stamp: FileStamp?, destination: ImageWriteDestination,
        sidecar: SidecarState, allowingArchivedValues: Bool,
        replacingOriginal: Bool, beforeReplace: () throws -> Void
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
            // nil heißt „kein Rating-Tag" und wird zum Löschbefehl; JEDER Wert,
            // auch ein negativer, ist ein echter Bestandswert aus der Datei und
            // wird wörtlich geschrieben. Vorher löschte hier jeder negative Wert
            // das Tag (Review-Fund 2026-08-18), und danach blieb −1 als
            // Löschwert übrig — genau der Wert, den Adobe für „abgelehnt"
            // vergibt (Review-Fund 2026-08-20).
            args.append(fields.rating.map { "-MWG:Rating=\($0)" } ?? "-MWG:Rating=")
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

        // Bild und Sidecar bilden gemeinsam den Lesestand, auch wenn nur
        // eine der beiden Dateien geschrieben wird oder gar nichts zu tun ist.
        let requireCurrentReading = {
            try FileStamp.requireUnchanged(stamp, at: url)
            if !MediaFormats.isXMPSidecar(url) {
                try sidecar.requireUnchanged(at: MediaFormats.sidecarURL(for: url))
            }
        }
        try requireCurrentReading()
        guard !args.isEmpty else { return }

        let exe = try locateExecutable()
        let beforeCommit = {
            try beforeReplace()
            try requireCurrentReading()
        }

        // exiftool auf der Temp-Kopie; die Temp-Datei einer neuen Sidecar
        // legt exiftool selbst an (eine fehlende .xmp entsteht beim Schreiben).
        // -overwrite_original: kein "_original"-Duplikat; -m: kleinere Warnungen tolerieren
        let mutate: (URL) throws -> Void = { temp in
            _ = try ExternalToolRunner.run(
                exe,
                ["-use", "MWG", "-overwrite_original", "-m"] + args
                    + [ExternalToolRunner.toolArgument(for: temp)])
        }
        // exiftool bricht bei einem Bild, das es nicht versteht, selbst ab
        // (Exit-Code ungleich 0, oben als `toolFailed` sichtbar) und lässt
        // die Datei dann unverändert. Für normale UI-/CLI-Werte genügt
        // deshalb die Strukturprüfung; die Oberfläche liest nach dem
        // Speichern ohnehin neu. Der Archivvertrag ist strenger: Er
        // verspricht den EXAKTEN früheren Zustand. Dessen Read-back muss
        // noch auf der Temp-Datei passen, bevor Dry-run, Sicherung oder
        // Austausch Erfolg melden. Bei einem Sidecar-Ziel liest der Read-back
        // Bild plus Temp-Sidecar zusammengeführt — so, wie die Oberfläche es
        // nach dem Austausch sehen wird.
        let validate: (URL) throws -> Void = { temp in
            guard let size = VolumeSpace.fileSize(of: temp), size > 0 else {
                throw TagError.saveFailed(path: url.path)
            }
            if allowingArchivedValues {
                let readBack = destination.isSidecar
                    ? try readCoreReading(url: url, sidecarURL: temp).fields
                    : try readCoreFields(url: temp)
                guard readBack == fields else {
                    throw TagError.saveFailed(path: url.path)
                }
            }
            // Auch ein Archiv-Probelauf endet erst nach Prüfung beider Quelldateien.
            try requireCurrentReading()
        }

        guard destination.isSidecar else {
            try AtomicFileRewrite.run(
                url: url, expecting: stamp, replacingOriginal: replacingOriginal,
                beforeReplace: beforeCommit, mutate: mutate, validate: validate)
            return
        }

        // Sidecar-Ziel: Die zu schützende Datei ist die Sidecar. Existiert
        // sie, läuft derselbe atomare Rahmen wie für ein Bild; sonst entsteht
        // sie exklusiv neu. Der Lesestand entscheidet, was erwartet wird —
        // eine inzwischen fremd angelegte oder gelöschte Sidecar ist ein
        // Konflikt, kein stilles Überschreiben.
        let sidecarURL = destination.url
        let sidecarStamp: FileStamp?
        switch sidecar {
        case .present(let known): sidecarStamp = known
        case .absent: sidecarStamp = nil
        case .unknown: sidecarStamp = FileStamp.current(of: sidecarURL)
        }
        if let sidecarStamp {
            try AtomicFileRewrite.run(
                url: sidecarURL, expecting: sidecarStamp, replacingOriginal: replacingOriginal,
                beforeReplace: beforeCommit, mutate: mutate, validate: validate)
        } else {
            try AtomicFileRewrite.create(
                url: sidecarURL, replacingOriginal: replacingOriginal,
                beforeReplace: beforeCommit, mutate: mutate, validate: validate)
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

extension ImageCoreFields {
    /// Übernimmt EIN Kernfeld aus `other` (für das feldweise Überlagern
    /// durch die Sidecar). GPS wird als Paar übernommen.
    mutating func assign(_ key: ImageCoreFieldKey, from other: ImageCoreFields) {
        switch key {
        case .title: title = other.title
        case .description: description = other.description
        case .keywords: keywords = other.keywords
        case .creator: creator = other.creator
        case .copyright: copyright = other.copyright
        case .dateTimeOriginal: dateTimeOriginal = other.dateTimeOriginal
        case .rating: rating = other.rating
        case .gps:
            gpsLatitude = other.gpsLatitude
            gpsLongitude = other.gpsLongitude
        }
    }
}

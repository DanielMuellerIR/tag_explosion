// tagx exif — Bild-Metadaten (EXIF/IPTC/XMP) anzeigen und setzen.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Exif: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exif",
        abstract: "Show and edit image metadata (EXIF/IPTC/XMP via exiftool).",
        subcommands: [ExifShow.self, ExifSet.self],
        defaultSubcommand: ExifShow.self
    )
}

struct ExifShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show core fields and all metadata groups.")

    @Argument(help: "Image file") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .long, help: "Print all groups (default: core fields only)") var all = false

    struct Report: Codable {
        var file: String
        /// Zusammengeführte Kernfelder: Sidecar-Werte überlagern eingebettete.
        var core: ImageCoreFields
        /// Pfad der XMP-Sidecar, falls eine neben dem Bild liegt.
        var sidecar: String?
        /// Kernfelder, deren Wert aus der Sidecar stammt.
        var sidecarFields: [String]
        /// Wohin `exif set` ohne `--sidecar` schreiben würde (Grund, siehe
        /// `ImageWriteDestination.Reason`).
        var writeTarget: String
        var groups: [MetadataGroup]?
    }

    /// Beide exiftool-Aufrufe als ein Lesewert, damit `FileSnapshot` sie
    /// gemeinsam gegen den Dateistempel absichern kann.
    private struct Reading: Sendable {
        let core: ImageCoreReading
        let groups: [MetadataGroup]?
    }

    func run() throws {
        let url = try resolveFile(file)
        // Kernfelder und Gruppen kommen aus zwei getrennten exiftool-Läufen.
        // Der gemeinsame Schnappschuss prüft den Dateistempel vor und nach
        // beiden Läufen; die Prüfung direkt vor der Ausgabe schließt das
        // letzte Zeitfenster. Sonst könnte `core` aus der alten und `groups`
        // aus einer neuen Fassung stammen.
        let snapshot = try FileSnapshot.capture(at: url) {
            let core = try ExifTool.readCoreReading(url: url)
            let groups = all ? try ExifTool.readAllGroups(url: url) : nil
            return Reading(core: core, groups: groups)
        }
        try snapshot.requireCurrent(at: url)
        try snapshot.value.core.requireUnchangedSidecar(for: url)
        let reading = snapshot.value.core
        let core = reading.fields
        let groups = snapshot.value.groups
        let sidecarFields = ImageCoreFieldKey.allCases
            .filter { reading.sidecarFields.contains($0) }.map(\.rawValue)
        let destination = ExifTool.writeDestination(for: url, preferSidecar: false)
        if json {
            try printJSON(Report(
                file: url.path, core: core, sidecar: reading.sidecarURL?.path,
                sidecarFields: sidecarFields, writeTarget: destination.reason.rawValue,
                groups: groups))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        line("SIDECAR", reading.sidecarURL?.path ?? "")
        line("SIDECAR_FIELDS", sidecarFields.joined(separator: ","))
        if destination.isSidecar { line("WRITE_TARGET", destination.reason.rawValue) }
        line("TITLE", core.title)
        line("DESCRIPTION", core.description)
        line("KEYWORDS", core.keywords.joined(separator: ", "))
        line("CREATOR", core.creator)
        line("COPYRIGHT", core.copyright)
        line("DATE", core.dateTimeOriginal)
        // Ausgegeben wird jeder vorhandene Wert — auch ein negativer
        // Bestandswert. Die Textausgabe verschwieg ihn, während --json ihn
        // zeigte (Review-Fund 2026-08-20).
        if let rating = core.rating { print("RATING=\(rating)") }
        if !core.gpsLatitude.isEmpty { print("GPS=\(core.gpsLatitude),\(core.gpsLongitude)") }
        if let groups {
            for group in groups {
                print("\n[\(group.name)]")
                for field in group.fields {
                    print("\(field.key)=\(field.value)")
                }
            }
        }
    }
}

struct ExifSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Set core fields (an empty value deletes the field).")

    @Argument(help: "Image file") var file: String
    @Option(help: "Title") var title: String?
    @Option(help: "Description") var description: String?
    @Option(help: "Keywords, comma-separated") var keywords: String?
    @Option(help: "Creator/photographer") var creator: String?
    @Option(help: "Copyright") var copyright: String?
    @Option(help: "Capture date (YYYY:MM:DD HH:MM:SS)") var date: String?
    @Option(help: "Rating -1–5 (use --rating=-1 for rejected), empty deletes") var rating: String?
    @Option(help: "GPS as \"lat,lon\" in decimal degrees, empty deletes") var gps: String?
    @Option(parsing: .upToNextOption,
            help: """
            Copy the value of a raw tag into a core field (TARGET=Group:Tag), \
            e.g. --copy description=IFD0:ImageDescription. Targets: title, \
            description, keywords, creator, copyright (text fields only — \
            rating/GPS take no free text). Groups as in `exif show --all`.
            """)
    var copy: [String] = []
    @Flag(name: .long,
          help: """
          Write into the XMP sidecar <name>.xmp next to the image instead of \
          the image itself (created if missing). Always on for camera RAW \
          (cr2, cr3, nef, arw, raf, orf, rw2, pef), for formats exiftool \
          cannot write (bmp, svg) and whenever a sidecar already exists.
          """)
    var sidecar = false
    @OptionGroup var safeMode: SafeModeOptions

    /// Textuelle Kernfelder, in die kopiert werden darf (Typkompatibilität:
    /// Text zu Text; Bewertung/GPS/Datum sind bewusst ausgenommen).
    private static let copyTargets = ["title", "description", "keywords", "creator", "copyright"]

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try ExifTool.readCoreFieldsSnapshot(url: url)
        let original = snapshot.value.fields
        var fields = original
        if let title { fields.title = title }
        if let description { fields.description = description }
        if let keywords { fields.keywords = keywords.splitCommaList() }
        if let creator { fields.creator = creator }
        if let copyright { fields.copyright = copyright }
        if let date { fields.dateTimeOriginal = date }
        if let rating {
            if rating.isEmpty {
                fields.rating = nil
            } else {
                // −1 ist ein echter XMP-Wert („abgelehnt“), kein Leerwert.
                // Nur ein explizit leerer Optionswert löscht das Tag.
                guard let parsed = Int(rating), (-1...5).contains(parsed) else {
                    throw ValidationError(
                        "Rating must be an integer from -1 (rejected) to 5; "
                            + "use an explicit empty value to delete it.")
                }
                fields.rating = parsed
            }
        }
        if let gps {
            if gps.isEmpty {
                fields.gpsLatitude = ""
                fields.gpsLongitude = ""
            } else {
                let parts = gps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else {
                    throw ValidationError("GPS format: \"lat,lon\" (decimal degrees)")
                }
                fields.gpsLatitude = parts[0]
                fields.gpsLongitude = parts[1]
            }
        }
        // Kopier-Zuweisungen NACH den direkten Optionen: Quellwert aus den
        // rohen Gruppen (EXIF/IPTC/XMP …) in ein Text-Kernfeld übernehmen —
        // geschrieben wird anschließend MWG-harmonisiert.
        if !copy.isEmpty {
            let raw = try ExifTool.readRawStringTags(urls: [url])[url.path] ?? [:]
            // Kernfelder und Roh-Tags müssen weiterhin dieselbe Dateifassung
            // beschreiben; der zweite exiftool-Aufruf darf nicht unbemerkt auf
            // eine zwischenzeitlich ersetzte Datei wechseln.
            try snapshot.requireCurrent(at: url)
            try snapshot.value.requireUnchangedSidecar(for: url)
            for assignment in copy {
                guard let eq = assignment.firstIndex(of: "=") else {
                    throw ValidationError("Invalid copy assignment (expected TARGET=Group:Tag): \(assignment)")
                }
                let target = String(assignment[..<eq]).lowercased()
                let source = String(assignment[assignment.index(after: eq)...])
                guard Self.copyTargets.contains(target) else {
                    throw ValidationError(
                        "Target \(target) is not a text field — allowed: \(Self.copyTargets.joined(separator: ", "))")
                }
                guard let value = raw[source], !value.isEmpty else {
                    FileHandle.standardError.write(
                        Data("Note: source \(source) is empty or not a text tag — \(target) unchanged\n".utf8))
                    continue
                }
                switch target {
                case "title": fields.title = value
                case "description": fields.description = value
                case "keywords": fields.keywords = value.splitCommaList()
                case "creator": fields.creator = value
                case "copyright": fields.copyright = value
                default: break
                }
            }
        }
        do {
            try ExifTool.requireValidCoreFields(fields, original: original)
        } catch let error as ImageMetadataValidationError {
            throw ValidationError(error.localizedDescription)
        }
        guard fields != original else {
            try snapshot.requireCurrent(at: url)
            try snapshot.value.requireUnchangedSidecar(for: url)
            print("No changes")
            return
        }
        try snapshot.requireCurrent(at: url)
        try snapshot.value.requireUnchangedSidecar(for: url)
        // Gesichert wird die Datei, die sich wirklich ändert: bei einem
        // Sidecar-Ziel die .xmp (eine noch fehlende Sidecar überspringt die
        // Sicherung — es gibt nichts zu sichern), sonst das Bild.
        let destination = ExifTool.writeDestination(for: url, preferSidecar: sidecar)
        try TrashBackup.shared.backUp(destination.url)
        try ExifTool.writeCoreFields(
            url: url, fields: fields, original: original, expecting: snapshot.stamp,
            to: destination, sidecar: snapshot.value.sidecar)
        if destination.isSidecar {
            print("OK \(url.lastPathComponent) -> \(destination.url.lastPathComponent) (\(destination.reason.rawValue))")
        } else {
            print("OK \(url.lastPathComponent)")
        }
    }
}

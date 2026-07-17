// tagx exif — Bild-Metadaten (EXIF/IPTC/XMP) anzeigen und setzen.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Exif: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exif",
        abstract: "Bild-Metadaten anzeigen und bearbeiten (EXIF/IPTC/XMP via exiftool).",
        subcommands: [ExifShow.self, ExifSet.self],
        defaultSubcommand: ExifShow.self
    )
}

struct ExifShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Kernfelder und alle Metadaten-Gruppen anzeigen.")

    @Argument(help: "Bilddatei") var file: String
    @Flag(name: .long, help: "Ausgabe als JSON") var json = false
    @Flag(name: .long, help: "Alle Gruppen ausgeben (sonst nur Kernfelder)") var all = false

    struct Report: Codable {
        var file: String
        var core: ImageCoreFields
        var groups: [MetadataGroup]?
    }

    func run() throws {
        let url = try resolveFile(file)
        let core = try ExifTool.readCoreFields(url: url)
        let groups = all ? try ExifTool.readAllGroups(url: url) : nil
        if json {
            try printJSON(Report(file: url.path, core: core, groups: groups))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        line("TITLE", core.title)
        line("DESCRIPTION", core.description)
        line("KEYWORDS", core.keywords.joined(separator: ", "))
        line("CREATOR", core.creator)
        line("COPYRIGHT", core.copyright)
        line("DATE", core.dateTimeOriginal)
        if core.rating >= 0 { print("RATING=\(core.rating)") }
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
        commandName: "set", abstract: "Kernfelder setzen (leerer Wert löscht das Feld).")

    @Argument(help: "Bilddatei") var file: String
    @Option(help: "Titel") var title: String?
    @Option(help: "Beschreibung") var description: String?
    @Option(help: "Schlagwörter, kommagetrennt") var keywords: String?
    @Option(help: "Ersteller/Fotograf") var creator: String?
    @Option(help: "Copyright") var copyright: String?
    @Option(help: "Aufnahmedatum (YYYY:MM:DD HH:MM:SS)") var date: String?
    @Option(help: "Bewertung 0–5, leer löscht") var rating: String?
    @Option(help: "GPS als \"lat,lon\" in Dezimalgrad, leer löscht") var gps: String?
    @Option(parsing: .upToNextOption,
            help: """
            Wert eines rohen Tags in ein Kernfeld übernehmen (ZIEL=Gruppe:Tag), \
            z.B. --copy description=IFD0:ImageDescription. Ziele: title, \
            description, keywords, creator, copyright (nur Textfelder — in \
            Bewertung/GPS passt kein freier Text). Gruppen wie in `exif show --all`.
            """)
    var copy: [String] = []

    /// Textuelle Kernfelder, in die kopiert werden darf (Typkompatibilität:
    /// Text zu Text; Bewertung/GPS/Datum sind bewusst ausgenommen).
    private static let copyTargets = ["title", "description", "keywords", "creator", "copyright"]

    func run() throws {
        let url = try resolveFile(file)
        let original = try ExifTool.readCoreFields(url: url)
        var fields = original
        if let title { fields.title = title }
        if let description { fields.description = description }
        if let keywords {
            fields.keywords = keywords.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if let creator { fields.creator = creator }
        if let copyright { fields.copyright = copyright }
        if let date { fields.dateTimeOriginal = date }
        if let rating { fields.rating = rating.isEmpty ? -1 : (Int(rating) ?? -1) }
        if let gps {
            if gps.isEmpty {
                fields.gpsLatitude = ""
                fields.gpsLongitude = ""
            } else {
                let parts = gps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else {
                    throw ValidationError("GPS-Format: \"lat,lon\" (Dezimalgrad)")
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
            for assignment in copy {
                guard let eq = assignment.firstIndex(of: "=") else {
                    throw ValidationError("Ungültige Kopier-Zuweisung (ZIEL=Gruppe:Tag erwartet): \(assignment)")
                }
                let target = String(assignment[..<eq]).lowercased()
                let source = String(assignment[assignment.index(after: eq)...])
                guard Self.copyTargets.contains(target) else {
                    throw ValidationError(
                        "Ziel \(target) ist kein Textfeld — erlaubt: \(Self.copyTargets.joined(separator: ", "))")
                }
                guard let value = raw[source], !value.isEmpty else {
                    FileHandle.standardError.write(
                        Data("Hinweis: Quelle \(source) ist leer oder kein Text-Tag — \(target) unverändert\n".utf8))
                    continue
                }
                switch target {
                case "title": fields.title = value
                case "description": fields.description = value
                case "keywords":
                    fields.keywords = value.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                case "creator": fields.creator = value
                case "copyright": fields.copyright = value
                default: break
                }
            }
        }
        guard fields != original else {
            print("Keine Änderungen")
            return
        }
        try ExifTool.writeCoreFields(url: url, fields: fields, original: original)
        print("OK \(url.lastPathComponent)")
    }
}

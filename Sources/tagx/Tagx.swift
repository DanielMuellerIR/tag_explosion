// tagx — CLI von Tag Explosion. Headless-steuerbar, maschinenlesbare Ausgabe.
// Exit-Codes: 0 = ok, 1 = Fehler (Beschreibung auf stderr).
import ArgumentParser
import Foundation
import TagExplosionCore

@main
struct Tagx: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tagx",
        abstract: "Show and edit media metadata (Tag Explosion CLI).",
        version: tagxVersion,
        subcommands: [Show.self, Set.self, Cover.self, Info.self, Exif.self, Ebook.self,
                      Invoice.self, Export.self, Import.self],
        defaultSubcommand: Show.self
    )
}

/// Version aus der beim Build eingebetteten VERSION-Datei; Fallback "dev".
let tagxVersion: String = {
    // build.sh reicht die Version via Umgebung/Generierung; im swift-run-Fall
    // lesen wir die VERSION-Datei relativ zum Repo, sonst "dev".
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
    let fm = FileManager.default
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("VERSION")
        if fm.fileExists(atPath: candidate.path),
           let s = try? String(contentsOf: candidate, encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        dir.deleteLastPathComponent()
    }
    return "dev"
}()

// MARK: - Gemeinsame Helfer

/// Datei-Argument prüfen und als URL liefern.
func resolveFile(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ValidationError("File not found: \(path)")
    }
    return url
}

/// Gemeinsame Optionen aller ändernden Unterbefehle.
///
/// Abgesicherter Modus: Vor jeder Änderung wandert eine unveränderte Kopie der
/// Datei in den Papierkorb. Standard ist an; abschalten per `--no-backup` oder
/// `TAGX_NO_BACKUP=1` (für Skripte, die selbst sichern).
struct SafeModeOptions: ParsableArguments {
    @Flag(name: .long, help: "Do not copy files to the trash before changing them")
    var noBackup = false

    /// Muss zu Beginn jedes ändernden `run()` aufgerufen werden.
    func apply() {
        let envDisabled = ProcessInfo.processInfo.environment["TAGX_NO_BACKUP"]
            .map { $0 == "1" || $0.lowercased() == "true" } ?? false
        TrashBackup.shared.isEnabled = !(noBackup || envDisabled)
    }
}

/// Objekt als hübsches JSON auf stdout schreiben.
func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

// MARK: - show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show tags, cover art, and audio properties of a file."
    )

    @Argument(help: "Media file(s)") var files: [String]
    @Flag(name: .long, help: "Output as JSON") var json = false

    /// JSON-Struktur für --json (Cover nur als Metadaten, nicht die Bytes).
    struct FileReport: Codable {
        struct ArtworkMeta: Codable {
            var mimeType: String
            var pictureType: String
            var description: String
            var bytes: Int
        }
        var file: String
        var readOnly: Bool
        var audio: AudioInfo?
        var properties: [TagProperty]
        var artworks: [ArtworkMeta]
    }

    func run() throws {
        var reports: [FileReport] = []
        for path in files {
            let url = try resolveFile(path)
            let data = try TagFile.read(at: url)
            let report = FileReport(
                file: url.path,
                readOnly: data.isReadOnly,
                audio: data.audio,
                properties: data.properties,
                artworks: data.artworks.map {
                    .init(mimeType: $0.resolvedMimeType, pictureType: $0.pictureType,
                          description: $0.description, bytes: $0.data.count)
                }
            )
            reports.append(report)
        }

        if json {
            try printJSON(reports.count == 1 ? [reports[0]] : reports)
            return
        }
        for report in reports {
            if reports.count > 1 { print("== \(report.file)") }
            if let a = report.audio {
                let seconds = Double(a.lengthMilliseconds) / 1000.0
                print(String(format: "# %.1f s · %d kbps · %d Hz · %d channel(s)%@",
                             seconds, a.bitrateKbps, a.sampleRateHz, a.channels,
                             report.readOnly ? " · READ-ONLY" : ""))
            }
            for prop in report.properties {
                print("\(prop.key)=\(prop.value)")
            }
            for art in report.artworks {
                print("COVER: \(art.pictureType.isEmpty ? "?" : art.pictureType) · \(art.mimeType) · \(art.bytes) bytes")
            }
        }
    }
}

// MARK: - set

struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set/delete tag fields (KEY=VALUE; an empty value deletes the field)."
    )

    @Argument(help: "Media file") var file: String
    @Option(name: .shortAndLong, parsing: .upToNextOption,
            help: "Field assignments, e.g. -t ARTIST=Miles TITLE='So What'") var tag: [String] = []
    @Option(name: .shortAndLong, parsing: .upToNextOption,
            help: "Copy the value of another field (TARGET=SOURCE), e.g. -c ALBUMARTIST=ARTIST")
    var copy: [String] = []
    @Flag(name: .long, help: "Remove all existing fields first") var replaceAll = false
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        guard !tag.isEmpty || !copy.isEmpty else {
            throw ValidationError("Provide at least one -t KEY=VALUE or -c TARGET=SOURCE.")
        }
        let url = try resolveFile(file)
        // Gelesen wird vorab; geschrieben wird ausschließlich über den
        // atomaren Weg in `TagFile.write`, nie in-place auf dem Original.
        // Inhalt und Stempel gehören zusammen: Verändert ein anderes Programm
        // die Datei WÄHREND des Lesens, passt der Stempel zu einer neueren
        // Fassung als der gelesene Inhalt — dann lieber abbrechen als auf
        // unklarer Grundlage entscheiden.
        let snapshot = try FileSnapshot.capture(at: url) {
            try TagFile.read(at: url)
        }
        let existing = snapshot.value

        var properties: [TagProperty] = replaceAll ? [] : existing.properties
        for assignment in tag {
            guard let eq = assignment.firstIndex(of: "=") else {
                throw ValidationError("Invalid assignment (expected KEY=VALUE): \(assignment)")
            }
            let rawKey = String(assignment[..<eq])
            guard !rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Invalid assignment (the key must not be empty): \(assignment)")
            }
            let key = rawKey.uppercased()
            let value = String(assignment[assignment.index(after: eq)...])
            // Bestehende Werte des Keys entfernen; nicht-leerer Wert wird neu gesetzt.
            properties.removeAll { $0.key == key }
            if !value.isEmpty {
                properties.append(TagProperty(key: key, value: value))
            }
        }
        // Kopier-Zuweisungen NACH den direkten Zuweisungen: pro Datei werden
        // ALLE Werte der Quelle übernommen (mehrwertige Felder bleiben ganz).
        for assignment in copy {
            guard let eq = assignment.firstIndex(of: "=") else {
                throw ValidationError("Invalid copy assignment (expected TARGET=SOURCE): \(assignment)")
            }
            let rawTarget = String(assignment[..<eq])
            let rawSource = String(assignment[assignment.index(after: eq)...])
            guard !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError(
                    "Invalid copy assignment (target and source must not be empty): \(assignment)")
            }
            let target = rawTarget.uppercased()
            let source = rawSource.uppercased()
            let values = properties.filter { $0.key == source }.map(\.value)
            guard !values.isEmpty else {
                FileHandle.standardError.write(
                    Data("Note: source \(source) is empty — \(target) unchanged\n".utf8))
                continue
            }
            properties.removeAll { $0.key == target }
            properties.append(contentsOf: values.map { TagProperty(key: target, value: $0) })
        }

        // Gezählt und geschrieben wird nur, was sich wirklich ändert: Ein
        // semantischer No-op (alle Sollwerte entsprechen dem Dateizustand)
        // darf weder Dateiidentität/Zeitstempel anfassen noch eine Sicherung
        // erzeugen — und die Meldung soll die echte Änderungszahl nennen.
        func valueMap(_ properties: [TagProperty]) -> [String: [String]] {
            var map: [String: [String]] = [:]
            for property in properties {
                map[property.key, default: []].append(property.value)
            }
            return map
        }
        let before = valueMap(existing.properties)
        let after = valueMap(properties)
        // Swift.Set: "Set" ist in dieser Datei der Name des CLI-Befehls.
        let changedKeys = Swift.Set(before.keys).union(after.keys)
            .filter { (before[$0] ?? []) != (after[$0] ?? []) }
        guard !changedKeys.isEmpty else {
            // Der Vergleich beruht auf dem Lesestand von oben. Erst die
            // Stempel-Prüfung macht die Erfolgsmeldung ehrlich: Hat ein anderes
            // Programm die Datei inzwischen auf einen abweichenden Wert
            // gesetzt, wäre "0 field(s) changed" eine falsche Zusicherung —
            // der gewünschte Sollwert stünde gar nicht in der Datei.
            try snapshot.requireCurrent(at: url)
            print("OK \(url.lastPathComponent): 0 field(s) changed")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url)
        try TagFile.write(properties: properties, to: url, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent): \(changedKeys.count) field(s) changed")
    }
}

// MARK: - cover

struct Cover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export, set, or remove cover art.",
        subcommands: [Export.self, CoverSet.self, Remove.self]
    )

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export", abstract: "Export embedded images to files.")

        @Argument(help: "Media file") var file: String
        @Option(name: .shortAndLong, help: "Target directory (default: next to the file)") var output: String?

        func run() throws {
            let url = try resolveFile(file)
            let data = try TagFile.read(at: url)
            guard !data.artworks.isEmpty else {
                throw ValidationError("No embedded images in \(url.lastPathComponent)")
            }
            let outDir = output.map { URL(fileURLWithPath: $0) }
                ?? url.deletingLastPathComponent()
            let exports = data.artworks.enumerated().map { i, art in
                let ext: String
                switch art.resolvedMimeType {
                case "image/png": ext = "png"
                case "image/gif": ext = "gif"
                case "image/webp": ext = "webp"
                case "image/bmp": ext = "bmp"
                case "image/jpeg": ext = "jpg"
                default: ext = "bin"
                }
                let base = url.deletingPathExtension().lastPathComponent
                let suffix = data.artworks.count > 1 ? "-\(i + 1)" : ""
                let target = outDir.appendingPathComponent("\(base)-cover\(suffix).\(ext)")
                return (art: art, target: target)
            }
            // Erst alle Kollisionen prüfen, damit ein späteres Cover nicht nach
            // bereits geschriebenen Vorgängern zum Teil-Export führt.
            for export in exports where FileManager.default.fileExists(atPath: export.target.path) {
                throw ValidationError("Output file already exists: \(export.target.path)")
            }
            for export in exports {
                do {
                    // Die exklusive Schreiboption schließt auch das Rennen
                    // zwischen Vorprüfung und tatsächlichem Anlegen der Datei.
                    try export.art.data.write(to: export.target, options: .withoutOverwriting)
                } catch where FileManager.default.fileExists(atPath: export.target.path) {
                    throw ValidationError("Output file already exists: \(export.target.path)")
                }
                print(export.target.path)
            }
        }
    }

    struct CoverSet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Set cover art (replaces existing images).")

        @Argument(help: "Media file") var file: String
        @Argument(help: "Image file (jpg/png/…)") var image: String
        @OptionGroup var safeMode: SafeModeOptions

        func run() throws {
            safeMode.apply()
            let url = try resolveFile(file)
            let imageURL = try resolveFile(image)
            // Ausgangsstand der Zieldatei, bevor irgendetwas anderes gelesen
            // wird. Der Stempel wandert bis in den atomaren Austausch: Wird die
            // Datei zwischen Sicherung und rename ersetzt (oder ein Symlink
            // umgebogen), bricht das Schreiben ab, statt eine fremde, nicht
            // gesicherte Fassung zu überschreiben.
            guard let stamp = FileStamp.current(of: url) else {
                throw TagError.cannotOpen(path: url.path)
            }
            let imageData = try Data(contentsOf: imageURL)
            guard Artwork.sniffMimeType(from: imageData) != nil else {
                throw ValidationError("Unsupported cover image: \(imageURL.path)")
            }
            let artwork = Artwork(data: imageData, pictureType: "Front Cover")
            try FileStamp.requireUnchanged(stamp, at: url)
            try TrashBackup.shared.backUp(url)
            try TagFile.write(artworks: [artwork], to: url, expecting: stamp)
            print("OK \(url.lastPathComponent): cover set (\(imageData.count) bytes)")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Remove all embedded images.")

        @Argument(help: "Media file") var file: String
        @OptionGroup var safeMode: SafeModeOptions

        func run() throws {
            safeMode.apply()
            let url = try resolveFile(file)
            // Gleiche Absicherung wie bei `cover set`: Gesichert und
            // geschrieben werden muss dieselbe Dateifassung.
            guard let stamp = FileStamp.current(of: url) else {
                throw TagError.cannotOpen(path: url.path)
            }
            try TrashBackup.shared.backUp(url)
            try TagFile.write(artworks: [], to: url, expecting: stamp)
            print("OK \(url.lastPathComponent): images removed")
        }
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the full technical report via mediainfo."
    )

    @Argument(help: "Media file") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    func run() throws {
        let url = try resolveFile(file)
        let report = try MediaInfoReader.read(url: url)
        if json {
            try printJSON(report.tracks)
        } else {
            print(report.text)
        }
    }
}

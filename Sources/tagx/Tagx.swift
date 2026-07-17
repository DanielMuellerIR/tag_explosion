// tagx — CLI von Tag Explosion. Headless-steuerbar, maschinenlesbare Ausgabe.
// Exit-Codes: 0 = ok, 1 = Fehler (Beschreibung auf stderr).
import ArgumentParser
import Foundation
import TagExplosionCore

@main
struct Tagx: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tagx",
        abstract: "Medien-Tags anzeigen und bearbeiten (Tag Explosion CLI).",
        version: tagxVersion,
        subcommands: [Show.self, Set.self, Cover.self, Info.self, Exif.self, Ebook.self,
                      Export.self, Import.self],
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
        throw ValidationError("Datei nicht gefunden: \(path)")
    }
    return url
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
        abstract: "Tags, Cover und Audio-Eigenschaften einer Datei anzeigen."
    )

    @Argument(help: "Mediendatei(en)") var files: [String]
    @Flag(name: .long, help: "Ausgabe als JSON") var json = false

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
                print(String(format: "# %.1f s · %d kbps · %d Hz · %d Kanäle%@",
                             seconds, a.bitrateKbps, a.sampleRateHz, a.channels,
                             report.readOnly ? " · SCHREIBGESCHÜTZT" : ""))
            }
            for prop in report.properties {
                print("\(prop.key)=\(prop.value)")
            }
            for art in report.artworks {
                print("COVER: \(art.pictureType.isEmpty ? "?" : art.pictureType) · \(art.mimeType) · \(art.bytes) Bytes")
            }
        }
    }
}

// MARK: - set

struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tag-Felder setzen/löschen (KEY=WERT; leerer Wert löscht das Feld)."
    )

    @Argument(help: "Mediendatei") var file: String
    @Option(name: .shortAndLong, parsing: .upToNextOption,
            help: "Feld-Zuweisungen, z.B. -t ARTIST=Miles TITLE=So What") var tag: [String] = []
    @Option(name: .shortAndLong, parsing: .upToNextOption,
            help: "Wert eines anderen Feldes übernehmen (ZIEL=QUELLE), z.B. -c ALBUMARTIST=ARTIST")
    var copy: [String] = []
    @Flag(name: .long, help: "Alle vorhandenen Felder vorher entfernen") var replaceAll = false

    func run() throws {
        guard !tag.isEmpty || !copy.isEmpty else {
            throw ValidationError("Mindestens ein -t KEY=WERT oder -c ZIEL=QUELLE angeben.")
        }
        let url = try resolveFile(file)
        let tagFile = try TagFile(url: url)
        defer { tagFile.close() }

        var properties = replaceAll ? [] : (try tagFile.properties())
        for assignment in tag {
            guard let eq = assignment.firstIndex(of: "=") else {
                throw ValidationError("Ungültige Zuweisung (KEY=WERT erwartet): \(assignment)")
            }
            let key = String(assignment[..<eq]).uppercased()
            let value = String(assignment[assignment.index(after: eq)...])
            // Bestehende Werte des Keys entfernen; nicht-leerer Wert wird neu gesetzt.
            properties.removeAll { $0.key == key }
            if !value.isEmpty {
                properties.append(TagProperty(key: key, value: value))
            }
        }
        // Kopier-Zuweisungen NACH den direkten Zuweisungen: pro Datei werden
        // ALLE Werte der Quelle übernommen (mehrwertige Felder bleiben ganz).
        var changed = tag.count
        for assignment in copy {
            guard let eq = assignment.firstIndex(of: "=") else {
                throw ValidationError("Ungültige Kopier-Zuweisung (ZIEL=QUELLE erwartet): \(assignment)")
            }
            let target = String(assignment[..<eq]).uppercased()
            let source = String(assignment[assignment.index(after: eq)...]).uppercased()
            let values = properties.filter { $0.key == source }.map(\.value)
            guard !values.isEmpty else {
                FileHandle.standardError.write(
                    Data("Hinweis: Quelle \(source) ist leer — \(target) unverändert\n".utf8))
                continue
            }
            properties.removeAll { $0.key == target }
            properties.append(contentsOf: values.map { TagProperty(key: target, value: $0) })
            changed += 1
        }
        try tagFile.setProperties(properties)
        try tagFile.save()
        print("OK \(url.lastPathComponent): \(changed) Feld(er) geändert")
    }
}

// MARK: - cover

struct Cover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cover exportieren, setzen oder entfernen.",
        subcommands: [Export.self, CoverSet.self, Remove.self]
    )

    struct Export: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export", abstract: "Eingebettete Bilder als Dateien exportieren.")

        @Argument(help: "Mediendatei") var file: String
        @Option(name: .shortAndLong, help: "Zielverzeichnis (Standard: neben der Datei)") var output: String?

        func run() throws {
            let url = try resolveFile(file)
            let data = try TagFile.read(at: url)
            guard !data.artworks.isEmpty else {
                throw ValidationError("Keine eingebetteten Bilder in \(url.lastPathComponent)")
            }
            let outDir = output.map { URL(fileURLWithPath: $0) }
                ?? url.deletingLastPathComponent()
            for (i, art) in data.artworks.enumerated() {
                let ext: String
                switch art.resolvedMimeType {
                case "image/png": ext = "png"
                case "image/gif": ext = "gif"
                case "image/webp": ext = "webp"
                default: ext = "jpg"
                }
                let base = url.deletingPathExtension().lastPathComponent
                let suffix = data.artworks.count > 1 ? "-\(i + 1)" : ""
                let target = outDir.appendingPathComponent("\(base)-cover\(suffix).\(ext)")
                try art.data.write(to: target)
                print(target.path)
            }
        }
    }

    struct CoverSet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Cover setzen (ersetzt vorhandene Bilder).")

        @Argument(help: "Mediendatei") var file: String
        @Argument(help: "Bilddatei (jpg/png/…)") var image: String

        func run() throws {
            let url = try resolveFile(file)
            let imageURL = try resolveFile(image)
            let imageData = try Data(contentsOf: imageURL)
            let artwork = Artwork(data: imageData, pictureType: "Front Cover")
            try TagFile.write(artworks: [artwork], to: url)
            print("OK \(url.lastPathComponent): Cover gesetzt (\(imageData.count) Bytes)")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Alle eingebetteten Bilder entfernen.")

        @Argument(help: "Mediendatei") var file: String

        func run() throws {
            let url = try resolveFile(file)
            try TagFile.write(artworks: [], to: url)
            print("OK \(url.lastPathComponent): Bilder entfernt")
        }
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Vollständige technische Details via mediainfo anzeigen."
    )

    @Argument(help: "Mediendatei") var file: String
    @Flag(name: .long, help: "Ausgabe als JSON") var json = false

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

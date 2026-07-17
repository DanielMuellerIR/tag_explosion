// E-Book-/Dokument-Metadaten (Umfang wie Calibres Metadaten-Dialog).
// Hybrid-Backend, je nach Format:
// - EPUB: nativ im Core (ZIP + OPF-XML, siehe EpubFile) — keine externen Tools.
// - PDF: über exiftool (Info-Dict + XMP), lesen UND schreiben.
// - mobi/azw3/fb2: NUR falls Calibre installiert ist, über dessen CLI
//   `ebook-meta` (GPL — ausschließlich als externes Programm aufgerufen,
//   gleiche Lizenz-Trennung wie mediainfo/exiftool).
import Foundation

/// Editierbare Kernfelder eines E-Books/Dokuments.
public struct EbookCoreFields: Sendable, Codable, Equatable {
    public var title: String
    /// Autor(en), mehrwertig.
    public var authors: [String]
    public var series: String
    /// Serienindex als String ("1", "2.5" …); leer = keiner.
    public var seriesIndex: String
    /// Klappentext/Beschreibung (kann HTML enthalten).
    public var description: String
    public var isbn: String
    public var publisher: String
    /// Sprachcode, z.B. "de" oder "deu".
    public var language: String
    /// Veröffentlichungsdatum, ISO 8601 (Datum reicht).
    public var date: String
    /// Schlagwörter, mehrwertig.
    public var subjects: [String]

    public init(title: String = "", authors: [String] = [], series: String = "",
                seriesIndex: String = "", description: String = "", isbn: String = "",
                publisher: String = "", language: String = "", date: String = "",
                subjects: [String] = []) {
        self.title = title
        self.authors = authors
        self.series = series
        self.seriesIndex = seriesIndex
        self.description = description
        self.isbn = isbn
        self.publisher = publisher
        self.language = language
        self.date = date
        self.subjects = subjects
    }
}

public enum EbookTool {

    /// Backend je Dateiendung.
    public enum Backend: Sendable {
        case epub      // nativ
        case pdf       // exiftool
        case calibre   // ebook-meta (mobi/azw3/fb2)
    }

    /// Endungen, die immer unterstützt werden.
    public static let builtinExtensions: Set<String> = ["epub", "pdf"]
    /// Endungen, die zusätzlich Calibres `ebook-meta` benötigen.
    public static let calibreExtensions: Set<String> = ["mobi", "azw3", "fb2"]

    public static func backend(for url: URL) -> Backend? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case let ext where calibreExtensions.contains(ext): return .calibre
        default: return nil
        }
    }

    // MARK: - Calibre auffinden

    public static let calibreCandidates: [String] = [
        "ebook-meta",
        "/opt/homebrew/bin/ebook-meta",
        "/usr/local/bin/ebook-meta",
        "/usr/bin/ebook-meta",
        "/Applications/calibre.app/Contents/MacOS/ebook-meta",
    ]

    public static func locateCalibre() throws -> String {
        for candidate in calibreCandidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if let found = which(candidate) {
                return found
            }
        }
        throw TagError.toolNotFound(name: "ebook-meta (Calibre)")
    }

    /// Ist Calibre da? (Entscheidet, ob mobi/azw3/fb2 angeboten werden.)
    public static var calibreAvailable: Bool {
        (try? locateCalibre()) != nil
    }

    // MARK: - Lesen/Schreiben (Dispatcher)

    public static func readCoreFields(url: URL) throws -> EbookCoreFields {
        switch backend(for: url) {
        case .epub: return try EpubFile.readCoreFields(url: url)
        case .pdf: return try readPdf(url: url)
        case .calibre: return try readCalibre(url: url)
        case nil: throw TagError.cannotOpen(path: url.path)
        }
    }

    /// Schreibt nur die Unterschiede zu `original`; leerer Wert löscht.
    public static func writeCoreFields(
        url: URL, fields: EbookCoreFields, original: EbookCoreFields
    ) throws {
        guard fields != original else { return }
        switch backend(for: url) {
        case .epub: try EpubFile.writeCoreFields(url: url, fields: fields, original: original)
        case .pdf: try writePdf(url: url, fields: fields, original: original)
        case .calibre: try writeCalibre(url: url, fields: fields, original: original)
        case nil: throw TagError.cannotOpen(path: url.path)
        }
    }

    /// Kann dieses Format ein Cover tragen? (PDF nicht.)
    public static func supportsCover(url: URL) -> Bool {
        backend(for: url) != .pdf
    }

    /// Kann dieses Format eine Serie speichern? (PDF nicht — exiftool kennt
    /// keinen Standard-Ort dafür; Serienfelder werden dort ignoriert.)
    public static func supportsSeries(url: URL) -> Bool {
        backend(for: url) != .pdf
    }

    public static func readCover(url: URL) throws -> Artwork? {
        switch backend(for: url) {
        case .epub: return try EpubFile.readCover(url: url)
        case .pdf, nil: return nil
        case .calibre:
            let exe = try locateCalibre()
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tagx-cover-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: temp) }
            _ = try runCalibre(exe, [url.path, "--get-cover", temp.path])
            guard let data = try? Data(contentsOf: temp), !data.isEmpty else { return nil }
            return Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                           pictureType: "Front Cover")
        }
    }

    public static func writeCover(url: URL, data: Data) throws {
        switch backend(for: url) {
        case .epub: try EpubFile.writeCover(url: url, data: data)
        case .pdf, nil: throw TagError.saveFailed(path: url.path)
        case .calibre:
            let exe = try locateCalibre()
            let ext = Artwork.sniffMimeType(from: data) == "image/png" ? "png" : "jpg"
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tagx-cover-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp)
            _ = try runCalibre(exe, [url.path, "--cover", temp.path])
        }
    }

    // MARK: - PDF via exiftool

    /// Tag-Zuordnung: Info-Dict (PDF:) und XMP werden gemeinsam geschrieben,
    /// gelesen wird bevorzugt XMP (exiftool-Reihenfolge der Argumente unten).
    private static func readPdf(url: URL) throws -> EbookCoreFields {
        let exe = try ExifTool.locateExecutable()
        let args = ["-j", "-XMP-dc:Title", "-PDF:Title", "-XMP-dc:Creator", "-PDF:Author",
                    "-XMP-dc:Description", "-PDF:Subject", "-XMP-dc:Subject", "-PDF:Keywords",
                    "-XMP-dc:Publisher", "-XMP-dc:Language", "-XMP-dc:Date",
                    "-XMP-prism:ISBN", url.path]
        let data = try MediaInfoReader.run(exe, args)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let dict = root.first
        else { return EbookCoreFields() }

        // exiftool liefert bei doppelt angefragten Tags ("Title" aus XMP und
        // PDF) nur EINEN Schlüssel — den zuletzt gelesenen; beide Quellen
        // landen also im selben Eintrag.
        var fields = EbookCoreFields()
        fields.title = ExifTool.stringify(dict["Title"])
        fields.authors = listify(dict["Creator"] ?? dict["Author"])
        fields.description = ExifTool.stringify(dict["Description"] ?? dict["Subject"])
        // XMP-dc:Subject (Liste) vor PDF:Keywords (ein String, kommagetrennt)
        if let subjectList = dict["Subject"] as? [Any] {
            fields.subjects = subjectList.map { ExifTool.stringify($0) }
        } else {
            fields.subjects = listify(dict["Keywords"])
        }
        fields.publisher = ExifTool.stringify(dict["Publisher"])
        fields.language = ExifTool.stringify(dict["Language"])
        // exiftool gibt Datumsangaben mit Doppelpunkten aus ("2023:11:05") —
        // auf ISO 8601 zurückführen (Projekt-Konvention).
        var date = ExifTool.stringify(dict["Date"])
        if date.count >= 10, date.dropFirst(4).first == ":", date.dropFirst(7).first == ":" {
            let day = date.prefix(10).replacingOccurrences(of: ":", with: "-")
            date = day + date.dropFirst(10)
        }
        fields.date = date
        fields.isbn = ExifTool.stringify(dict["ISBN"])
        return fields
    }

    private static func writePdf(url: URL, fields: EbookCoreFields, original: EbookCoreFields) throws {
        var args: [String] = []

        func assign(_ tags: [String], _ new: String, _ old: String) {
            guard new != old else { return }
            for tag in tags { args.append("-\(tag)=\(new)") } // leer löscht
        }
        assign(["XMP-dc:Title", "PDF:Title"], fields.title, original.title)
        assign(["XMP-dc:Description", "PDF:Subject"], fields.description, original.description)
        assign(["XMP-dc:Publisher"], fields.publisher, original.publisher)
        assign(["XMP-dc:Language"], fields.language, original.language)
        assign(["XMP-dc:Date"], fields.date, original.date)
        assign(["XMP-prism:ISBN"], fields.isbn, original.isbn)

        if fields.authors != original.authors {
            args.append("-XMP-dc:Creator=")
            for author in fields.authors where !author.isEmpty {
                args.append("-XMP-dc:Creator+=\(author)")
            }
            args.append("-PDF:Author=\(fields.authors.joined(separator: " & "))")
        }
        if fields.subjects != original.subjects {
            args.append("-XMP-dc:Subject=")
            for subject in fields.subjects where !subject.isEmpty {
                args.append("-XMP-dc:Subject+=\(subject)")
            }
            args.append("-PDF:Keywords=\(fields.subjects.joined(separator: ", "))")
        }
        // Serie: für PDF bewusst nicht unterstützt (kein Standard-Ort).

        guard !args.isEmpty else { return }
        let exe = try ExifTool.locateExecutable()
        _ = try MediaInfoReader.run(exe, ["-overwrite_original", "-m"] + args + [url.path])
    }

    // MARK: - mobi/azw3/fb2 via Calibre ebook-meta

    /// `ebook-meta <datei>` gibt "Label : Wert"-Zeilen aus; mit LC_ALL=C sind
    /// die Labels stabil englisch. Mehrzeilige Werte (Comments) werden über
    /// Fortsetzungszeilen angehängt.
    private static func readCalibre(url: URL) throws -> EbookCoreFields {
        let exe = try locateCalibre()
        let output = MediaInfoReader.decodeLossy(try runCalibre(exe, [url.path]))

        var values: [String: String] = [:]
        var currentKey: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            // Label-Zeilen: "Title               : Wert"
            if let colon = line.firstIndex(of: ":"),
               line.distance(from: line.startIndex, to: colon) <= 20,
               !line.hasPrefix(" ") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                values[key] = value
                currentKey = key
            } else if let key = currentKey {
                values[key] = (values[key] ?? "") + "\n" + line.trimmingCharacters(in: .whitespaces)
            }
        }

        var fields = EbookCoreFields()
        fields.title = values["Title"] ?? ""
        // "Author(s) : A & B [Sortiername]" — Sortier-Zusatz abtrennen
        var authors = values["Author(s)"] ?? ""
        if let bracket = authors.firstIndex(of: "[") {
            authors = String(authors[..<bracket])
        }
        fields.authors = authors.components(separatedBy: " & ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Unknown" }
        fields.publisher = values["Publisher"] ?? ""
        fields.description = (values["Comments"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        fields.language = values["Languages"] ?? ""
        fields.subjects = (values["Tags"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // "Series : Name #2.0"
        if let series = values["Series"], let hash = series.range(of: " #", options: .backwards) {
            fields.series = String(series[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            var index = String(series[hash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if index.hasSuffix(".0") { index = String(index.dropLast(2)) }
            fields.seriesIndex = index
        } else {
            fields.series = values["Series"] ?? ""
        }
        // "Published : 2020-01-01T00:00:00+00:00" — nur das Datum behalten
        if let published = values["Published"] {
            fields.date = String(published.prefix(10))
        }
        // "Identifiers : isbn:9781234567890, mobi-asin:…"
        if let identifiers = values["Identifiers"] {
            for identifier in identifiers.split(separator: ",") {
                let trimmed = identifier.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("isbn:") {
                    fields.isbn = String(trimmed.dropFirst("isbn:".count))
                    break
                }
            }
        }
        return fields
    }

    private static func writeCalibre(url: URL, fields: EbookCoreFields, original: EbookCoreFields) throws {
        var args: [String] = [url.path]
        if fields.title != original.title { args += ["--title", fields.title] }
        if fields.authors != original.authors {
            args += ["--authors", fields.authors.joined(separator: " & ")]
        }
        if fields.series != original.series { args += ["--series", fields.series] }
        if fields.seriesIndex != original.seriesIndex, !fields.seriesIndex.isEmpty {
            args += ["--index", fields.seriesIndex]
        }
        if fields.description != original.description { args += ["--comments", fields.description] }
        if fields.isbn != original.isbn { args += ["--isbn", fields.isbn] }
        if fields.publisher != original.publisher { args += ["--publisher", fields.publisher] }
        if fields.language != original.language { args += ["--language", fields.language] }
        if fields.date != original.date, !fields.date.isEmpty {
            // Reines Datum als UTC-Mitternacht übergeben — sonst interpretiert
            // Calibre lokal und die Ausgabe (UTC) rutscht einen Tag zurück.
            let date = fields.date.count == 10 ? fields.date + "T00:00:00+00:00" : fields.date
            args += ["--date", date]
        }
        if fields.subjects != original.subjects {
            args += ["--tags", fields.subjects.joined(separator: ",")]
        }
        guard args.count > 1 else { return }
        let exe = try locateCalibre()
        _ = try runCalibre(exe, args)
    }

    /// ebook-meta mit stabiler englischer Ausgabe (Labels sind lokalisiert).
    private static func runCalibre(_ executable: String, _ arguments: [String]) throws -> Data {
        try MediaInfoReader.run("/usr/bin/env", ["LC_ALL=C", executable] + arguments)
    }

    // MARK: - Intern

    private static func listify(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.map { ExifTool.stringify($0) }.filter { !$0.isEmpty }
        }
        let single = ExifTool.stringify(value)
        guard !single.isEmpty else { return [] }
        // Kommagetrennte Einzelwerte (PDF:Keywords, PDF:Author "A & B")
        if single.contains(",") {
            return single.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if single.contains(" & ") {
            return single.components(separatedBy: " & ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return [single]
    }

    private static func which(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

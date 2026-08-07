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

/// Cover-Anteil eines kombinierten E-Book-Schreibvorgangs.
public enum EbookCoverUpdate: Sendable {
    case unchanged
    case set(Data)
    case remove
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

    /// Einmal pro Prozess gesucht — eine Calibre-Installation ändert sich zur
    /// Laufzeit nicht, und der Pfad-Scan liefe sonst bei jeder Datei-Operation.
    private static let calibreLocation: String? =
        try? MediaInfoReader.locateTool(candidates: calibreCandidates, name: "ebook-meta")

    public static func locateCalibre() throws -> String {
        guard let calibreLocation else { throw TagError.toolNotFound(name: "ebook-meta (Calibre)") }
        return calibreLocation
    }

    /// Ist Calibre da? (Entscheidet, ob mobi/azw3/fb2 angeboten werden.)
    public static var calibreAvailable: Bool {
        calibreLocation != nil
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
    ///
    /// Bewusst nicht public: Der Calibre-Zweig verändert die übergebene Datei
    /// direkt, ohne Backup und atomaren Austausch. Von außen führt jeder
    /// Schreibweg über `write(url:fields:original:coverUpdate:)`, das diesen
    /// Mutator nur auf der Geschwisterkopie aufruft.
    static func writeCoreFields(
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

    /// Schreibt Kernfelder und Cover als eine Transaktion pro Datei. Schlägt
    /// ein späterer Backend-Schritt fehl, bleibt das Original unverändert.
    ///
    /// `expecting` (optional): Stempel des gelesenen Standes; bei Abweichung
    /// unmittelbar vor dem Austausch bricht das Schreiben ab
    /// (`fileChangedOnDisk`), statt eine fremde Änderung zu überschreiben.
    public static func write(
        url: URL,
        fields: EbookCoreFields,
        original: EbookCoreFields,
        coverUpdate: EbookCoverUpdate,
        expecting stamp: FileStamp? = nil
    ) throws {
        let hasCoverChange: Bool
        switch coverUpdate {
        case .unchanged: hasCoverChange = false
        case .set, .remove: hasCoverChange = true
        }
        guard fields != original || hasCoverChange else { return }

        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            // Auf der Geschwisterkopie laufen nur reine Inhalts-Mutatoren.
            // Fehlerpfade zeigen dabei auf die versteckte Kopie; nach außen
            // muss die vom Menschen gewählte Datei stehen (siehe unten).
            try withOriginalPath(url) {
                switch backend(for: temp) {
                case .epub:
                    try EpubFile.mutateContents(url: temp, fields: fields,
                                                original: original,
                                                coverUpdate: coverUpdate)
                default:
                    try writeCoreFields(url: temp, fields: fields, original: original)
                    switch coverUpdate {
                    case .unchanged: break
                    case .set(let data): try writeCover(url: temp, data: data)
                    case .remove: try removeCover(url: temp)
                    }
                }
            }
        } validate: { temp in
            try withOriginalPath(url) {
                // Die EPUB-Invarianten prüfte bisher der verschachtelte
                // Austausch in `EpubFile`; ohne ihn gehört die Prüfung hierher.
                if backend(for: temp) == .epub { try EpubFile.validateContainer(url: temp) }
                _ = try readCoreFields(url: temp)
                switch coverUpdate {
                case .unchanged: break
                case .set:
                    guard try readCover(url: temp) != nil else {
                        throw TagError.saveFailed(path: temp.path)
                    }
                case .remove:
                    guard try readCover(url: temp) == nil else {
                        throw TagError.saveFailed(path: temp.path)
                    }
                }
            }
        }
    }

    /// Führt einen Schritt auf der Geschwisterkopie aus und stellt dessen
    /// typisierte Fehler auf die Originaldatei um. Die Kopie trägt einen
    /// versteckten Zufallsnamen und existiert nach dem Abbruch nicht mehr —
    /// ihr Pfad in einer Meldung sagt niemandem etwas.
    private static func withOriginalPath(_ url: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as TagError {
            switch error {
            case .cannotOpen: throw TagError.cannotOpen(path: url.path)
            case .saveFailed: throw TagError.saveFailed(path: url.path)
            case .readOnly: throw TagError.readOnly(path: url.path)
            case .fileChangedOnDisk: throw TagError.fileChangedOnDisk(path: url.path)
            case .backupFailed(_, let reason):
                throw TagError.backupFailed(path: url.path, reason: reason)
            case .notEnoughSpace(_, let needBytes, let freeBytes):
                throw TagError.notEnoughSpace(path: url.path, needBytes: needBytes,
                                              freeBytes: freeBytes)
            // Diese Fälle tragen keinen Dateipfad und bleiben unverändert.
            case .propertiesRejected, .toolNotFound, .toolFailed: throw error
            }
        }
    }

    /// Kann dieses Format ein Cover tragen? (PDF nicht.)
    public static func supportsCover(url: URL) -> Bool {
        backend(for: url) != .pdf
    }

    /// Ein Cover kann nur dann als leerer Archiv-Sollwert angewendet werden,
    /// wenn das Backend es tatsächlich entfernen kann. ebook-meta bietet dafür
    /// keine öffentliche, verlässliche Operation; ein stilles Beibehalten wäre
    /// gefährlicher als das Archiv vor dem ersten Schreiben abzulehnen.
    public static func supportsCoverRemoval(url: URL) -> Bool {
        backend(for: url) == .epub
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
            _ = try runCalibre(exe, [MediaInfoReader.toolArgument(for: url), "--get-cover", temp.path])
            guard let data = try? Data(contentsOf: temp), !data.isEmpty else { return nil }
            return Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                           pictureType: "Front Cover")
        }
    }

    /// Nicht public — direkter Backend-Mutator ohne Backup/Atomik, nur für
    /// `write(...)` auf der Geschwisterkopie (und Tests).
    static func writeCover(url: URL, data: Data) throws {
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
            _ = try runCalibre(exe, [MediaInfoReader.toolArgument(for: url), "--cover", temp.path])
        }
    }

    /// Entfernt ein explizit archiviertes leeres Cover. PDF besitzt keine
    /// Cover-Metadaten. Calibres öffentliche ebook-meta-Schnittstelle kennt
    /// nur das Setzen eines Cover-Pfads; dort melden wir den nicht sicher
    /// ausführbaren Löschwunsch statt ein vorhandenes Cover still zu behalten.
    /// Nicht public — siehe `writeCover`.
    static func removeCover(url: URL) throws {
        switch backend(for: url) {
        case .epub: try EpubFile.removeCover(url: url)
        case .pdf, .calibre, nil: throw TagError.saveFailed(path: url.path)
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
                    "-XMP-prism:ISBN", MediaInfoReader.toolArgument(for: url)]
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
        _ = try MediaInfoReader.run(exe, ["-overwrite_original", "-m"] + args + [MediaInfoReader.toolArgument(for: url)])
    }

    // MARK: - mobi/azw3/fb2 via Calibre ebook-meta

    /// `ebook-meta <datei>` gibt "Label : Wert"-Zeilen aus; mit LC_ALL=C sind
    /// die Labels stabil englisch. Mehrzeilige Werte (Comments) werden über
    /// Fortsetzungszeilen angehängt.
    private static func readCalibre(url: URL) throws -> EbookCoreFields {
        let exe = try locateCalibre()
        let output = MediaInfoReader.decodeLossy(try runCalibre(exe, [MediaInfoReader.toolArgument(for: url)]))

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
            fields.seriesIndex = normalizedSeriesIndex(String(series[hash.upperBound...]))
        } else {
            fields.series = values["Series"] ?? ""
        }
        // "Published : 2020-01-01T00:00:00+00:00" — nur das Datum behalten.
        // Calibre codiert einen leeren Wert als Undefined-Date-Sentinel; die
        // öffentliche Tag-API zeigt ihn wieder als leeren Wert an.
        if let published = values["Published"] {
            let day = String(published.prefix(10))
            fields.date = day == "0101-01-01" ? "" : day
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
        var args: [String] = [MediaInfoReader.toolArgument(for: url)]
        if fields.title != original.title { args += ["--title", fields.title] }
        if fields.authors != original.authors {
            args += ["--authors", fields.authors.joined(separator: " & ")]
        }
        if fields.series != original.series { args += ["--series", fields.series] }
        if fields.seriesIndex != original.seriesIndex {
            if !fields.seriesIndex.isEmpty {
                args += ["--index", fields.seriesIndex]
            } else if !fields.series.isEmpty {
                // Calibres Modell kennt bei einer vorhandenen Serie keinen
                // indexlosen Zustand. Der stabile Default #1 ersetzt daher
                // den alten Wert, statt ihn unbemerkt stehen zu lassen.
                args += ["--index", "1"]
            }
        }
        if fields.description != original.description { args += ["--comments", fields.description] }
        if fields.isbn != original.isbn { args += ["--isbn", fields.isbn] }
        if fields.publisher != original.publisher { args += ["--publisher", fields.publisher] }
        if fields.language != original.language { args += ["--language", fields.language] }
        if fields.date != original.date {
            // Reines Datum als UTC-Mitternacht übergeben — sonst interpretiert
            // Calibre lokal und die Ausgabe (UTC) rutscht einen Tag zurück.
            // Ein leerer Wert wird intern als Undefined-Date-Sentinel gespeichert
            // und beim Lesen oben wieder als leer abgebildet.
            let date = fields.date.isEmpty ? ""
                : (fields.date.count == 10 ? fields.date + "T00:00:00+00:00" : fields.date)
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

    /// "1.0" → "1" (Calibre schreibt Serienindizes als Bruchzahl).
    static func normalizedSeriesIndex(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".0") { return String(trimmed.dropLast(2)) }
        return trimmed
    }

    private static func listify(_ value: Any?) -> [String] {
        if let list = value as? [Any] {
            return list.map { ExifTool.stringify($0) }.filter { !$0.isEmpty }
        }
        let single = ExifTool.stringify(value)
        guard !single.isEmpty else { return [] }
        // Kommagetrennte Einzelwerte (PDF:Keywords, PDF:Author "A & B")
        if single.contains(",") {
            return single.splitCommaList()
        }
        if single.contains(" & ") {
            return single.components(separatedBy: " & ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return [single]
    }
}

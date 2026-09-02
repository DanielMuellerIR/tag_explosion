// Dokument-Metadaten: Office (docx/xlsx/pptx), OpenDocument (odt/ods/odp),
// Comic-Archive (cbz) und Markdown mit YAML-Frontmatter. Alle vier haben einen
// gemeinsamen Feldsatz (`DocumentCoreFields`); was ein Format davon nicht
// speichern kann, meldet `supportedFields` — App und CLI blenden solche Felder
// aus, und ein Schreibversuch darauf wird VOR jeder Mutation abgelehnt statt
// still verworfen.
//
// Backends (je eine Datei):
// - OfficeDocumentFile:  OOXML docProps/core.xml (+ app.xml nur Anzeige)
// - OpenDocumentFile:    ODF meta.xml
// - ComicArchiveFile:    ComicInfo.xml; Cover = erste Bildseite (nur Anzeige)
// - MarkdownDocumentFile: YAML-Frontmatter am Dateianfang
import Foundation

/// Die gemeinsamen, editierbaren Felder eines Dokuments.
public enum DocumentField: String, CaseIterable, Sendable, Codable {
    case title, authors, subject, description, keywords
    case publisher, language, category, created, modified
}

/// Ein formatspezifisches Zusatzfeld (z.B. ComicInfo „Series“, OOXML
/// „revision“ oder ein unbekannter Frontmatter-Schlüssel). Reihenfolge und
/// Schlüssel bleiben beim Schreiben erhalten.
public struct DocumentCustomField: Sendable, Codable, Equatable, Hashable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Editierbare Kernfelder eines Dokuments. Datumsfelder als ISO 8601.
public struct DocumentCoreFields: Sendable, Codable, Equatable {
    public var title: String
    /// Autor(en), mehrwertig.
    public var authors: [String]
    /// Thema (OOXML dc:subject, ODF dc:subject).
    public var subject: String
    /// Beschreibung/Kommentar (OOXML dc:description, ODF dc:description,
    /// ComicInfo Summary, Frontmatter description).
    public var description: String
    /// Schlagwörter, mehrwertig.
    public var keywords: [String]
    public var publisher: String
    /// Sprachcode, z.B. "de" oder "de-DE".
    public var language: String
    /// Kategorie (OOXML cp:category).
    public var category: String
    /// Erstellungsdatum bzw. -zeitpunkt (ISO 8601).
    public var created: String
    /// Letzte Änderung (ISO 8601).
    public var modified: String
    /// Formatspezifische Zusatzfelder in Dateireihenfolge.
    public var custom: [DocumentCustomField]

    public init(title: String = "", authors: [String] = [], subject: String = "",
                description: String = "", keywords: [String] = [], publisher: String = "",
                language: String = "", category: String = "", created: String = "",
                modified: String = "", custom: [DocumentCustomField] = []) {
        self.title = title
        self.authors = authors
        self.subject = subject
        self.description = description
        self.keywords = keywords
        self.publisher = publisher
        self.language = language
        self.category = category
        self.created = created
        self.modified = modified
        self.custom = custom
    }

    /// Wert eines Zusatzfelds ("" wenn nicht vorhanden).
    public func customValue(for key: String) -> String {
        custom.first { $0.key == key }?.value ?? ""
    }

    /// Setzt ein Zusatzfeld; ein leerer Wert entfernt es. Ein neuer Schlüssel
    /// wird hinten angehängt, ein vorhandener behält seine Position.
    public mutating func setCustom(_ key: String, _ value: String) {
        if let index = custom.firstIndex(where: { $0.key == key }) {
            if value.isEmpty {
                custom.remove(at: index)
            } else {
                custom[index].value = value
            }
        } else if !value.isEmpty {
            custom.append(DocumentCustomField(key: key, value: value))
        }
    }

    /// Ist das Feld gesetzt? Für die Feld-für-Feld-Prüfung der Backends.
    func value(of field: DocumentField) -> [String] {
        switch field {
        case .title: return [title]
        case .authors: return authors
        case .subject: return [subject]
        case .description: return [description]
        case .keywords: return keywords
        case .publisher: return [publisher]
        case .language: return [language]
        case .category: return [category]
        case .created: return [created]
        case .modified: return [modified]
        }
    }
}

/// Reine Anzeigeinformation (z.B. Anwendung und Seitenzahl aus app.xml).
/// Die Bezeichner sind die Rohnamen der Quelle, wie bei den Rohgruppen der
/// Bild-Metadaten.
public struct DocumentInfoItem: Sendable, Codable, Equatable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Zusammengehöriger Inhalt eines Dokument-Schnappschusses.
public struct DocumentContents: Sendable, Equatable {
    public let fields: DocumentCoreFields
    /// Nur CBZ: erste Bildseite (reine Anzeige, kein Schreibweg). nil, wenn
    /// das Format kein Cover kennt, `includeCover` false war oder keine
    /// Bildseite vorhanden ist.
    public let cover: Artwork?
    public let info: [DocumentInfoItem]

    public init(fields: DocumentCoreFields, cover: Artwork?, info: [DocumentInfoItem]) {
        self.fields = fields
        self.cover = cover
        self.info = info
    }
}

/// Gemeinsame Schnittstelle der vier Backends (intern).
protocol DocumentBackend {
    /// Felder und Anzeigeinformationen lesen.
    static func read(url: URL) throws -> (DocumentCoreFields, [DocumentInfoItem])
    /// Cover lesen (Standard: keins).
    static func readCover(url: URL) throws -> Artwork?
    /// Felder, die dieses Format speichern kann.
    static var supportedFields: Set<DocumentField> { get }
    /// Erlaubte Zusatzschlüssel; nil = beliebige Schlüssel (Markdown).
    static var customKeys: [String]? { get }
    /// Formatregeln für Werte (Trennzeichen, Datumsform) — wirft
    /// `invalidDocumentValue`. Nur geänderte Felder werden geprüft.
    static func validate(_ fields: DocumentCoreFields, original: DocumentCoreFields) throws
    /// Ändert die Datei DIREKT (Aufrufer arbeitet auf der Geschwisterkopie).
    static func mutate(url: URL, fields: DocumentCoreFields, original: DocumentCoreFields) throws
    /// Strukturprüfung der geschriebenen Datei (z.B. mimetype an erster Stelle).
    static func validateContainer(url: URL) throws
}

extension DocumentBackend {
    static func readCover(url: URL) throws -> Artwork? { nil }
}

public enum DocumentTool {

    public enum Backend: Sendable {
        case ooxml
        case odf
        case cbz
        case markdown
    }

    /// Alle Dokument-Endungen.
    public static let extensions: Set<String> = [
        "docx", "xlsx", "pptx", "odt", "ods", "odp", "cbz", "md", "markdown",
    ]

    public static func backend(for url: URL) -> Backend? {
        switch url.pathExtension.lowercased() {
        case "docx", "xlsx", "pptx": return .ooxml
        case "odt", "ods", "odp": return .odf
        case "cbz": return .cbz
        case "md", "markdown": return .markdown
        default: return nil
        }
    }

    private static func implementation(for url: URL) throws -> DocumentBackend.Type {
        switch backend(for: url) {
        case .ooxml: return OfficeDocumentFile.self
        case .odf: return OpenDocumentFile.self
        case .cbz: return ComicArchiveFile.self
        case .markdown: return MarkdownDocumentFile.self
        case nil: throw TagError.cannotOpen(path: url.path)
        }
    }

    // MARK: - Fähigkeiten

    /// Felder, die das Format der Datei speichern kann. Unbekannte Endung:
    /// leer.
    public static func supportedFields(url: URL) -> Set<DocumentField> {
        (try? implementation(for: url))?.supportedFields ?? []
    }

    /// Zusatzschlüssel des Formats; nil = beliebige Schlüssel (Markdown).
    public static func customKeys(url: URL) -> [String]? {
        guard let backend = try? implementation(for: url) else { return [] }
        return backend.customKeys
    }

    /// Kann das Format ein Cover zeigen? (nur CBZ, reine Anzeige)
    public static func supportsCover(url: URL) -> Bool {
        backend(for: url) == .cbz
    }

    // MARK: - Lesen

    public static func readCoreFields(url: URL) throws -> DocumentCoreFields {
        try implementation(for: url).read(url: url).0
    }

    public static func readCover(url: URL) throws -> Artwork? {
        try implementation(for: url).readCover(url: url)
    }

    /// Felder, Anzeigeinfos und optional Cover unter einem gemeinsamen
    /// Dateistempel — zwei Leseaufrufe dürfen keinen Mischzustand aus zwei
    /// Dateifassungen bilden (gleiche Regel wie bei E-Books).
    public static func readSnapshot(
        url: URL, includeCover: Bool, expecting stamp: FileStamp? = nil
    ) throws -> FileSnapshot<DocumentContents> {
        let backend = try implementation(for: url)
        return try FileSnapshot.capture(at: url, expecting: stamp) {
            let (fields, info) = try backend.read(url: url)
            let cover = includeCover && supportsCover(url: url)
                ? try backend.readCover(url: url) : nil
            return DocumentContents(fields: fields, cover: cover, info: info)
        }
    }

    // MARK: - Schreiben

    /// Lehnt ab, was das Ziel nicht speichern kann — VOR Sicherung und
    /// Schreibweg: geänderte Felder außerhalb von `supportedFields`,
    /// Zusatzschlüssel außerhalb von `customKeys`, leere Schlüssel und Werte,
    /// die das Format so nicht ablegt (Trennzeichen, Datumsform).
    /// Öffentlich, damit CLI, App und Archiv-Import dieselbe Regel nutzen.
    public static func requireWritable(
        _ fields: DocumentCoreFields, original: DocumentCoreFields, url: URL
    ) throws {
        let backend = try implementation(for: url)
        for field in DocumentField.allCases
        where fields.value(of: field) != original.value(of: field)
            && !backend.supportedFields.contains(field) {
            throw TagError.unsupportedDocumentField(name: field.rawValue)
        }
        var seen: Set<String> = []
        for entry in fields.custom {
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key == entry.key else {
                throw TagError.invalidDocumentValue(
                    field: "custom", reason: "custom field keys must not be empty or padded")
            }
            guard seen.insert(key).inserted else {
                throw TagError.invalidDocumentValue(
                    field: key, reason: "custom field key appears more than once")
            }
        }
        if let allowed = backend.customKeys {
            let originalValues = Dictionary(
                original.custom.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let newValues = Dictionary(
                fields.custom.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            for key in Set(originalValues.keys).union(newValues.keys)
            where originalValues[key] != newValues[key] && !allowed.contains(key) {
                throw TagError.unsupportedDocumentField(name: key)
            }
        }
        try backend.validate(fields, original: original)
    }

    /// Schreibt die Unterschiede zu `original` als eine Transaktion: Sicherung
    /// macht der Aufrufer (`TrashBackup`), der Austausch läuft atomar, und die
    /// fertige Kopie wird vor dem Austausch zurückgelesen — nur wenn sie
    /// exakt die Zielfelder liefert, ersetzt sie das Original.
    public static func write(
        url: URL, fields: DocumentCoreFields, original: DocumentCoreFields,
        expecting stamp: FileStamp? = nil
    ) throws {
        try requireWritable(fields, original: original, url: url)
        guard fields != original else {
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        let backend = try implementation(for: url)
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            try withOriginalPath(url) {
                try backend.mutate(url: temp, fields: fields, original: original)
            }
        } validate: { temp in
            try withOriginalPath(url) {
                try backend.validateContainer(url: temp)
                let readBack = try backend.read(url: temp).0
                guard readBack == fields else { throw TagError.saveFailed(path: temp.path) }
            }
        }
    }

    /// Fehler von der versteckten Geschwisterkopie auf die gewählte Datei
    /// umstellen (gleiche Begründung wie in EbookTool).
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
            default: throw error
            }
        }
    }

    // MARK: - Gemeinsame Helfer der Backends

    /// Datum/Zeitpunkt nach ISO 8601 bzw. W3CDTF: "2024-01-05",
    /// "2024-01-05T10:00:00", "…Z", "…+01:00", auch mit Sekundenbruchteilen.
    /// OOXML und ODF lehnen andere Formen ab (Word meldet sonst beschädigten
    /// Inhalt).
    static func isW3CDateTime(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})?)?$"#,
            options: .regularExpression) != nil
    }

    static func requireW3CDateTime(_ value: String, field: DocumentField) throws {
        guard value.isEmpty || isW3CDateTime(value) else {
            throw TagError.invalidDocumentValue(
                field: field.rawValue, reason: "expected ISO 8601 (YYYY-MM-DD or YYYY-MM-DDThh:mm:ssZ)")
        }
    }

    /// Mehrwertige Felder, die das Format als EINEN String mit Trennzeichen
    /// ablegt, dürfen dieses Trennzeichen nicht in den Werten tragen — sonst
    /// läse die Datei später mehr Werte zurück als geschrieben wurden.
    static func requireValues(_ values: [String], free separators: [Character],
                              field: DocumentField) throws {
        for value in values {
            for separator in separators where value.contains(separator) {
                throw TagError.invalidDocumentValue(
                    field: field.rawValue,
                    reason: "values must not contain \"\(separator)\" in this format")
            }
        }
    }

    /// "A; B" → ["A", "B"] für alle genannten Trennzeichen.
    static func splitList(_ raw: String, separators: [Character]) -> [String] {
        raw.split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

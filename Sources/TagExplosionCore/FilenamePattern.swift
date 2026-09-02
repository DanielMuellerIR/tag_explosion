// Muster-Engine für Dateinamen im kid3-Stil: `%{artist} - %{title}`.
//
// Zwei Richtungen, beide als reine Funktionen ohne Dateizugriff:
//   1. Tags → Dateiname (`render`): Platzhalter durch Feldwerte ersetzen,
//      unzulässige Zeichen entschärfen, Länge begrenzen.
//   2. Dateiname → Tags (`extract`): Das Muster wird in einen regulären
//      Ausdruck übersetzt; alles zwischen den Platzhaltern muss wörtlich im
//      Namen vorkommen.
//
// Die Zuordnung der Platzhalter zu den Feldern der einzelnen Medienarten
// (Audio, Bild, E-Book) steht in `PatternFields` am Ende der Datei.
import Foundation

/// Ein geparstes Dateinamen-Muster.
public struct FilenamePattern: Sendable, Equatable {

    /// Ein Platzhalter wie `%{track:2}`.
    public struct Placeholder: Sendable, Equatable {
        /// Kanonischer Feldschlüssel, z.B. "TRACKNUMBER" für `%{track}`.
        public let key: String
        /// Wie der Platzhalter im Muster geschrieben wurde ("track").
        public let alias: String
        /// Mindestbreite mit führenden Nullen (nur für Zahlen), nil = keine.
        public let width: Int?

        /// Platzhalter, deren Wert eine Zahl ist. Sie bekommen beim Parsen
        /// ein Ziffernmuster, damit `%{track} %{title}` eindeutig trennt.
        public var isNumeric: Bool {
            FilenamePattern.numericKeys.contains(key) || alias == "year"
        }

        /// `%{year}` liest aus dem Datumsfeld nur die Jahreszahl.
        public var isYear: Bool { alias == "year" }
    }

    /// Bausteine des Musters in Reihenfolge.
    enum Token: Sendable, Equatable {
        case literal(String)
        case placeholder(Placeholder)
    }

    let tokens: [Token]
    /// Das Muster, wie es eingegeben wurde.
    public let text: String

    /// Alle Platzhalter in Reihenfolge ihres Auftretens.
    public var placeholders: [Placeholder] {
        tokens.compactMap {
            if case .placeholder(let p) = $0 { return p }
            return nil
        }
    }

    /// Fehler beim Lesen eines Musters. Texte englisch (CLI-Konvention);
    /// die App stellt eigene Übersetzungen davor.
    public enum ParseError: Error, LocalizedError, Equatable, Sendable {
        case unbalancedBraces
        case emptyPlaceholder
        case invalidWidth(String)
        case containsPathSeparator
        case noPlaceholder

        public var errorDescription: String? {
            switch self {
            case .unbalancedBraces:
                return "Pattern has an unclosed %{ placeholder"
            case .emptyPlaceholder:
                return "Pattern contains an empty placeholder %{}"
            case .invalidWidth(let raw):
                return "Placeholder width must be a number between 1 and 9: \(raw)"
            case .containsPathSeparator:
                return "Pattern must describe a file name, not a folder path (no '/')"
            case .noPlaceholder:
                return "Pattern contains no placeholder such as %{title}"
            }
        }
    }

    /// Kurznamen im kid3-Stil → Feldschlüssel des Datenmodells (TagLib-
    /// PropertyMap). Unbekannte Namen werden großgeschrieben übernommen,
    /// damit Custom-Keys wie `%{isrc}` direkt funktionieren.
    public static let aliases: [String: String] = [
        "artist": "ARTIST",
        "title": "TITLE",
        "album": "ALBUM",
        "albumartist": "ALBUMARTIST",
        "track": "TRACKNUMBER",
        "tracknumber": "TRACKNUMBER",
        "disc": "DISCNUMBER",
        "discnumber": "DISCNUMBER",
        "year": "DATE",
        "date": "DATE",
        "genre": "GENRE",
        "composer": "COMPOSER",
        "comment": "COMMENT",
    ]

    /// Felder mit Zahlenwert: Breite polstert mit Nullen, Parsen erwartet Ziffern.
    static let numericKeys: Set<String> = ["TRACKNUMBER", "DISCNUMBER"]

    /// Übersetzt einen Kurznamen in den Feldschlüssel.
    public static func canonicalKey(for alias: String) -> String {
        let lower = alias.lowercased()
        return aliases[lower] ?? alias.uppercased()
    }

    /// Liest ein Muster. `%%` steht für ein wörtliches Prozentzeichen.
    public init(_ text: String) throws {
        guard !text.contains("/") else { throw ParseError.containsPathSeparator }
        var tokens: [Token] = []
        var literal = ""
        var rest = Substring(text)
        func flushLiteral() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while let percent = rest.firstIndex(of: "%") {
            literal += rest[..<percent]
            let afterPercent = rest.index(after: percent)
            guard afterPercent < rest.endIndex else {
                // Ein einzelnes % am Ende bleibt wörtlich.
                literal += "%"
                rest = rest[rest.endIndex...]
                break
            }
            if rest[afterPercent] == "%" {
                literal += "%"
                rest = rest[rest.index(after: afterPercent)...]
                continue
            }
            guard rest[afterPercent] == "{" else {
                // "%x" ohne Klammer: wörtlich übernehmen.
                literal += "%"
                rest = rest[afterPercent...]
                continue
            }
            guard let close = rest[afterPercent...].firstIndex(of: "}") else {
                throw ParseError.unbalancedBraces
            }
            let inner = rest[rest.index(after: afterPercent)..<close]
                .trimmingCharacters(in: .whitespaces)
            // "%{artist - %{title}": Die erste Klammer wurde nie geschlossen,
            // der Feldname hätte sonst ein zweites "%{" im Bauch.
            guard !inner.contains("%"), !inner.contains("{") else {
                throw ParseError.unbalancedBraces
            }
            guard !inner.isEmpty else { throw ParseError.emptyPlaceholder }
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let alias = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty else { throw ParseError.emptyPlaceholder }
            var width: Int?
            if parts.count == 2 {
                let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard let parsed = Int(raw), (1...9).contains(parsed) else {
                    throw ParseError.invalidWidth(raw)
                }
                width = parsed
            }
            flushLiteral()
            tokens.append(.placeholder(Placeholder(
                key: Self.canonicalKey(for: alias), alias: alias.lowercased(), width: width)))
            rest = rest[rest.index(after: close)...]
        }
        literal += rest
        flushLiteral()
        guard tokens.contains(where: { if case .placeholder = $0 { return true } else { return false } })
        else { throw ParseError.noPlaceholder }
        self.tokens = tokens
        self.text = text
    }

    // MARK: - Tags → Dateiname

    /// Höchstlänge eines Dateinamens in UTF-8-Bytes (APFS, ext4, NTFS: 255).
    public static let maxNameBytes = 255

    /// Baut aus den Feldwerten den Namensstamm (ohne Endung). Fehlende Felder
    /// werden leer eingesetzt; ein komplett leeres Ergebnis meldet der
    /// Aufrufer als Konflikt.
    public func renderStem(fields: [String: String]) -> String {
        var result = ""
        for token in tokens {
            switch token {
            case .literal(let text):
                result += text
            case .placeholder(let placeholder):
                result += Self.formatValue(fields[placeholder.key] ?? "", for: placeholder)
            }
        }
        return Self.sanitizeStem(result)
    }

    /// Vollständiger Dateiname: Stamm aus dem Muster plus die bisherige
    /// Endung (Groß-/Kleinschreibung bleibt). Der Stamm wird so gekürzt, dass
    /// der ganze Name in die Längengrenze passt.
    public func renderFileName(fields: [String: String], extension ext: String) -> String {
        var stem = renderStem(fields: fields)
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let budget = Self.maxNameBytes - suffix.utf8.count
        while stem.utf8.count > budget, !stem.isEmpty {
            stem.removeLast()
        }
        stem = stem.trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "" : stem + suffix
    }

    /// Einzelnen Feldwert für den Dateinamen aufbereiten: Tracknummern
    /// "3/12" → "3", Jahr aus "2021-05-01" → "2021", Breite mit Nullen.
    static func formatValue(_ raw: String, for placeholder: Placeholder) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeholder.isYear {
            value = yearComponent(of: value)
        } else if Self.numericKeys.contains(placeholder.key) {
            // "3/12" (Track 3 von 12) → "3"; kid3 und TagLib schreiben so.
            if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if let width = placeholder.width, placeholder.isNumeric,
           !value.isEmpty, value.allSatisfy(\.isNumber), value.count < width {
            value = String(repeating: "0", count: width - value.count) + value
        }
        return value
    }

    /// Erste vierstellige Ziffernfolge eines Datums ("2021-05-01",
    /// "2021:05:01 12:00:00", "05.06.2021" → "2021"); sonst der Rohwert.
    static func yearComponent(of value: String) -> String {
        if let range = value.range(of: #"\d{4}"#, options: .regularExpression) {
            return String(value[range])
        }
        return value
    }

    /// Zeichen, die in keinem Dateinamen stehen dürfen oder Ärger machen:
    /// `/` (Pfadtrenner), `:` (Finder zeigt es als `/`, HFS-Trenner),
    /// Steuerzeichen (unsichtbar, brechen Terminals und Skripte).
    static func sanitizeStem(_ raw: String) -> String {
        var cleaned = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", ":":
                cleaned.unicodeScalars.append("-")
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                // Steuerzeichen ersatzlos streichen.
                continue
            default:
                cleaned.unicodeScalars.append(scalar)
            }
        }
        // Mehrfache Leerzeichen (z.B. aus leeren Feldern) zusammenziehen.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        // Ein führender Punkt versteckt die Datei im Finder und in `ls`.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Dateiname → Tags

    /// Regulärer Ausdruck des Musters: Literale wörtlich, Platzhalter als
    /// Fanggruppen (Ziffern für Zahlenfelder, sonst möglichst kurz), verankert
    /// am ganzen Stamm.
    var regexSource: String {
        var source = "^"
        for token in tokens {
            switch token {
            case .literal(let text):
                source += NSRegularExpression.escapedPattern(for: text)
            case .placeholder(let placeholder):
                if placeholder.isYear {
                    source += #"(\d{4})"#
                } else if placeholder.isNumeric {
                    source += #"(\d+)"#
                } else {
                    source += "(.+?)"
                }
            }
        }
        return source + "$"
    }

    /// Liest die Feldwerte aus einem Namensstamm (ohne Endung). nil = das
    /// Muster passt nicht. Leere Treffer gibt es nicht: `.+?` verlangt
    /// mindestens ein Zeichen, Ziffernfelder mindestens eine Ziffer.
    public func extract(fromStem stem: String) -> [String: String]? {
        guard let regex = try? NSRegularExpression(pattern: regexSource) else { return nil }
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = regex.firstMatch(in: stem, range: range),
              match.numberOfRanges == placeholders.count + 1 else { return nil }
        var fields: [String: String] = [:]
        for (index, placeholder) in placeholders.enumerated() {
            guard let valueRange = Range(match.range(at: index + 1), in: stem) else { continue }
            var value = String(stem[valueRange]).trimmingCharacters(in: .whitespaces)
            if Self.numericKeys.contains(placeholder.key) {
                // "01" → "1": Tags tragen die Zahl, die Nullen sind Anzeige.
                let stripped = value.drop { $0 == "0" }
                value = stripped.isEmpty ? "0" : String(stripped)
            }
            // Kommt ein Feld zweimal vor, gewinnt das erste.
            if fields[placeholder.key] == nil { fields[placeholder.key] = value }
        }
        return fields
    }

    /// Bequemer Einstieg mit Dateiname/URL: Die Endung wird abgetrennt.
    public func extract(fromFileName fileName: String) -> [String: String]? {
        extract(fromStem: (fileName as NSString).deletingPathExtension)
    }
}

// MARK: - Felder je Medienart

/// Übersetzt zwischen den Modellen der Medienarten und dem flachen
/// Feld-Wörterbuch der Muster-Engine. Audio nutzt die TagLib-Schlüssel
/// direkt; Bild und E-Book bekommen dieselben Namen, wo es ein passendes
/// Feld gibt, plus Synonyme (`%{artist}` = Ersteller/Autor).
public enum PatternFields {

    /// Felder, die ein Audio-/Video-Tag liefert (erster Wert je Schlüssel).
    public static func fields(from data: TagData) -> [String: String] {
        fields(from: data.properties)
    }

    public static func fields(from properties: [TagProperty]) -> [String: String] {
        var fields: [String: String] = [:]
        for property in properties where fields[property.key] == nil {
            fields[property.key] = property.value
        }
        return fields
    }

    /// Bildfelder. Datum ist das Aufnahmedatum (exiftool-Schreibweise
    /// "YYYY:MM:DD HH:MM:SS"; `%{year}` zieht daraus die Jahreszahl).
    public static func fields(from image: ImageCoreFields) -> [String: String] {
        [
            "TITLE": image.title,
            "DESCRIPTION": image.description,
            "KEYWORDS": image.keywords.joined(separator: ", "),
            "CREATOR": image.creator,
            "ARTIST": image.creator,
            "AUTHOR": image.creator,
            "COPYRIGHT": image.copyright,
            "DATE": image.dateTimeOriginal,
            "RATING": image.rating.map(String.init) ?? "",
        ]
    }

    /// E-Book-Felder. `%{artist}`/`%{author}` sind die Autoren, `%{genre}`
    /// die Schlagwörter, `%{track}` der Serienindex (für Reihen).
    public static func fields(from ebook: EbookCoreFields) -> [String: String] {
        let authors = ebook.authors.joined(separator: ", ")
        return [
            "TITLE": ebook.title,
            "AUTHOR": authors,
            "AUTHORS": authors,
            "ARTIST": authors,
            "SERIES": ebook.series,
            "SERIESINDEX": ebook.seriesIndex,
            "TRACKNUMBER": ebook.seriesIndex,
            "DESCRIPTION": ebook.description,
            "ISBN": ebook.isbn,
            "PUBLISHER": ebook.publisher,
            "LANGUAGE": ebook.language,
            "DATE": ebook.date,
            "SUBJECTS": ebook.subjects.joined(separator: ", "),
            "GENRE": ebook.subjects.joined(separator: ", "),
        ]
    }

    /// Fehler beim Übertragen geparster Werte in ein Modell.
    /// Dokumente (Office, OpenDocument, CBZ, Markdown): gemeinsamer Feldsatz;
    /// Zusatzfelder (z.B. ComicInfo „Series“) sind über ihren Schlüssel in
    /// Großbuchstaben erreichbar.
    public static func fields(from document: DocumentCoreFields) -> [String: String] {
        let authors = document.authors.joined(separator: ", ")
        var fields: [String: String] = [
            "TITLE": document.title,
            "AUTHOR": authors,
            "AUTHORS": authors,
            "ARTIST": authors,
            "SUBJECT": document.subject,
            "DESCRIPTION": document.description,
            "KEYWORDS": document.keywords.joined(separator: ", "),
            "SUBJECTS": document.keywords.joined(separator: ", "),
            "GENRE": document.keywords.joined(separator: ", "),
            "PUBLISHER": document.publisher,
            "LANGUAGE": document.language,
            "CATEGORY": document.category,
            "DATE": document.created,
            "CREATED": document.created,
            "MODIFIED": document.modified,
        ]
        for custom in document.custom where fields[custom.key.uppercased()] == nil {
            fields[custom.key.uppercased()] = custom.value
        }
        return fields
    }

    public enum ApplyError: Error, LocalizedError, Equatable, Sendable {
        /// Die Medienart hat kein Feld für diesen Schlüssel.
        case unsupportedField(key: String, kind: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedField(let key, let kind):
                return "Field \(key) does not exist for \(kind) files"
            }
        }
    }

    /// Setzt geparste Werte in eine Audio-Property-Liste (jeder Schlüssel
    /// bekommt genau einen Wert; leere Werte entfernen das Feld).
    public static func apply(_ parsed: [String: String], to properties: inout [TagProperty]) {
        for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
            properties.removeAll { $0.key == key }
            if !value.isEmpty { properties.append(TagProperty(key: key, value: value)) }
        }
    }

    /// Setzt geparste Werte in Bildfelder. Schlüssel ohne Bildfeld werfen,
    /// damit ein Tippfehler im Muster nicht still verloren geht.
    public static func apply(_ parsed: [String: String], to image: inout ImageCoreFields) throws {
        for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "TITLE": image.title = value
            case "DESCRIPTION": image.description = value
            case "KEYWORDS": image.keywords = value.splitCommaList()
            case "CREATOR", "ARTIST", "AUTHOR": image.creator = value
            case "COPYRIGHT": image.copyright = value
            case "DATE": image.dateTimeOriginal = value
            default: throw ApplyError.unsupportedField(key: key, kind: "image")
            }
        }
    }

    /// Setzt geparste Werte in E-Book-Felder (Regel wie bei Bildern).
    public static func apply(_ parsed: [String: String], to ebook: inout EbookCoreFields) throws {
        for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "TITLE": ebook.title = value
            case "AUTHOR", "AUTHORS", "ARTIST": ebook.authors = value.splitCommaList()
            case "SERIES": ebook.series = value
            case "SERIESINDEX", "TRACKNUMBER": ebook.seriesIndex = value
            case "DESCRIPTION": ebook.description = value
            case "ISBN": ebook.isbn = value
            case "PUBLISHER": ebook.publisher = value
            case "LANGUAGE": ebook.language = value
            case "DATE": ebook.date = value
            case "SUBJECTS", "GENRE": ebook.subjects = value.splitCommaList()
            default: throw ApplyError.unsupportedField(key: key, kind: "e-book")
            }
        }
    }

    /// Dokumente: nur der gemeinsame Feldsatz — ob das Zielformat das Feld
    /// speichern kann, prüft beim Speichern `DocumentTool.requireWritable`.
    public static func apply(_ parsed: [String: String], to document: inout DocumentCoreFields) throws {
        for (key, value) in parsed.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "TITLE": document.title = value
            case "AUTHOR", "AUTHORS", "ARTIST": document.authors = value.splitCommaList()
            case "SUBJECT": document.subject = value
            case "DESCRIPTION": document.description = value
            case "KEYWORDS", "SUBJECTS", "GENRE": document.keywords = value.splitCommaList()
            case "PUBLISHER": document.publisher = value
            case "LANGUAGE": document.language = value
            case "CATEGORY": document.category = value
            case "DATE", "CREATED": document.created = value
            case "MODIFIED": document.modified = value
            default: throw ApplyError.unsupportedField(key: key, kind: "document")
            }
        }
    }
}

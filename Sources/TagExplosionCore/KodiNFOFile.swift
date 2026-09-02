// Kodi-/Jellyfin-NFO (`<name>.nfo` neben einem Video): eine kleine XML-Datei
// mit Titel, Jahr, Handlung, Genres usw. Wurzelelemente: `movie`,
// `episodedetails`, `tvshow`, `musicvideo`, für Musik `album` und `artist`.
//
// Zwei Sonderformen kommen in freier Wildbahn vor:
// - Nur-URL-NFO: Die Datei enthält nur eine oder mehrere Scraper-URLs (kein
//   XML). Sie wird angezeigt, aber nie beschrieben.
// - XML plus URL-Zeilen hinter dem Wurzelelement (Kodi erlaubt das). Der
//   XML-Teil wird bearbeitet, die URL-Zeilen bleiben unverändert dahinter.
//
// Schreiben: Unbekannte Elemente, ihre Reihenfolge und die Einrückung der
// Datei bleiben erhalten. Foundation-XML verwirft beim Parsen den Leerraum
// zwischen Elementen; deshalb schreibt `NFOWriter` das Dokument mit einem
// eigenen Serialisierer neu, der Einrückungsbreite, Zeilenende und Form
// leerer Elemente aus dem Original übernimmt. Die XML-Deklaration wird
// wörtlich übernommen. Fallen: knowledge/kodi-nfo-untertitel.md.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Editierbare NFO-Felder. Mehrwertige Elemente (genre, tag, director) als
/// Listen; Zahlen bleiben Strings, damit die Datei ihre Schreibweise behält.
public struct NFOFields: Sendable, Codable, Equatable {
    public var title: String
    public var originalTitle: String
    public var sortTitle: String
    /// Vierstellige Jahreszahl.
    public var year: String
    /// Erstaufführung (`premiered`) bzw. bei Episoden Ausstrahlung (`aired`),
    /// ISO 8601 (JJJJ-MM-TT).
    public var premiered: String
    public var plot: String
    public var outline: String
    public var tagline: String
    public var genres: [String]
    public var tags: [String]
    public var studio: String
    public var directors: [String]
    /// Drehbuch (`credits`).
    public var credits: String
    /// Bewertung 0–10 (flaches `rating` oder `ratings/rating/value`).
    public var rating: String
    /// Eigene Bewertung (`userrating`).
    public var userRating: String
    /// Altersfreigabe (`mpaa`).
    public var mpaa: String
    /// Laufzeit in Minuten.
    public var runtime: String
    /// Nur Episoden: Staffel, Folge, Serientitel.
    public var season: String
    public var episode: String
    public var showTitle: String

    public init(title: String = "", originalTitle: String = "", sortTitle: String = "",
                year: String = "", premiered: String = "", plot: String = "",
                outline: String = "", tagline: String = "", genres: [String] = [],
                tags: [String] = [], studio: String = "", directors: [String] = [],
                credits: String = "", rating: String = "", userRating: String = "",
                mpaa: String = "", runtime: String = "", season: String = "",
                episode: String = "", showTitle: String = "") {
        self.title = title
        self.originalTitle = originalTitle
        self.sortTitle = sortTitle
        self.year = year
        self.premiered = premiered
        self.plot = plot
        self.outline = outline
        self.tagline = tagline
        self.genres = genres
        self.tags = tags
        self.studio = studio
        self.directors = directors
        self.credits = credits
        self.rating = rating
        self.userRating = userRating
        self.mpaa = mpaa
        self.runtime = runtime
        self.season = season
        self.episode = episode
        self.showTitle = showTitle
    }
}

/// Gelesener Inhalt einer NFO: Felder, Anzeigeinformationen und die Art der
/// Datei. `rootName` ist nil bei einer Nur-URL-NFO.
public struct NFOContents: Sendable, Equatable {
    /// Wurzelelement (`movie`, `episodedetails`, …); nil = Nur-URL-NFO.
    public let rootName: String?
    public let fields: NFOFields
    /// Nur Anzeige: Typ, Darsteller, uniqueid, thumb/fanart, zugehöriges
    /// Video, URL-Zeilen.
    public let info: [DocumentInfoItem]
    /// Scraper-URLs (Nur-URL-NFO oder Zeilen hinter dem XML).
    public let urls: [String]

    public var isURLOnly: Bool { rootName == nil }

    public init(rootName: String?, fields: NFOFields, info: [DocumentInfoItem], urls: [String]) {
        self.rootName = rootName
        self.fields = fields
        self.info = info
        self.urls = urls
    }
}

public enum KodiNFOFile {

    /// Wurzelelemente, die als NFO gelten. Andere `.nfo`-Dateien (etwa
    /// Szene-Textdateien) sind keine Medien-Sidecars.
    public static let rootNames: Set<String> = [
        "movie", "episodedetails", "tvshow", "musicvideo", "album", "artist",
    ]

    /// Mehr liest die Erkennung nicht; NFOs sind kleine Textdateien.
    private static let sniffLimit = 64 * 1024

    // MARK: - Erkennung

    /// Ist die Datei eine NFO (bekanntes XML-Wurzelelement oder Nur-URL)?
    /// Liest nur den Anfang der Datei.
    public static func sniff(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: sniffLimit), !data.isEmpty else { return false }
        let text = decode(data)
        if rootName(in: text) != nil { return true }
        return isURLOnly(text)
    }

    /// Wurzelelement eines XML-Texts (erstes Tag, das keine Deklaration,
    /// kein Kommentar und keine DTD ist), sofern es ein NFO-Wurzelelement ist.
    static func rootName(in text: String) -> String? {
        guard let range = rootStartRange(in: text) else { return nil }
        var name = ""
        for character in text[range.upperBound...] {
            if character.isLetter || character.isNumber || character == "_" {
                name.append(character)
            } else {
                break
            }
        }
        return rootNames.contains(name.lowercased()) ? name.lowercased() : nil
    }

    /// Position des `<` des Wurzelelements.
    private static func rootStartRange(in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let lt = text[search...].firstIndex(of: "<") {
            let next = text.index(after: lt)
            guard next < text.endIndex else { return nil }
            let following = text[next]
            if following == "?" || following == "!" {
                // Deklaration, Kommentar oder DTD überspringen.
                guard let gt = text[next...].firstIndex(of: ">") else { return nil }
                search = text.index(after: gt)
                continue
            }
            return lt..<next
        }
        return nil
    }

    /// Nur-URL-NFO: jede nicht-leere Zeile ist eine http(s)-Adresse.
    static func isURLOnly(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !lines.isEmpty && lines.allSatisfy(isURLLine)
    }

    private static func isURLLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            && !line.contains(where: \.isWhitespace)
    }

    /// UTF-8 (mit oder ohne BOM), sonst Latin-1 — wie bei den übrigen
    /// Textformaten des Projekts.
    private static func decode(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Lesen

    /// Zerlegte Datei: XML-Teil und alles außerhalb des Wurzelelements.
    struct Layout {
        /// Alles vor dem `<` des Wurzelelements (Deklaration, Kommentare).
        var prefix: String
        /// Das Wurzelelement samt Inhalt.
        var xml: String
        /// Alles nach dem Wurzelelement (Zeilenumbruch, URL-Zeilen).
        var suffix: String
        /// Zeichensatz der Ausgabe (aus der Deklaration).
        var encoding: String.Encoding
    }

    public static func read(url: URL) throws -> NFOContents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: url.path)
        }
        return try parse(decode(data), path: url.path, companionOf: url)
    }

    /// Felder unter einem Dateistempel lesen (Konfliktschutz beim Schreiben).
    public static func readSnapshot(url: URL, expecting stamp: FileStamp? = nil)
        throws -> FileSnapshot<NFOContents> {
        try FileSnapshot.capture(at: url, expecting: stamp) { try read(url: url) }
    }

    static func parse(_ text: String, path: String, companionOf url: URL? = nil) throws -> NFOContents {
        guard let layout = try layout(of: text, path: path) else {
            // Kein XML mit NFO-Wurzel: Nur-URL oder gar keine NFO.
            guard isURLOnly(text) else { throw TagError.cannotOpen(path: path) }
            let urls = urlLines(in: text)
            var info = [DocumentInfoItem(label: "type", value: "url-only")]
            info.append(contentsOf: urls.map { DocumentInfoItem(label: "url", value: $0) })
            if let url { info.append(companionItem(for: url)) }
            return NFOContents(rootName: nil, fields: NFOFields(), info: info, urls: urls)
        }
        let document = try XMLTools.document(from: Data(layout.xml.utf8), path: path)
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: path) }
        let rootName = XMLTools.localName(root).lowercased()
        var fields = NFOFields()
        fields.title = XMLTools.text(of: "title", in: root)
        fields.originalTitle = XMLTools.text(of: "originaltitle", in: root)
        fields.sortTitle = XMLTools.text(of: "sorttitle", in: root)
        fields.year = XMLTools.text(of: "year", in: root)
        fields.premiered = XMLTools.text(of: "premiered", in: root)
        if fields.premiered.isEmpty { fields.premiered = XMLTools.text(of: "aired", in: root) }
        fields.plot = XMLTools.text(of: "plot", in: root)
        fields.outline = XMLTools.text(of: "outline", in: root)
        fields.tagline = XMLTools.text(of: "tagline", in: root)
        fields.genres = texts(of: "genre", in: root)
        fields.tags = texts(of: "tag", in: root)
        fields.studio = XMLTools.text(of: "studio", in: root)
        fields.directors = texts(of: "director", in: root)
        fields.credits = XMLTools.text(of: "credits", in: root)
        fields.rating = readRating(in: root)
        fields.userRating = XMLTools.text(of: "userrating", in: root)
        fields.mpaa = XMLTools.text(of: "mpaa", in: root)
        fields.runtime = XMLTools.text(of: "runtime", in: root)
        fields.season = XMLTools.text(of: "season", in: root)
        fields.episode = XMLTools.text(of: "episode", in: root)
        fields.showTitle = XMLTools.text(of: "showtitle", in: root)

        var info = [DocumentInfoItem(label: "type", value: rootName)]
        for actor in XMLTools.elements(named: "actor", in: root) {
            let name = XMLTools.text(of: "name", in: actor)
            let role = XMLTools.text(of: "role", in: actor)
            guard !name.isEmpty else { continue }
            info.append(DocumentInfoItem(label: "actor", value: role.isEmpty ? name : "\(name) (\(role))"))
        }
        for id in XMLTools.elements(named: "uniqueid", in: root) {
            let value = (id.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let type = XMLTools.attribute(id, "type") ?? ""
            let isDefault = XMLTools.attribute(id, "default")?.lowercased() == "true"
            var line = type.isEmpty ? value : "\(type): \(value)"
            if isDefault { line += " (default)" }
            info.append(DocumentInfoItem(label: "uniqueid", value: line))
        }
        for thumb in XMLTools.elements(named: "thumb", in: root) {
            let value = (thumb.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { info.append(DocumentInfoItem(label: "thumb", value: value)) }
        }
        for fanart in XMLTools.elements(named: "fanart", in: root) {
            for thumb in XMLTools.elements(named: "thumb", in: fanart) {
                let value = (thumb.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { info.append(DocumentInfoItem(label: "fanart", value: value)) }
            }
        }
        let urls = urlLines(in: layout.suffix)
        info.append(contentsOf: urls.map { DocumentInfoItem(label: "url", value: $0) })
        if let url { info.append(companionItem(for: url)) }
        return NFOContents(rootName: rootName, fields: fields, info: info, urls: urls)
    }

    /// Alle Textwerte gleichnamiger Elemente (leere übersprungen).
    private static func texts(of name: String, in parent: XMLElement) -> [String] {
        XMLTools.elements(named: name, in: parent)
            .map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Flaches `rating` gewinnt; sonst der Standard-Eintrag (oder der erste)
    /// unter `ratings/rating/value` (Kodi ab v17).
    private static func readRating(in root: XMLElement) -> String {
        let flat = XMLTools.text(of: "rating", in: root)
        if !flat.isEmpty { return flat }
        guard let entry = defaultRatingElement(in: root) else { return "" }
        return XMLTools.text(of: "value", in: entry)
    }

    private static func defaultRatingElement(in root: XMLElement) -> XMLElement? {
        guard let ratings = XMLTools.firstElement(named: "ratings", in: root) else { return nil }
        let entries = XMLTools.elements(named: "rating", in: ratings)
        return entries.first { XMLTools.attribute($0, "default")?.lowercased() == "true" } ?? entries.first
    }

    private static func urlLines(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isURLLine($0) }
    }

    /// Zeile „video = Dateiname" bzw. „video = (none)" für die Anzeige.
    private static func companionItem(for url: URL) -> DocumentInfoItem {
        DocumentInfoItem(label: "video",
                         value: MediaFormats.videoURL(forNFO: url)?.lastPathComponent ?? "(none)")
    }

    /// Zerlegt den Text in Vorspann, Wurzelelement und Nachspann; nil, wenn
    /// kein NFO-Wurzelelement gefunden wird.
    static func layout(of text: String, path: String) throws -> Layout? {
        guard let start = rootStartRange(in: text), rootName(in: text) != nil else { return nil }
        // Ende des Wurzelelements: das letzte `>` der Datei, hinter dem nur
        // noch Leerraum oder URL-Zeilen stehen.
        guard let end = text.lastIndex(of: ">") else { return nil }
        let after = text.index(after: end)
        let prefix = String(text[..<start.lowerBound])
        let xml = String(text[start.lowerBound..<after])
        let suffix = String(text[after...])
        let trailing = suffix.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard trailing.allSatisfy(isURLLine) else { throw TagError.cannotOpen(path: path) }
        return Layout(prefix: prefix, xml: xml, suffix: suffix, encoding: declaredEncoding(in: prefix))
    }

    /// Zeichensatz aus `encoding="…"` der Deklaration; Standard UTF-8.
    private static func declaredEncoding(in prefix: String) -> String.Encoding {
        guard let range = prefix.range(of: #"encoding\s*=\s*["']([^"']+)["']"#, options: .regularExpression)
        else { return .utf8 }
        let declaration = prefix[range]
        let name = declaration.split(separator: "=").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() ?? ""
        switch name {
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return .utf8
        }
    }

    // MARK: - Schreiben

    /// Prüft die Werte VOR Sicherung und Schreibweg; wirft
    /// `invalidDocumentValue`. Nur geänderte Felder werden geprüft.
    public static func validate(_ fields: NFOFields, original: NFOFields) throws {
        func requireInteger(_ value: String, _ original: String, field: String) throws {
            guard value != original, !value.isEmpty, Int(value) == nil else { return }
            throw TagError.invalidDocumentValue(field: field, reason: "expected a whole number")
        }
        func requireDecimal(_ value: String, _ original: String, field: String) throws {
            guard value != original, !value.isEmpty, Double(value) == nil else { return }
            throw TagError.invalidDocumentValue(field: field, reason: "expected a number such as 7.5")
        }
        if fields.year != original.year, !fields.year.isEmpty,
           fields.year.range(of: #"^\d{4}$"#, options: .regularExpression) == nil {
            throw TagError.invalidDocumentValue(field: "year", reason: "expected a four-digit year")
        }
        if fields.premiered != original.premiered, !fields.premiered.isEmpty,
           fields.premiered.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            throw TagError.invalidDocumentValue(field: "premiered", reason: "expected ISO 8601 (YYYY-MM-DD)")
        }
        try requireDecimal(fields.rating, original.rating, field: "rating")
        try requireDecimal(fields.userRating, original.userRating, field: "userrating")
        try requireInteger(fields.runtime, original.runtime, field: "runtime")
        try requireInteger(fields.season, original.season, field: "season")
        try requireInteger(fields.episode, original.episode, field: "episode")
        for (name, values) in [("genre", fields.genres), ("tag", fields.tags), ("director", fields.directors)]
        where values.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw TagError.invalidDocumentValue(field: name, reason: "values must not be empty")
        }
    }

    /// Schreibt die Unterschiede zu `original` atomar (Sicherung macht der
    /// Aufrufer). Eine Nur-URL-NFO wird nie beschrieben.
    public static func write(url: URL, fields: NFOFields, original: NFOFields,
                             expecting stamp: FileStamp? = nil) throws {
        try validate(fields, original: original)
        guard fields != original else {
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            try mutate(url: temp, originalPath: url.path, fields: fields, original: original)
        } validate: { temp in
            let readBack = try read(url: temp)
            guard !readBack.isURLOnly, readBack.fields == fields else {
                throw TagError.saveFailed(path: url.path)
            }
        }
    }

    /// Ändert die Datei direkt (Aufrufer arbeitet auf der Geschwisterkopie).
    static func mutate(url: URL, originalPath: String, fields: NFOFields, original: NFOFields) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: originalPath)
        }
        let text = decode(data)
        guard let layout = try layout(of: text, path: originalPath) else {
            throw TagError.urlOnlyNFO(path: originalPath)
        }
        let document = try XMLTools.document(from: Data(layout.xml.utf8), path: originalPath)
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: originalPath) }
        let rootName = XMLTools.localName(root).lowercased()

        func set(_ name: String, _ new: String, _ old: String) {
            guard new != old else { return }
            XMLTools.setSingle(root, name, prefix: "", value: new)
        }
        func setList(_ name: String, _ new: [String], _ old: [String]) {
            guard new != old else { return }
            // Neue Werte an der Stelle des ersten vorhandenen Elements
            // einfügen, damit die Gruppe nicht ans Ende wandert.
            let existing = XMLTools.elements(named: name, in: root)
            let anchor = existing.first?.index
            existing.forEach { $0.detach() }
            var position = anchor ?? root.childCount
            for value in new {
                root.insertChild(XMLTools.element(name, prefix: "", value: value), at: position)
                position += 1
            }
        }
        set("title", fields.title, original.title)
        set("originaltitle", fields.originalTitle, original.originalTitle)
        set("sorttitle", fields.sortTitle, original.sortTitle)
        set("year", fields.year, original.year)
        if fields.premiered != original.premiered {
            // Das Element behalten, das die Datei schon benutzt; sonst
            // `aired` für Episoden, `premiered` für alles andere.
            let name: String
            if XMLTools.firstElement(named: "premiered", in: root) != nil {
                name = "premiered"
            } else if XMLTools.firstElement(named: "aired", in: root) != nil {
                name = "aired"
            } else {
                name = rootName == "episodedetails" ? "aired" : "premiered"
            }
            XMLTools.setSingle(root, name, prefix: "", value: fields.premiered)
        }
        set("plot", fields.plot, original.plot)
        set("outline", fields.outline, original.outline)
        set("tagline", fields.tagline, original.tagline)
        setList("genre", fields.genres, original.genres)
        setList("tag", fields.tags, original.tags)
        set("studio", fields.studio, original.studio)
        setList("director", fields.directors, original.directors)
        set("credits", fields.credits, original.credits)
        if fields.rating != original.rating {
            if XMLTools.firstElement(named: "rating", in: root) == nil,
               let entry = defaultRatingElement(in: root) {
                XMLTools.setSingle(entry, "value", prefix: "", value: fields.rating)
            } else {
                XMLTools.setSingle(root, "rating", prefix: "", value: fields.rating)
            }
        }
        set("userrating", fields.userRating, original.userRating)
        set("mpaa", fields.mpaa, original.mpaa)
        set("runtime", fields.runtime, original.runtime)
        set("season", fields.season, original.season)
        set("episode", fields.episode, original.episode)
        set("showtitle", fields.showTitle, original.showTitle)

        let style = NFOWriter.Style(detectedFrom: layout.xml)
        let output = layout.prefix + NFOWriter.serialize(root, style: style) + layout.suffix
        guard let bytes = output.data(using: layout.encoding) else {
            throw TagError.saveFailed(path: originalPath)
        }
        do {
            // Eine BOM am Anfang bleibt erhalten, weil sie im Vorspann steckt
            // (decode entfernt sie, deshalb hier wieder voranstellen).
            var out = Data()
            if data.starts(with: [0xEF, 0xBB, 0xBF]), layout.encoding == .utf8 {
                out.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            out.append(bytes)
            try out.write(to: url)
        } catch {
            throw TagError.saveFailed(path: originalPath)
        }
    }
}

/// Serialisiert ein XML-Element in der Form, die die Quelldatei benutzt:
/// gleiche Einrückungsbreite (Leerzeichen oder Tab), gleiches Zeilenende und
/// gleiche Schreibweise leerer Elemente. Foundation-XML kennt den Leerraum
/// zwischen Elementen nach dem Parsen nicht mehr; der eigene Serialisierer
/// stellt ihn nach den erkannten Regeln wieder her. Für eine normal
/// eingerückte NFO ist das Ergebnis byteweise die Eingabe.
enum NFOWriter {

    struct Style {
        /// Eine Einrückungsstufe ("    ", "  " oder "\t").
        var indent: String
        var newline: String
        /// Leere Elemente: `<a></a>`, `<a/>` oder `<a />`.
        var emptyElement: EmptyElementStyle

        enum EmptyElementStyle {
            case openClose
            case selfClosing
            case selfClosingSpaced
        }

        static let `default` = Style(indent: "    ", newline: "\n", emptyElement: .openClose)

        /// Liest die Regeln aus dem XML-Text ab. Ohne eingerückte Zeile gilt
        /// die Kodi-Vorgabe (vier Leerzeichen).
        init(detectedFrom xml: String) {
            newline = xml.contains("\r\n") ? "\r\n" : "\n"
            var indent = Style.default.indent
            for line in xml.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                if !leading.isEmpty, leading.count < line.count {
                    indent = String(leading)
                    break
                }
            }
            self.indent = indent
            if xml.range(of: #"<[^>]*\s/>"#, options: .regularExpression) != nil {
                emptyElement = .selfClosingSpaced
            } else if xml.range(of: #"<[^>]*[^\s>]/>"#, options: .regularExpression) != nil {
                emptyElement = .selfClosing
            } else {
                emptyElement = .openClose
            }
        }

        init(indent: String, newline: String, emptyElement: EmptyElementStyle) {
            self.indent = indent
            self.newline = newline
            self.emptyElement = emptyElement
        }
    }

    static func serialize(_ root: XMLElement, style: Style) -> String {
        var out = ""
        write(root, depth: 0, style: style, into: &out)
        return out
    }

    private static func write(_ element: XMLElement, depth: Int, style: Style, into out: inout String) {
        let pad = String(repeating: style.indent, count: depth)
        let name = element.name ?? ""
        out += pad + "<" + name
        for attribute in element.attributes ?? [] {
            out += " \(attribute.name ?? "")=\"\(escapeAttribute(attribute.stringValue ?? ""))\""
        }
        let children = element.children ?? []
        if children.isEmpty {
            switch style.emptyElement {
            case .openClose: out += "></\(name)>"
            case .selfClosing: out += "/>"
            case .selfClosingSpaced: out += " />"
            }
            return
        }
        let hasElements = children.contains { $0.kind == .element || $0.kind == .comment }
        let hasText = children.contains {
            $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasElements && !hasText {
            // Reiner Elementcontainer: jedes Kind auf eigener Zeile.
            out += ">"
            for child in children {
                switch child.kind {
                case .element:
                    guard let child = child as? XMLElement else { continue }
                    out += style.newline
                    write(child, depth: depth + 1, style: style, into: &out)
                case .comment:
                    out += style.newline + pad + style.indent + "<!--\(child.stringValue ?? "")-->"
                case .processingInstruction:
                    out += style.newline + pad + style.indent + child.xmlString
                default:
                    // Leerraum-Text zwischen Elementen fällt weg; die
                    // Zeilenstruktur setzt der Serialisierer selbst.
                    continue
                }
            }
            out += style.newline + pad + "</\(name)>"
        } else {
            // Text (auch gemischt mit Elementen): in einer Zeile, Reihenfolge
            // der Kinder unverändert.
            out += ">"
            for child in children {
                switch child.kind {
                case .element:
                    if let child = child as? XMLElement {
                        var inline = ""
                        write(child, depth: 0, style: style, into: &inline)
                        out += inline
                    }
                case .comment:
                    out += "<!--\(child.stringValue ?? "")-->"
                default:
                    let raw = child.xmlString
                    if raw.hasPrefix("<![CDATA[") {
                        out += raw
                    } else {
                        out += escapeText(child.stringValue ?? "")
                    }
                }
            }
            out += "</\(name)>"
        }
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

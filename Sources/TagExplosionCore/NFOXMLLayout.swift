// Textgrenzen einer NFO: XML-Vorspann, ein Wurzelelement und Nachspann.
// Der Scanner findet nur Grenzen; die eigentliche XML-Prüfung übernimmt
// weiterhin XMLTools. Kommentare, CDATA und zitierte > zählen nicht als Tags.
import Foundation

struct NFOXMLLayout {
    var prefix: String
    var xml: String
    var suffix: String
    var encoding: String.Encoding
    var urls: [String]

    private struct Markup {
        enum Kind { case opening(String, empty: Bool), closing, other }
        var range: Range<String.Index>
        var kind: Kind
    }

    private static func markup(in text: String, at start: String.Index) -> Markup? {
        let rest = text[start...]
        for (prefix, ending) in [("<!--", "-->"), ("<?", "?>"), ("<![CDATA[", "]]>")] {
            if rest.hasPrefix(prefix) {
                guard let end = rest.range(of: ending) else { return nil }
                return Markup(range: start..<end.upperBound, kind: .other)
            }
        }
        var cursor = text.index(after: start)
        var quote: Character?
        var brackets = 0
        while cursor < text.endIndex {
            let character = text[cursor]
            if let delimiter = quote {
                if character == delimiter { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if text[cursor...].hasPrefix("<!--") {
                // Kommentare im internen DTD-Teil dürfen dessen Klammern
                // nicht verändern (z.B. ein ] innerhalb eines Kommentars).
                guard let end = text[cursor...].range(of: "-->") else { return nil }
                cursor = end.upperBound
                continue
            } else if character == "[" {
                brackets += 1
            } else if character == "]" {
                brackets = max(0, brackets - 1)
            } else if character == ">", brackets == 0 {
                let range = start..<text.index(after: cursor)
                if rest.hasPrefix("<!") { return Markup(range: range, kind: .other) }
                if rest.hasPrefix("</") { return Markup(range: range, kind: .closing) }
                let body = text[text.index(after: start)..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                let name = String(body.prefix { !$0.isWhitespace && $0 != "/" })
                return Markup(range: range, kind: .opening(name, empty: body.hasSuffix("/")))
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func firstElement(in text: String) -> Markup? {
        var cursor = text.startIndex
        while let start = text[cursor...].firstIndex(of: "<") {
            guard let token = markup(in: text, at: start) else { return nil }
            switch token.kind {
            case .opening: return token
            case .closing: return nil
            case .other: cursor = token.range.upperBound
            }
        }
        return nil
    }

    static func rootName(in text: String) -> String? {
        guard let root = firstElement(in: text), case .opening(let name, _) = root.kind,
              KodiNFOFile.rootNames.contains(name.lowercased()) else { return nil }
        return name.lowercased()
    }

    static func parse(_ text: String, path: String) throws -> NFOXMLLayout? {
        guard let root = firstElement(in: text), case .opening(let name, let empty) = root.kind,
              KodiNFOFile.rootNames.contains(name.lowercased()) else { return nil }
        var end = root.range.upperBound
        var depth = empty ? 0 : 1
        while depth > 0 {
            guard let start = text[end...].firstIndex(of: "<"), let token = markup(in: text, at: start)
            else { throw TagError.cannotOpen(path: path) }
            switch token.kind {
            case .opening(_, let empty): if !empty { depth += 1 }
            case .closing: depth -= 1
            case .other: break
            }
            end = token.range.upperBound
        }
        let prefix = String(text[..<root.range.lowerBound])
        let suffix = String(text[end...])
        guard let urls = trailingURLs(in: suffix) else { throw TagError.cannotOpen(path: path) }
        return NFOXMLLayout(prefix: prefix, xml: String(text[root.range.lowerBound..<end]),
                            suffix: suffix, encoding: declaredEncoding(in: prefix), urls: urls)
    }

    /// Nach dem Wurzelelement sind Leerraum, Kommentare, Verarbeitungs-
    /// anweisungen und Kodi-URL-Zeilen erlaubt. URLs in Kommentaren zählen nicht.
    private static func trailingURLs(in text: String) -> [String]? {
        var cursor = text.startIndex
        var urls: [String] = []
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
                continue
            }
            let rest = text[cursor...]
            if rest.hasPrefix("<!--") || rest.hasPrefix("<?") {
                guard let token = markup(in: text, at: cursor) else { return nil }
                cursor = token.range.upperBound
                continue
            }
            let end = rest.firstIndex(where: \.isNewline) ?? text.endIndex
            let line = String(text[cursor..<end]).trimmingCharacters(in: .whitespaces)
            guard KodiNFOFile.isURLLine(line) else { return nil }
            urls.append(line)
            cursor = end
        }
        return urls
    }

    /// Zeichensatz aus der Deklaration; Standard UTF-8.
    private static func declaredEncoding(in prefix: String) -> String.Encoding {
        guard let range = prefix.range(of: #"encoding\s*=\s*["']([^"']+)["']"#, options: .regularExpression)
        else { return .utf8 }
        let name = prefix[range].split(separator: "=").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() ?? ""
        switch name {
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return .utf8
        }
    }
}

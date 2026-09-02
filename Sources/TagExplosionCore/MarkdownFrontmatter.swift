// Markdown mit YAML-Frontmatter: ein Block zwischen `---` in der ersten Zeile
// und der nächsten `---`-Zeile (oder `...`). Bewusst KEIN vollständiger
// YAML-Parser (keine Abhängigkeit): Verstanden wird das flache Subset
//   key: wert            (auch "…"/'…' in Anführungszeichen)
//   key: [a, b]          (Fließliste)
//   key:                 (Blockliste)
//     - a
//     - b
// Alles andere (verschachtelte Maps, Blockskalare `|`/`>`, Anker …) bleibt als
// „komplexer“ Eintrag erhalten und wird beim Schreiben unverändert
// durchgereicht. Auch unveränderte einfache Einträge werden aus ihren
// Rohzeilen zurückgeschrieben; nur geänderte werden neu erzeugt. Der Body
// nach dem Block wird byte-identisch übernommen.
import Foundation

/// Ein Eintrag des Frontmatters mit seinen Rohzeilen (ohne Zeilenende).
struct FrontmatterEntry: Equatable {
    enum Value: Equatable {
        case scalar(String)
        case list([String])
        /// Nicht verstandene Struktur — nur die Rohzeilen zählen.
        case complex
    }

    /// Leer für Zeilen ohne Schlüssel (Kommentare, Leerzeilen am Blockanfang).
    var key: String
    var value: Value
    var rawLines: [String]

    /// Neu erzeugter Eintrag; die Rohzeilen entstehen beim Serialisieren.
    static func scalar(_ key: String, _ value: String) -> FrontmatterEntry {
        FrontmatterEntry(key: key, value: .scalar(value),
                         rawLines: ["\(key): \(MarkdownFrontmatter.yamlScalar(value))"])
    }

    static func list(_ key: String, _ values: [String]) -> FrontmatterEntry {
        let items = values.map(MarkdownFrontmatter.yamlScalar).joined(separator: ", ")
        return FrontmatterEntry(key: key, value: .list(values), rawLines: ["\(key): [\(items)]"])
    }

    /// Einfacher Wert als Text: Skalar direkt, Liste kommagetrennt.
    var displayValue: String? {
        switch value {
        case .scalar(let text): return text
        case .list(let items): return items.joined(separator: ", ")
        case .complex: return nil
        }
    }

    var listValue: [String] {
        switch value {
        case .scalar(let text): return text.splitCommaList()
        case .list(let items): return items
        case .complex: return []
        }
    }
}

/// Zerlegte Markdown-Datei: Frontmatter-Einträge plus unveränderter Body.
struct MarkdownDocument: Equatable {
    /// Byte-Order-Mark am Dateianfang (bleibt erhalten).
    var bom: Data
    /// nil = die Datei hat kein Frontmatter.
    var entries: [FrontmatterEntry]?
    /// Zeilenende des Blocks ("\n" oder "\r\n"); bei fehlendem Block das der
    /// ersten Body-Zeile, sonst "\n".
    var lineEnding: String
    /// Alles nach der schließenden Trennzeile, byte-identisch.
    var body: Data

    func entry(_ key: String) -> FrontmatterEntry? {
        entries?.first { $0.key == key }
    }
}

enum MarkdownFrontmatter {

    private static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    // MARK: - Parsen

    static func parse(_ data: Data, path: String) throws -> MarkdownDocument {
        var bytes = [UInt8](data)
        var bom = Data()
        if bytes.starts(with: bomBytes) {
            bom = Data(bomBytes)
            bytes.removeFirst(bomBytes.count)
        }
        let lines = splitLines(bytes)
        let lineEnding = lines.first?.ending ?? "\n"

        // Erste Zeile muss genau "---" sein, sonst gibt es keinen Block.
        guard let first = lines.first, first.text == "---",
              let closing = lines.dropFirst().firstIndex(where: {
                  $0.text == "---" || $0.text == "..."
              }) else {
            return MarkdownDocument(bom: bom, entries: nil, lineEnding: lineEnding,
                                    body: Data(bytes))
        }
        let blockLines = lines[1..<closing]
        var text: [String] = []
        for line in blockLines {
            guard let decoded = String(bytes: line.bytes, encoding: .utf8) else {
                throw TagError.cannotOpen(path: path)
            }
            text.append(decoded)
        }
        let bodyStart = lines[closing].end
        return MarkdownDocument(bom: bom, entries: group(text), lineEnding: lineEnding,
                                body: Data(bytes[bodyStart...]))
    }

    private struct Line {
        let bytes: ArraySlice<UInt8>
        /// "\n" oder "\r\n"; leer für die letzte Zeile ohne Zeilenende.
        let ending: String
        /// Byte-Offset direkt hinter dem Zeilenende.
        let end: Int
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private static func splitLines(_ bytes: [UInt8]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                let hasCR = index > start && bytes[index - 1] == 0x0D
                let contentEnd = hasCR ? index - 1 : index
                lines.append(Line(bytes: bytes[start..<contentEnd], ending: hasCR ? "\r\n" : "\n",
                                  end: index + 1))
                start = index + 1
            }
            index += 1
        }
        if start < bytes.count {
            lines.append(Line(bytes: bytes[start...], ending: "", end: bytes.count))
        }
        return lines
    }

    /// Zeilen zu Einträgen bündeln: Eine Zeile am linken Rand mit `key:`
    /// beginnt einen Eintrag, alle folgenden eingerückten oder Listenzeilen
    /// gehören dazu.
    private static func group(_ lines: [String]) -> [FrontmatterEntry] {
        var entries: [FrontmatterEntry] = []
        var current: (key: String, lines: [String])?

        func flush() {
            guard let block = current else { return }
            entries.append(classify(key: block.key, lines: block.lines))
            current = nil
        }
        for line in lines {
            if let key = keyOfEntryLine(line) {
                flush()
                current = (key, [line])
            } else if current != nil {
                current!.lines.append(line)
            } else {
                // Kommentar/Leerzeile vor dem ersten Schlüssel.
                entries.append(FrontmatterEntry(key: "", value: .complex, rawLines: [line]))
            }
        }
        flush()
        return entries
    }

    /// Schlüssel einer Eintragszeile (`key:` am Zeilenanfang), sonst nil.
    private static func keyOfEntryLine(_ line: String) -> String? {
        guard let firstChar = line.first, !firstChar.isWhitespace, firstChar != "#",
              firstChar != "-",
              let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else {
            return nil
        }
        let afterColon = line.index(after: colon)
        // "key:" am Zeilenende oder "key: …" — ein Doppelpunkt mitten in einem
        // Wort (z.B. eine URL) ist kein Schlüssel.
        guard afterColon == line.endIndex || line[afterColon] == " " || line[afterColon] == "\t" else {
            return nil
        }
        return key
    }

    private static func classify(key: String, lines: [String]) -> FrontmatterEntry {
        let first = lines[0]
        let colon = first.firstIndex(of: ":")!
        let rest = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let continuation = lines.dropFirst()
        let meaningful = continuation.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }

        if rest.isEmpty {
            if meaningful.isEmpty {
                return FrontmatterEntry(key: key, value: .scalar(""), rawLines: lines)
            }
            // Blockliste: jede sinnvolle Folgezeile ist "- wert".
            var items: [String] = []
            for line in meaningful {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") || trimmed == "-",
                      let item = parseScalar(String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                else {
                    return FrontmatterEntry(key: key, value: .complex, rawLines: lines)
                }
                items.append(item)
            }
            return FrontmatterEntry(key: key, value: .list(items), rawLines: lines)
        }
        // Ein Wert in der ersten Zeile darf keine Fortsetzung haben (mehrzeilige
        // Skalare sind „komplex“).
        guard meaningful.isEmpty else {
            return FrontmatterEntry(key: key, value: .complex, rawLines: lines)
        }
        if rest.hasPrefix("[") {
            guard rest.hasSuffix("]"), let items = parseFlowList(rest) else {
                return FrontmatterEntry(key: key, value: .complex, rawLines: lines)
            }
            return FrontmatterEntry(key: key, value: .list(items), rawLines: lines)
        }
        guard let scalar = parseScalar(rest) else {
            return FrontmatterEntry(key: key, value: .complex, rawLines: lines)
        }
        return FrontmatterEntry(key: key, value: .scalar(scalar), rawLines: lines)
    }

    /// Skalar lesen: doppelte Anführungszeichen mit Escapes, einfache mit
    /// `''`, sonst unquotiert (Kommentar hinter ` #` fällt weg). nil für
    /// Formen außerhalb des Subsets (Blockskalar, Fließmap, Anker, Tags).
    static func parseScalar(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "" }
        if text.hasPrefix("\"") {
            return parseDoubleQuoted(text)
        }
        if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { return nil }
            let inner = text.dropFirst().dropLast()
            // '' ist das einzige Escape in einfachen Anführungszeichen.
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        if let firstChar = text.first, "|>{&*!%@`".contains(firstChar) { return nil }
        // Kommentar: " #" (Leerraum davor ist Pflicht laut YAML).
        var value = text
        if let range = value.range(of: " #") ?? value.range(of: "\t#") {
            value = String(value[..<range.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func parseDoubleQuoted(_ text: String) -> String? {
        var result = ""
        var iterator = text.dropFirst().makeIterator()
        var closed = false
        while let char = iterator.next() {
            if closed {
                // Nach dem schließenden Zeichen nur noch Kommentar/Leerraum.
                let remainder = String(char)
                guard remainder.trimmingCharacters(in: .whitespaces).isEmpty || char == "#" else { return nil }
                break
            }
            switch char {
            case "\\":
                guard let escaped = iterator.next() else { return nil }
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case " ": result.append(" ")
                default: return nil
                }
            case "\"":
                closed = true
            default:
                result.append(char)
            }
        }
        return closed ? result : nil
    }

    /// "[a, "b, c", 'd']" → ["a", "b, c", "d"]
    private static func parseFlowList(_ text: String) -> [String]? {
        let inner = text.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        for char in inner {
            if let open = quote {
                current.append(char)
                if char == open, previous != "\\" { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
                current.append(char)
            } else if char == "," {
                items.append(current)
                current = ""
            } else {
                current.append(char)
            }
            previous = char
        }
        guard quote == nil else { return nil }
        items.append(current)
        var parsed: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = parseScalar(trimmed) else { return nil }
            parsed.append(value)
        }
        return parsed
    }

    // MARK: - Serialisieren

    /// Wert als YAML-Skalar. Unquotiert, wenn er unmissverständlich ein Text
    /// bleibt; sonst in doppelten Anführungszeichen mit Escapes. Zahlen und
    /// Wahrheitswerte werden quotiert, damit andere Leser sie nicht umdeuten;
    /// ISO-Daten ("2024-01-05") bleiben unquotiert, wie in Frontmatter üblich.
    static func yamlScalar(_ value: String) -> String {
        guard needsQuoting(value) else { return value }
        var escaped = ""
        for char in value {
            switch char {
            case "\\": escaped.append("\\\\")
            case "\"": escaped.append("\\\"")
            case "\n": escaped.append("\\n")
            case "\r": escaped.append("\\r")
            case "\t": escaped.append("\\t")
            default: escaped.append(char)
            }
        }
        return "\"\(escaped)\""
    }

    private static func needsQuoting(_ value: String) -> Bool {
        guard let first = value.first, let last = value.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if last == ":" { return true }
        if value.contains(": ") || value.contains(" #") || value.contains("\t")
            || value.contains("\n") || value.contains("\r") { return true }
        let lowered = value.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~", ".inf", ".nan"].contains(lowered) {
            return true
        }
        // Zahlen (auch mit Unterstrichen, Exponent, hex) würden als Zahl gelesen.
        if value.range(of: #"^[-+]?(\d[\d_]*(\.\d*)?([eE][-+]?\d+)?|\.\d+|0x[0-9a-fA-F]+|0o[0-7]+)$"#,
                       options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Setzt die Datei wieder zusammen. Ein leerer Block (keine Einträge)
    /// wird weggelassen, damit aus einer Datei ohne Frontmatter keine leere
    /// `---`-Hülle entsteht.
    static func serialize(_ document: MarkdownDocument) -> Data {
        var output = document.bom
        let ending = document.lineEnding
        if let entries = document.entries, !entries.isEmpty {
            var text = "---" + ending
            for entry in entries {
                for line in entry.rawLines { text += line + ending }
            }
            text += "---" + ending
            output.append(Data(text.utf8))
        }
        output.append(document.body)
        return output
    }
}

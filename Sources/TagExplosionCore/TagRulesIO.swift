import Foundation

/// Regeldateien lesen und schreiben; ergänzt Fehler um die JSON-Zeile.
public enum TagRulesIO {

    public static func load(_ url: URL) throws -> TagRuleDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagRulesError.invalidJSON(line: nil, reason: error.localizedDescription)
        }
        return try parse(data)
    }

    /// Liest eine Regeldatei aus JSON-Daten. Reihenfolge der Prüfungen:
    /// JSON-Syntax → Struktur (unbekannte Aktion usw.) → Version → Inhalt
    /// jeder Regel. Jede Stufe nennt, wo es hakt.
    public static func parse(_ data: Data) throws -> TagRuleDocument {
        let text = String(decoding: data, as: UTF8.self)
        // Syntaxfehler zuerst getrennt prüfen: Foundations Meldung nennt
        // die Zeile, JSONDecoder verpackt sie nur noch als Text.
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription
            throw TagRulesError.invalidJSON(line: lineNumber(in: reason), reason: reason)
        }
        let document: TagRuleDocument
        do {
            document = try JSONDecoder().decode(TagRuleDocument.self, from: data)
        } catch let error as DecodingError {
            throw translate(error, text: text)
        }
        do {
            try document.validate()
        } catch TagRulesError.invalidRule(let index, _, let reason) {
            throw TagRulesError.invalidRule(index: index, line: lineOfRule(index, in: text), reason: reason)
        }
        return document
    }

    /// Serialisiert eine Regeldatei (lesbar eingerückt, Schlüssel sortiert).
    public static func encode(_ document: TagRuleDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func save(_ document: TagRuleDocument, to url: URL) throws {
        // Wie jeder andere Export über den gemeinsamen Weg: Eine vorhandene
        // Regeldatei am Zielpfad wird gesichert und dann atomar ersetzt.
        try FileExport.write(try encode(document), to: url)
    }

    /// Kommentierte Beispiel-Regeldatei (`tagx apply --example`). JSON kennt
    /// keine Kommentare, deshalb `_comment`-Felder.
    public static let exampleJSON = """
    {
      "_comment": "Tag Explosion rules file — tagx apply rules.json [--apply] <files>. Rules run in order; field names are the same as in file name patterns (title, artist, album, albumartist, track, disc, year, genre, composer, comment or any tag key).",
      "version": 1,
      "rules": [
        {
          "_comment": "Remove spaces and control characters at both ends and collapse double spaces — in every field.",
          "action": "trim",
          "field": "*"
        },
        {
          "_comment": "Title case for titles: every word capitalized, small words (a, the, und, der …) lowercase; set smallWords to use your own list.",
          "action": "case",
          "field": "title",
          "mode": "title"
        },
        {
          "_comment": "Album artist from artist, only where it is still empty. Placeholders work like in file name patterns.",
          "action": "copy",
          "field": "albumartist",
          "from": "artist",
          "onlyIfEmpty": true
        },
        {
          "_comment": "Same thing written with set and a condition (when: empty, notEmpty, equals, contains, matches).",
          "action": "set",
          "field": "albumartist",
          "value": "%{artist}",
          "when": { "field": "albumartist", "is": "empty" }
        },
        {
          "_comment": "Literal search/replace; with \\"regex\\": true, groups are available as $1, $2 …",
          "action": "replace",
          "field": "title",
          "search": "^(.*) \\\\(Remastered\\\\)$",
          "replacement": "$1",
          "regex": true
        },
        {
          "_comment": "Remove a field, here only for audio files (kinds: audio, image, ebook, document, sidecar).",
          "action": "remove",
          "field": "comment",
          "kinds": ["audio"]
        },
        {
          "_comment": "Track numbers 1…n in file name order (sortBy: filename or a field), written as n/total.",
          "action": "number",
          "field": "track",
          "sortBy": "filename",
          "start": 1,
          "total": true
        }
      ]
    }
    """

    // MARK: Zeilen finden

    /// Übersetzt einen Decoder-Fehler in einen Regelfehler mit Zeile. Der
    /// Coding-Pfad verrät, in welcher Regel es hakt (`rules[3].action`).
    private static func translate(_ error: DecodingError, text: String) -> TagRulesError {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c),
             .typeMismatch(_, let c), .valueNotFound(_, let c):
            context = c
        @unknown default:
            return .invalidJSON(line: nil, reason: String(describing: error))
        }
        var reason = context.debugDescription
        if case .keyNotFound(let key, _) = error {
            reason = "missing key \"\(key.stringValue)\""
        }
        // Pfad: [rules, Index 3, action] → Regel 3, Schlüssel "action".
        var ruleIndex: Int?
        var keyName: String?
        var sawRules = false
        for component in context.codingPath {
            if let index = component.intValue, sawRules, ruleIndex == nil {
                ruleIndex = index
            } else if component.stringValue == "rules" {
                sawRules = true
            } else if ruleIndex != nil {
                keyName = component.stringValue
            }
        }
        if let keyName, !reason.lowercased().contains("\"\(keyName)\"") {
            reason = "key \"\(keyName)\": \(reason)"
        }
        guard let ruleIndex else { return .invalidJSON(line: nil, reason: reason) }
        return .invalidRule(index: ruleIndex, line: lineOfRule(ruleIndex, in: text), reason: reason)
    }

    /// „… around line 12, column 3." → 12
    static func lineNumber(in message: String) -> Int? {
        guard let range = message.range(of: #"line (\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(message[range].dropFirst(5))
    }

    /// Zeile (ab 1), in der die n-te Regel des `rules`-Arrays beginnt. Ein
    /// kleiner Scanner, der Strings überspringt und Klammern zählt — genau
    /// genug für Fehlermeldungen; nil, wenn die Struktur nicht passt.
    static func lineOfRule(_ index: Int, in text: String) -> Int? {
        var line = 1
        var depth = 0
        var inString = false
        var escaped = false
        var lastString = ""
        var currentString = ""
        // Tiefe, auf der die Elemente des rules-Arrays liegen (nil = noch
        // nicht gefunden).
        var rulesDepth: Int?
        var elementIndex = -1
        var expectingRulesArray = false

        for scalar in text.unicodeScalars {
            if scalar == "\n" { line += 1 }
            if inString {
                if escaped {
                    escaped = false
                    currentString.unicodeScalars.append(scalar)
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                    lastString = currentString
                } else {
                    currentString.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                inString = true
                currentString = ""
            case ":":
                // "rules": auf der obersten Ebene → das nächste [ ist das Array.
                if depth == 1, lastString == "rules" { expectingRulesArray = true }
            case "[":
                depth += 1
                if expectingRulesArray {
                    rulesDepth = depth
                    expectingRulesArray = false
                }
            case "{":
                depth += 1
                if let rulesDepth, depth == rulesDepth + 1 {
                    elementIndex += 1
                    if elementIndex == index { return line }
                }
            case "]", "}":
                depth -= 1
                if let d = rulesDepth, depth < d { return nil }
            case " ", "\t", "\r", "\n", ",":
                break
            default:
                // Ein Wert außer String/Objekt/Array (Zahl, true …): egal.
                expectingRulesArray = false
            }
        }
        return nil
    }
}

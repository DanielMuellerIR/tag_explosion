// Batch-Regeln als Skript: eine JSON-Datei mit einer Liste von Regeln, die
// nacheinander auf die Felder mehrerer Dateien angewendet werden — etwa
// „Titel in Titel-Schreibweise", „Leerzeichen trimmen", „Albumkünstler aus
// Künstler übernehmen, wenn leer".
//
// Aufbau dieser Datei:
//   1. Datenmodell (`TagRuleDocument`, `TagRule`, `TagRuleCondition`) — flach
//      gehalten, damit JSON und der Regel-Editor der App dieselben Felder
//      benutzen können.
//   2. Laden/Speichern (`TagRulesIO`) mit Fehlern, die die Regelnummer und
//      die JSON-Zeile nennen.
//   3. Die Engine (`TagRuleEngine`) — eine reine Funktion: Felder rein,
//      Änderungsplan raus. Geschrieben wird hier nie; das erledigen CLI und
//      App über die bestehenden Schreibwege (Sicherung + atomarer Austausch).
//   4. Textwerkzeuge (Groß-/Kleinschreibung, Trimmen, Platzhalter).
//
// Audio-Regeln erhalten alle Werte. Dateinamen, Bedingungen und Platzhalter
// verwenden weiterhin den ersten Wert je Schlüssel.
import Foundation

// MARK: - Datenmodell

/// Eine Regeldatei: Versionsnummer plus Regeln in Ausführungsreihenfolge.
public struct TagRuleDocument: Codable, Sendable, Equatable {
    /// Schema-Version dieser Datei. Beim Lesen werden nur bekannte Versionen
    /// angenommen, damit eine Datei aus einer neueren App nicht still falsch
    /// gelesen wird.
    public static let currentVersion = 1

    public var version: Int
    /// Freier Hinweistext (JSON kennt keine Kommentare). Wird beim Laden
    /// mitgenommen und beim Speichern erhalten.
    public var comment: String?
    public var rules: [TagRule]

    enum CodingKeys: String, CodingKey {
        case version
        case comment = "_comment"
        case rules
    }

    public init(version: Int = TagRuleDocument.currentVersion, comment: String? = nil,
                rules: [TagRule] = []) {
        self.version = version
        self.comment = comment
        self.rules = rules
    }

    /// Prüft Version und jede Regel (Pflichtparameter, reguläre Ausdrücke).
    /// Der Fehler nennt die Regelnummer (ab 1); die JSON-Zeile ergänzt
    /// `TagRulesIO.load`, das den Text kennt.
    public func validate() throws {
        guard version == Self.currentVersion else {
            throw TagRulesError.unsupportedVersion(version)
        }
        for (index, rule) in rules.enumerated() {
            do {
                try rule.validate()
            } catch let error as TagRulesError {
                // Die Regel kennt ihre Nummer nicht; hier wird sie ergänzt.
                if case .invalidRule(_, let line, let reason) = error {
                    throw TagRulesError.invalidRule(index: index, line: line, reason: reason)
                }
                throw error
            }
        }
    }
}

/// Eine einzelne Regel: optionaler Filter plus genau eine Aktion.
///
/// Das Modell ist bewusst flach (alle Parameter als optionale Eigenschaften
/// statt Enum mit zugeordneten Werten): So lässt sich jede Regel direkt in
/// SwiftUI-Formularfelder binden, und die JSON-Form bleibt eine einfache
/// Liste von Schlüssel-Wert-Paaren. Welche Parameter eine Aktion braucht,
/// prüft `validate()`.
public struct TagRule: Codable, Sendable, Equatable {

    /// Die Aktionen; der Rohwert ist die JSON-Schreibweise.
    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Feld = Wert (mit Platzhaltern wie `%{artist}`).
        case set
        /// Feld ← anderes Feld (optional nur, wenn das Ziel leer ist).
        case copy
        /// Suchen/Ersetzen im Feld, wörtlich oder als regulärer Ausdruck.
        case replace
        /// Groß-/Kleinschreibung ändern.
        case `case`
        /// Leerzeichen und Steuerzeichen am Rand entfernen, Mehrfach-
        /// Leerzeichen zusammenziehen.
        case trim
        /// Feld löschen.
        case remove
        /// Tracknummern fortlaufend vergeben.
        case number
    }

    /// Schreibweisen für die Aktion `case`.
    public enum CaseMode: String, Codable, Sendable, CaseIterable {
        case upper
        case lower
        /// Jedes Wort groß, kleine Wörter (a, the, und, der …) klein.
        case title
        /// Nur der Satzanfang groß.
        case sentence
    }

    /// Freier Hinweistext zur Regel (JSON-Schlüssel `_comment`).
    public var comment: String?
    /// Nur auf diese Medienarten anwenden; nil = alle.
    public var kinds: [MediaFormats.Kind]?
    /// Feld-Bedingung; nil = immer.
    public var when: TagRuleCondition?

    public var action: Action
    /// Zielfeld (kanonischer Schlüssel wie "TITLE"; `*` = alle Felder, nur
    /// bei `replace`, `case` und `trim`).
    public var field: String
    /// `set`: der Wert, mit Platzhaltern `%{artist}` usw.
    public var value: String?
    /// `copy`: Quellfeld.
    public var from: String?
    /// `copy`: nur kopieren, wenn das Ziel leer ist (Voreinstellung: nein).
    public var onlyIfEmpty: Bool?
    /// `replace`: Suchtext (wörtlich oder Regex, siehe `regex`).
    public var search: String?
    /// `replace`: Ersatztext; bei Regex mit Gruppen `$1`, `$2` ….
    public var replacement: String?
    /// `replace`: `search` als regulärer Ausdruck lesen (Voreinstellung: nein).
    public var regex: Bool?
    /// `replace` und Bedingung `contains`: Groß-/Kleinschreibung ignorieren
    /// (Voreinstellung: nein).
    public var ignoreCase: Bool?
    /// `case`: die Schreibweise.
    public var mode: CaseMode?
    /// `case` mit `title`: Wörter, die klein bleiben (nil = Standardliste).
    public var smallWords: [String]?
    /// `number`: Sortierung — `filename` (Voreinstellung) oder ein Feld.
    public var sortBy: String?
    /// `number`: erste Nummer (Voreinstellung 1).
    public var start: Int?
    /// `number`: Gesamtzahl anhängen, also "3/12" (Voreinstellung: nein).
    public var total: Bool?
    /// `number`: Mindestbreite mit führenden Nullen (nil = keine).
    public var width: Int?

    /// `field` darf bei `number` fehlen (dann TRACKNUMBER).
    public init(action: Action, field: String = "", value: String? = nil, from: String? = nil,
                onlyIfEmpty: Bool? = nil, search: String? = nil, replacement: String? = nil,
                regex: Bool? = nil, ignoreCase: Bool? = nil, mode: CaseMode? = nil,
                smallWords: [String]? = nil, sortBy: String? = nil, start: Int? = nil,
                total: Bool? = nil, width: Int? = nil, kinds: [MediaFormats.Kind]? = nil,
                when: TagRuleCondition? = nil, comment: String? = nil) {
        self.action = action
        let name = field.trimmingCharacters(in: .whitespaces)
        self.field = TagRule.canonicalField(name.isEmpty && action == .number ? "TRACKNUMBER" : name)
        self.value = value
        self.from = from.map(TagRule.canonicalField)
        self.onlyIfEmpty = onlyIfEmpty
        self.search = search
        self.replacement = replacement
        self.regex = regex
        self.ignoreCase = ignoreCase
        self.mode = mode
        self.smallWords = smallWords
        self.sortBy = sortBy.map(TagRule.canonicalSortKey)
        self.start = start
        self.total = total
        self.width = width
        self.kinds = kinds
        self.when = when
        self.comment = comment
    }

    /// Feldnamen wie bei den Dateinamen-Mustern: `title` → "TITLE",
    /// `albumartist` → "ALBUMARTIST", Unbekanntes großgeschrieben. `*`
    /// bleibt `*`.
    public static func canonicalField(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed == "*" ? "*" : FilenamePattern.canonicalKey(for: trimmed)
    }

    /// `filename` bleibt das Schlüsselwort, alles andere ist ein Feldname.
    static func canonicalSortKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased() == "filename" ? "filename" : canonicalField(trimmed)
    }

    /// Standardliste kleiner Wörter für die Titel-Schreibweise (Englisch und
    /// Deutsch). Wer andere braucht, setzt `smallWords` in der Regel.
    public static let defaultSmallWords: [String] = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "by",
        "und", "oder", "der", "die", "das", "des", "dem", "den", "ein", "eine",
        "einer", "eines", "im", "am", "vom", "zum", "zur", "von", "mit", "aus",
        "auf", "für", "bei", "zu",
    ]

    enum CodingKeys: String, CodingKey {
        case comment = "_comment"
        case kinds, when, action, field, value, from, onlyIfEmpty, search, replacement
        case regex, ignoreCase, mode, smallWords, sortBy, start, total, width
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Die Aktion von Hand lesen, damit die Fehlermeldung den unbekannten
        // Namen nennt statt eines generischen „Cannot initialize Action".
        let actionName = try container.decode(String.self, forKey: .action)
        guard let action = Action(rawValue: actionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .action, in: container,
                debugDescription: "unknown action \"\(actionName)\" (expected one of "
                    + Action.allCases.map(\.rawValue).joined(separator: ", ") + ")")
        }
        var mode: CaseMode?
        if let modeName = try container.decodeIfPresent(String.self, forKey: .mode) {
            guard let parsed = CaseMode(rawValue: modeName) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: container,
                    debugDescription: "unknown case mode \"\(modeName)\" (expected one of "
                        + CaseMode.allCases.map(\.rawValue).joined(separator: ", ") + ")")
            }
            mode = parsed
        }
        self.init(
            action: action,
            field: try container.decodeIfPresent(String.self, forKey: .field) ?? "",
            value: try container.decodeIfPresent(String.self, forKey: .value),
            from: try container.decodeIfPresent(String.self, forKey: .from),
            onlyIfEmpty: try container.decodeIfPresent(Bool.self, forKey: .onlyIfEmpty),
            search: try container.decodeIfPresent(String.self, forKey: .search),
            replacement: try container.decodeIfPresent(String.self, forKey: .replacement),
            regex: try container.decodeIfPresent(Bool.self, forKey: .regex),
            ignoreCase: try container.decodeIfPresent(Bool.self, forKey: .ignoreCase),
            mode: mode,
            smallWords: try container.decodeIfPresent([String].self, forKey: .smallWords),
            sortBy: try container.decodeIfPresent(String.self, forKey: .sortBy),
            start: try container.decodeIfPresent(Int.self, forKey: .start),
            total: try container.decodeIfPresent(Bool.self, forKey: .total),
            width: try container.decodeIfPresent(Int.self, forKey: .width),
            kinds: try container.decodeIfPresent([MediaFormats.Kind].self, forKey: .kinds),
            when: try container.decodeIfPresent(TagRuleCondition.self, forKey: .when),
            comment: try container.decodeIfPresent(String.self, forKey: .comment))
    }

    /// Schreibt nur die Parameter, die die Aktion wirklich benutzt — eine
    /// gespeicherte Datei soll nicht mit Resten aus früheren Bearbeitungen
    /// im Editor verwirren.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encode(action, forKey: .action)
        try container.encode(field, forKey: .field)
        switch action {
        case .set:
            try container.encode(value ?? "", forKey: .value)
        case .copy:
            try container.encode(from ?? "", forKey: .from)
            try container.encodeIfPresent(onlyIfEmpty, forKey: .onlyIfEmpty)
        case .replace:
            try container.encode(search ?? "", forKey: .search)
            try container.encode(replacement ?? "", forKey: .replacement)
            try container.encodeIfPresent(regex, forKey: .regex)
            try container.encodeIfPresent(ignoreCase, forKey: .ignoreCase)
        case .case:
            try container.encode(mode ?? .title, forKey: .mode)
            try container.encodeIfPresent(smallWords, forKey: .smallWords)
        case .trim, .remove:
            break
        case .number:
            try container.encodeIfPresent(sortBy, forKey: .sortBy)
            try container.encodeIfPresent(start, forKey: .start)
            try container.encodeIfPresent(total, forKey: .total)
            try container.encodeIfPresent(width, forKey: .width)
        }
        try container.encodeIfPresent(kinds, forKey: .kinds)
        try container.encodeIfPresent(when, forKey: .when)
    }

    /// Prüft Pflichtparameter und reguläre Ausdrücke. Fehler ohne
    /// Regelnummer (0); `TagRuleDocument.validate` trägt die Nummer nach.
    public func validate() throws {
        func fail(_ reason: String) -> TagRulesError {
            .invalidRule(index: 0, line: nil, reason: reason)
        }
        if field.isEmpty { throw fail("\"field\" is required for action \"\(action.rawValue)\"") }
        let wildcardAllowed: Set<Action> = [.replace, .case, .trim]
        if field == "*", !wildcardAllowed.contains(action) {
            throw fail("field \"*\" is only allowed for replace, case and trim")
        }
        switch action {
        case .set:
            guard value != nil else { throw fail("\"value\" is required for action \"set\"") }
        case .copy:
            guard let from, !from.isEmpty, from != "*" else {
                throw fail("\"from\" (source field) is required for action \"copy\"")
            }
        case .replace:
            guard let search, !search.isEmpty else {
                throw fail("\"search\" is required for action \"replace\"")
            }
            if regex == true { try Self.requireRegex(search, label: "search") }
        case .case:
            guard mode != nil else {
                throw fail("\"mode\" (upper, lower, title, sentence) is required for action \"case\"")
            }
        case .trim, .remove:
            break
        case .number:
            if let start, start < 0 { throw fail("\"start\" must not be negative") }
            if let width, !(1...9).contains(width) { throw fail("\"width\" must be between 1 and 9") }
        }
        if let when {
            if when.field.isEmpty { throw fail("\"when.field\" is required") }
            switch when.test {
            case .matches:
                guard let pattern = when.value else { throw fail("\"when.value\" is required for \"matches\"") }
                try Self.requireRegex(pattern, label: "when.value")
            case .equals, .contains:
                guard when.value != nil else {
                    throw fail("\"when.value\" is required for \"\(when.test.rawValue)\"")
                }
            case .empty, .notEmpty:
                break
            }
        }
    }

    private static func requireRegex(_ pattern: String, label: String) throws {
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw TagRulesError.invalidRule(
                index: 0, line: nil, reason: "\"\(label)\" is not a valid regular expression: \(pattern)")
        }
    }
}

/// Feld-Bedingung einer Regel: `{"field": "albumartist", "is": "empty"}`.
public struct TagRuleCondition: Codable, Sendable, Equatable {
    public enum Test: String, Codable, Sendable, CaseIterable {
        case empty
        case notEmpty
        case equals
        case contains
        /// Regulärer Ausdruck (Treffer irgendwo im Wert).
        case matches
    }

    public var field: String
    public var test: Test
    public var value: String?
    /// Für `equals`, `contains` und `matches`: Groß-/Kleinschreibung ignorieren.
    public var ignoreCase: Bool?

    enum CodingKeys: String, CodingKey {
        case field
        case test = "is"
        case value
        case ignoreCase
    }

    public init(field: String, test: Test, value: String? = nil, ignoreCase: Bool? = nil) {
        self.field = TagRule.canonicalField(field)
        self.test = test
        self.value = value
        self.ignoreCase = ignoreCase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let testName = try container.decode(String.self, forKey: .test)
        guard let test = Test(rawValue: testName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .test, in: container,
                debugDescription: "unknown condition \"\(testName)\" (expected one of "
                    + Test.allCases.map(\.rawValue).joined(separator: ", ") + ")")
        }
        self.init(field: try container.decode(String.self, forKey: .field),
                  test: test,
                  value: try container.decodeIfPresent(String.self, forKey: .value),
                  ignoreCase: try container.decodeIfPresent(Bool.self, forKey: .ignoreCase))
    }

    /// Trifft die Bedingung auf diese Felder zu?
    public func matches(_ fields: [String: String]) -> Bool {
        let current = fields[field] ?? ""
        let caseInsensitive = ignoreCase == true
        switch test {
        case .empty:
            return current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .notEmpty:
            return !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .equals:
            let expected = value ?? ""
            return caseInsensitive
                ? current.compare(expected, options: .caseInsensitive) == .orderedSame
                : current == expected
        case .contains:
            let needle = value ?? ""
            guard !needle.isEmpty else { return true }
            return current.range(of: needle, options: caseInsensitive ? [.caseInsensitive] : []) != nil
        case .matches:
            guard let pattern = value,
                  let regex = try? NSRegularExpression(
                      pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            else { return false }
            let range = NSRange(current.startIndex..., in: current)
            return regex.firstMatch(in: current, range: range) != nil
        }
    }
}

/// Fehler beim Lesen oder Prüfen einer Regeldatei. Texte englisch
/// (CLI-Konvention); die App übersetzt die Kontextzeile.
public enum TagRulesError: Error, LocalizedError, Sendable, Equatable {
    /// Kein gültiges JSON oder falsche Struktur; `line` wenn bekannt.
    case invalidJSON(line: Int?, reason: String)
    case unsupportedVersion(Int)
    /// Eine Regel ist unvollständig oder hat einen unbekannten Wert.
    /// `index` zählt ab 0, die Meldung nennt die Nummer ab 1.
    case invalidRule(index: Int, line: Int?, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let line, let reason):
            return "Invalid rules file\(Self.lineSuffix(line)): \(reason)"
        case .unsupportedVersion(let version):
            return "Unsupported rules file version \(version) "
                + "(this version understands \(TagRuleDocument.currentVersion))"
        case .invalidRule(let index, let line, let reason):
            return "Rule \(index + 1)\(Self.lineSuffix(line)): \(reason)"
        }
    }

    private static func lineSuffix(_ line: Int?) -> String {
        line.map { " (line \($0))" } ?? ""
    }
}

// MARK: - Laden und Speichern

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
        try encode(document).write(to: url, options: .atomic)
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

// MARK: - Engine

/// Eingabe für die Engine: eine Datei mit ihren Feldern.
public struct TagRuleInput: Sendable, Equatable {
    public var url: URL
    public var kind: MediaFormats.Kind
    /// Flaches Feld-Wörterbuch (siehe `PatternFields.fields(from:)`).
    public var values: [String: [String]]
    public var fields: [String: String] { values.mapValues { $0.first ?? "" } }

    public init(url: URL, kind: MediaFormats.Kind, fields: [String: String]) {
        self.url = url
        self.kind = kind
        self.values = fields.mapValues { [$0] }
    }
    public init(url: URL, kind: MediaFormats.Kind, values: [String: [String]]) {
        self.url = url
        self.kind = kind
        self.values = values
    }

}

/// Eine geplante Feldänderung: alt → neu. `new` leer heißt „Feld löschen".
public struct TagFieldChange: Codable, Sendable, Equatable, Hashable {
    public var field: String
    public var old: String
    public var new: String
    // Optionale Ergänzung zum bisherigen JSON-Vertrag; Skalare bleiben erhalten.
    public var oldValues: [String]?
    public var newValues: [String]?
    public var allOldValues: [String] { oldValues ?? (old.isEmpty ? [] : [old]) }
    public var allNewValues: [String] { newValues ?? (new.isEmpty ? [] : [new]) }
    public var oldDisplay: String { Self.display(allOldValues) }
    public var newDisplay: String { Self.display(allNewValues) }
    private static func display(_ values: [String]) -> String {
        guard values.count > 1 || values == [""] else { return values.first ?? "" }
        return String(data: try! JSONEncoder().encode(values), encoding: .utf8)!
    }

    public init(field: String, old: String, new: String) {
        self.field = field
        self.old = old
        self.new = new
    }
    public init(field: String, oldValues: [String], newValues: [String]) {
        self.init(field: field, old: oldValues.first ?? "", new: newValues.first ?? "")
        self.oldValues = oldValues.count > 1 || oldValues == [""] ? oldValues : nil
        self.newValues = newValues.count > 1 || newValues == [""] ? newValues : nil
    }

}

/// Änderungsplan einer Datei. Ohne `changes` ist die Datei unverändert.
public struct TagRulePlan: Sendable, Equatable {
    public var url: URL
    public var kind: MediaFormats.Kind
    public var changes: [TagFieldChange]

    public init(url: URL, kind: MediaFormats.Kind, changes: [TagFieldChange]) {
        self.url = url
        self.kind = kind
        self.changes = changes
    }

    /// Die neuen Werte als Wörterbuch — die Form, die `PatternFields.apply`
    /// und die Schreibwege erwarten.
    public var newValues: [String: String] {
        Dictionary(uniqueKeysWithValues: changes.map { ($0.field, $0.new) })
    }
}

/// Wendet Regeln auf Feld-Wörterbücher an. Reine Funktion: kein Dateizugriff.
public enum TagRuleEngine {

    /// Führt alle Regeln in Reihenfolge aus und liefert je Datei die
    /// Änderungen gegenüber dem Ausgangszustand (unveränderte Felder fehlen —
    /// damit erkennen CLI und App No-ops, ohne die Datei anzufassen).
    ///
    /// Die Datei-Reihenfolge der Eingabe ist auch die des Ergebnisses. Die
    /// Aktion `number` betrachtet alle Dateien gemeinsam (Sortierung).
    public static func plan(_ document: TagRuleDocument, inputs: [TagRuleInput]) throws -> [TagRulePlan] {
        try document.validate()
        var working = inputs.map(\.values)
        for (ruleIndex, rule) in document.rules.enumerated() {
            // Betroffene Dateien: Medienart und Bedingung auf dem AKTUELLEN
            // Stand — eine frühere Regel kann die Bedingung erst erfüllen.
            let affected = inputs.indices.filter { index in
                applies(rule, to: inputs[index], fields: working[index].mapValues { $0.first ?? "" })
            }
            if rule.action == .number {
                // Der gesamte Bereich muss darstellbar sein, bevor die erste
                // Nummer entsteht. Ein einzelnes Int.max bleibt zulässig.
                let (_, overflow) = (rule.start ?? 1).addingReportingOverflow(max(0, affected.count - 1))
                guard !overflow else {
                    throw TagRulesError.invalidRule(index: ruleIndex, line: nil,
                        reason: "numbering exceeds the supported integer range")
                }
                var flat = working.map { $0.mapValues { $0.first ?? "" } }
                number(rule, inputs: inputs, indices: affected, fields: &flat)
                for index in affected { working[index][rule.field] = [flat[index][rule.field] ?? ""] }
                continue
            }
            for index in affected {
                try applyValues(rule, to: &working[index])
            }
        }
        return inputs.indices.map { index in
            let before = inputs[index].values
            let after = working[index]
            let keys = Set(before.keys).union(after.keys).sorted()
            let changes = keys.compactMap { key -> TagFieldChange? in
                let old = before[key] ?? []
                let new = after[key] ?? []
                return old == new ? nil : TagFieldChange(field: key, oldValues: old, newValues: new)
            }
            return TagRulePlan(url: inputs[index].url, kind: inputs[index].kind, changes: changes)
        }
    }

    /// Bereinigung arbeitet pro Wert; explizites Setzen ersetzt die Liste.
    private static func applyValues(_ rule: TagRule, to values: inout [String: [String]]) throws {
        switch rule.action {
        case .trim, .case, .replace:
            let keys = rule.field == "*" ? values.keys.sorted() : [rule.field]
            for key in keys {
                guard let current = values[key] else { continue }
                values[key] = try current.map { value in
                    var single = [key: value]
                    try apply(rule, to: &single)
                    return single[key] ?? ""
                }
            }
        case .copy:
            let source = values[rule.from ?? ""] ?? []
            let target = values[rule.field] ?? []
            if rule.onlyIfEmpty == true,
               target.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { return }
            guard source.contains(where: { !$0.isEmpty }) else { return }
            values[rule.field] = source
        case .set:
            let value = TagRuleText.expandPlaceholders(rule.value ?? "", fields: values.mapValues { $0.first ?? "" })
            values[rule.field] = value.isEmpty ? nil : [value]
        case .remove: values[rule.field] = nil
        case .number: break
        }
    }

    /// Bequeme Variante für eine einzelne Feldmenge (Tests, Vorschau).
    public static func apply(_ document: TagRuleDocument, to fields: [String: String],
                             kind: MediaFormats.Kind = .audio) throws -> [String: String] {
        let input = TagRuleInput(url: URL(fileURLWithPath: "/dev/null"), kind: kind, fields: fields)
        var result = fields
        for change in try plan(document, inputs: [input])[0].changes {
            if change.new.isEmpty { result[change.field] = nil } else { result[change.field] = change.new }
        }
        return result
    }

    private static func applies(_ rule: TagRule, to input: TagRuleInput, fields: [String: String]) -> Bool {
        if let kinds = rule.kinds, !kinds.contains(input.kind) { return false }
        if let when = rule.when, !when.matches(fields) { return false }
        return true
    }

    /// Alle Felder, die eine `*`-Regel bearbeitet: die vorhandenen mit Wert.
    private static func targetFields(_ rule: TagRule, in fields: [String: String]) -> [String] {
        rule.field == "*" ? fields.keys.sorted() : [rule.field]
    }

    /// Eine Regel (außer `number`) auf ein Feld-Wörterbuch anwenden.
    static func apply(_ rule: TagRule, to fields: inout [String: String]) throws {
        switch rule.action {
        case .set:
            fields[rule.field] = TagRuleText.expandPlaceholders(rule.value ?? "", fields: fields)
        case .copy:
            let source = fields[rule.from ?? ""] ?? ""
            let target = fields[rule.field] ?? ""
            if rule.onlyIfEmpty == true, !target.trimmingCharacters(in: .whitespaces).isEmpty { return }
            // Eine leere Quelle lässt das Ziel in Ruhe — wie `tagx set -c`.
            guard !source.isEmpty else { return }
            fields[rule.field] = source
        case .replace:
            for key in targetFields(rule, in: fields) {
                guard let current = fields[key], !current.isEmpty else { continue }
                fields[key] = try TagRuleText.replace(
                    in: current, search: rule.search ?? "", replacement: rule.replacement ?? "",
                    regex: rule.regex == true, ignoreCase: rule.ignoreCase == true)
            }
        case .case:
            for key in targetFields(rule, in: fields) {
                guard let current = fields[key], !current.isEmpty else { continue }
                fields[key] = TagRuleText.changeCase(
                    current, mode: rule.mode ?? .title,
                    smallWords: rule.smallWords ?? TagRule.defaultSmallWords)
            }
        case .trim:
            for key in targetFields(rule, in: fields) {
                guard let current = fields[key], !current.isEmpty else { continue }
                fields[key] = TagRuleText.trim(current)
            }
        case .remove:
            fields[rule.field] = ""
        case .number:
            break // läuft über alle Dateien, siehe number(_:...)
        }
    }

    /// Tracknummern fortlaufend vergeben: die betroffenen Dateien in
    /// Sortierreihenfolge, ab `start`, optional als "n/gesamt".
    private static func number(_ rule: TagRule, inputs: [TagRuleInput], indices: [Int],
                               fields: inout [[String: String]]) {
        let sortKey = rule.sortBy ?? "filename"
        let ordered = indices.sorted { lhs, rhs in
            compareForNumbering(inputs[lhs], fields[lhs], inputs[rhs], fields[rhs], sortKey: sortKey)
        }
        let start = rule.start ?? 1
        let total = ordered.count
        for (offset, index) in ordered.enumerated() {
            var text = String(start + offset)
            if let width = rule.width, text.count < width {
                text = String(repeating: "0", count: width - text.count) + text
            }
            if rule.total == true { text += "/\(total)" }
            fields[index][rule.field] = text
        }
    }

    /// Sortierung für `number`: Dateiname natürlich ("2" vor "10"), ein
    /// Feld zahlenbewusst ("3/12" → 3), Gleichstand nach Dateiname.
    private static func compareForNumbering(_ a: TagRuleInput, _ aFields: [String: String],
                                            _ b: TagRuleInput, _ bFields: [String: String],
                                            sortKey: String) -> Bool {
        let byName = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        guard sortKey != "filename" else { return byName == .orderedAscending }
        let left = aFields[sortKey] ?? ""
        let right = bFields[sortKey] ?? ""
        if let l = leadingInt(left), let r = leadingInt(right), l != r { return l < r }
        let byField = left.localizedStandardCompare(right)
        if byField != .orderedSame { return byField == .orderedAscending }
        return byName == .orderedAscending
    }

    /// "3/12" → 3, " 07" → 7, "abc" → nil.
    private static func leadingInt(_ value: String) -> Int? {
        let head = value.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return head.isEmpty ? nil : Int(head)
    }
}

// MARK: - Textwerkzeuge

/// Die Textoperationen der Regeln, als reine Funktionen einzeln testbar.
public enum TagRuleText {

    /// Ersetzt `%{feld}` (und `%{feld:breite}`, `%%`) durch Feldwerte —
    /// gleiche Kurznamen wie bei Dateinamen-Mustern, aber ohne deren
    /// Dateinamen-Entschärfung: In einem Tag darf "AC/DC" stehen bleiben.
    public static func expandPlaceholders(_ template: String, fields: [String: String]) -> String {
        var result = ""
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            result += rest[..<percent]
            let afterPercent = rest.index(after: percent)
            guard afterPercent < rest.endIndex else {
                result += "%"
                rest = rest[rest.endIndex...]
                break
            }
            if rest[afterPercent] == "%" {
                result += "%"
                rest = rest[rest.index(after: afterPercent)...]
                continue
            }
            guard rest[afterPercent] == "{",
                  let close = rest[afterPercent...].firstIndex(of: "}") else {
                // "%x" oder unvollständig: wörtlich lassen.
                result += "%"
                rest = rest[afterPercent...]
                continue
            }
            let inner = rest[rest.index(after: afterPercent)..<close]
            let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let alias = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let width = parts.count == 2 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let placeholder = FilenamePattern.Placeholder(
                key: FilenamePattern.canonicalKey(for: alias), alias: alias.lowercased(), width: width)
            result += FilenamePattern.formatValue(fields[placeholder.key] ?? "", for: placeholder)
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    /// Suchen/Ersetzen — wörtlich oder als regulärer Ausdruck mit Gruppen
    /// (`$1`). Ein ungültiger Ausdruck wirft `invalidRule` (ohne Nummer).
    public static func replace(in text: String, search: String, replacement: String,
                               regex: Bool, ignoreCase: Bool) throws -> String {
        guard !search.isEmpty else { return text }
        if regex {
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(
                    pattern: search, options: ignoreCase ? [.caseInsensitive] : [])
            } catch {
                throw TagRulesError.invalidRule(
                    index: 0, line: nil, reason: "\"search\" is not a valid regular expression: \(search)")
            }
            let range = NSRange(text.startIndex..., in: text)
            return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        var options: String.CompareOptions = [.literal]
        if ignoreCase { options.insert(.caseInsensitive) }
        return text.replacingOccurrences(of: search, with: replacement, options: options)
    }

    /// Leerzeichen, Zeilenumbrüche und Steuerzeichen am Rand entfernen;
    /// mehrere Leerzeichen/Tabs hintereinander zu einem Leerzeichen. Zeilen-
    /// umbrüche IM Text bleiben (Lyrics, Beschreibungen).
    public static func trim(_ text: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        var result = text.trimmingCharacters(in: edges)
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return result
    }

    public static func changeCase(_ text: String, mode: TagRule.CaseMode, smallWords: [String]) -> String {
        switch mode {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return titleCase(text, smallWords: Set(smallWords.map { $0.lowercased() }))
        case .sentence: return sentenceCase(text)
        }
    }

    /// Zeichen, nach denen innerhalb eines Wortes wieder groß geschrieben
    /// wird: "Rock-'n'-Roll", "AC/DC", "(Live)", "„Zitat".
    private static let subwordStarters: Set<Character> = [
        "-", "/", "(", "[", "{", "\"", "„", "“", "‘", "«", "»",
    ]

    /// Satzzeichen, nach denen ein kleines Wort trotzdem groß beginnt
    /// ("Titel: Der Film", "Was? Die Antwort").
    private static let phraseEnders: Set<Character> = [":", ";", "?", "!", ".", "–", "—", "-", "("]

    /// Titel-Schreibweise: jedes Wort groß, der Rest klein; kleine Wörter
    /// klein — außer am Anfang, am Ende oder nach einem Satzzeichen.
    /// Getrennt wird an Leerraum; Bindestrich-Teile zählen als eigene Wörter
    /// ("Rock-and-Roll"). Umlaute und andere Unicode-Buchstaben werden wie
    /// alle Buchstaben behandelt ("ärger" → "Ärger"). Bekannte Grenze:
    /// Abkürzungen in Großbuchstaben ("DJ", "USA") werden zu "Dj"/"Usa".
    static func titleCase(_ text: String, smallWords: Set<String>) -> String {
        // Wörter und Leerraum abwechselnd, damit der Leerraum unverändert
        // zurückkommt.
        var tokens: [(text: String, isWord: Bool)] = []
        var current = ""
        var currentIsWord = false
        for character in text {
            let isWord = !character.isWhitespace
            if !current.isEmpty, isWord != currentIsWord {
                tokens.append((current, currentIsWord))
                current = ""
            }
            current.append(character)
            currentIsWord = isWord
        }
        if !current.isEmpty { tokens.append((current, currentIsWord)) }

        let lastWordIndex = tokens.lastIndex(where: \.isWord)
        var result = ""
        var previousWord: String?
        for (index, token) in tokens.enumerated() {
            guard token.isWord else {
                result += token.text
                continue
            }
            // Am Anfang, am Ende und nach einem Satzzeichen ("Titel: Der
            // Film") beginnt auch ein kleines Wort groß.
            let afterPhraseEnd = previousWord?.last.map(phraseEnders.contains) ?? false
            let forceCapital = previousWord == nil || index == lastWordIndex || afterPhraseEnd
            result += titleCaseWord(token.text, smallWords: smallWords, forceCapital: forceCapital)
            previousWord = token.text
        }
        return result
    }

    /// Ein Leerraum-freies Wort in Titel-Schreibweise, inklusive Teilwörtern
    /// nach Bindestrich/Schrägstrich/Klammer.
    private static func titleCaseWord(_ word: String, smallWords: Set<String>, forceCapital: Bool) -> String {
        // In Teilwörter zerlegen: Grenze ist jedes Zeichen aus subwordStarters.
        var parts: [String] = []
        var current = ""
        for character in word {
            if subwordStarters.contains(character) {
                parts.append(current)
                parts.append(String(character))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)

        var result = ""
        var isFirstPart = true
        for part in parts {
            if part.count == 1, let only = part.first, subwordStarters.contains(only) {
                result += part
                continue
            }
            guard !part.isEmpty else { continue }
            let lowered = part.lowercased()
            let core = lowered.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let keepSmall = smallWords.contains(core) && !(forceCapital && isFirstPart)
            result += keepSmall ? lowered : capitalizeFirstLetter(lowered)
            isFirstPart = false
        }
        return result
    }

    /// Ersten Buchstaben groß (Zeichen davor wie Klammern oder Anführungs-
    /// zeichen bleiben), Rest unverändert.
    private static func capitalizeFirstLetter(_ word: String) -> String {
        guard let index = word.firstIndex(where: \.isLetter) else { return word }
        return String(word[..<index]) + word[index].uppercased() + word[word.index(after: index)...]
    }

    /// Satz-Schreibweise: alles klein, dann der erste Buchstabe des Textes
    /// und jeder Buchstabe nach ". ", "! " oder "? " groß.
    static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        var previous: Character?
        for character in text.lowercased() {
            if capitalizeNext, character.isLetter {
                result += character.uppercased()
                capitalizeNext = false
            } else {
                result.append(character)
            }
            if character.isWhitespace, let previous, ".!?".contains(previous) {
                capitalizeNext = true
            }
            previous = character
        }
        return result
    }
}

// MARK: - Vorlagen

/// Mitgelieferte Regelsätze, die App und Doku als Startpunkt anbieten. Die
/// Anzeigenamen liegen in der App (lokalisiert); hier nur Kennung und Inhalt.
public enum TagRuleTemplate: String, CaseIterable, Sendable {
    case titleCase
    case trimWhitespace
    case albumArtistFromArtist
    case renumberTracks

    public var document: TagRuleDocument {
        switch self {
        case .titleCase:
            return TagRuleDocument(rules: [
                TagRule(action: .case, field: "TITLE", mode: .title),
                TagRule(action: .case, field: "ALBUM", mode: .title),
            ])
        case .trimWhitespace:
            return TagRuleDocument(rules: [TagRule(action: .trim, field: "*")])
        case .albumArtistFromArtist:
            return TagRuleDocument(rules: [
                TagRule(action: .copy, field: "ALBUMARTIST", from: "ARTIST", onlyIfEmpty: true),
            ])
        case .renumberTracks:
            return TagRuleDocument(rules: [
                TagRule(action: .number, field: "TRACKNUMBER", sortBy: "filename", start: 1, total: true),
            ])
        }
    }
}

/// Audio-Regelfelder sind unabhängig von den einwertigen Dateinamenmustern.
public enum TagRuleFields {
    public static func values(from properties: [TagProperty]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for property in properties { result[property.key, default: []].append(property.value) }
        return result
    }

    public static func apply(_ values: [String: [String]], to properties: inout [TagProperty]) {
        for key in values.keys.sorted() {
            properties.removeAll { $0.key == key }
            properties += (values[key] ?? []).map { TagProperty(key: key, value: $0) }
        }
    }
}

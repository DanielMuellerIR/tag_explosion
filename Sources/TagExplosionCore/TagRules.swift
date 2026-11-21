import Foundation

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
        _ = try validatedExpressions()
    }

    func validatedExpressions() throws -> [TagRuleExpressions] {
        guard version == Self.currentVersion else {
            throw TagRulesError.unsupportedVersion(version)
        }
        return try rules.enumerated().map { index, rule in
            do {
                return try rule.validatedExpressions()
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
    /// `replace`: Groß-/Kleinschreibung ignorieren (Voreinstellung: nein).
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
        _ = try validatedExpressions()
    }

    func validatedExpressions() throws -> TagRuleExpressions {
        func fail(_ reason: String) -> TagRulesError {
            .invalidRule(index: 0, line: nil, reason: reason)
        }
        if field.isEmpty { throw fail("\"field\" is required for action \"\(action.rawValue)\"") }
        let wildcardAllowed: Set<Action> = [.replace, .case, .trim]
        if field == "*", !wildcardAllowed.contains(action) {
            throw fail("field \"*\" is only allowed for replace, case and trim")
        }
        var replacementExpression: NSRegularExpression?
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
            if regex == true {
                replacementExpression = try Self.compileRegex(search, label: "search", ignoreCase: ignoreCase == true)
            }
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
        var conditionExpression: NSRegularExpression?
        if let when {
            if when.field.isEmpty { throw fail("\"when.field\" is required") }
            switch when.test {
            case .matches:
                guard let pattern = when.value else { throw fail("\"when.value\" is required for \"matches\"") }
                conditionExpression = try Self.compileRegex(pattern, label: "when.value", ignoreCase: when.ignoreCase == true)
            case .equals, .contains:
                guard when.value != nil else {
                    throw fail("\"when.value\" is required for \"\(when.test.rawValue)\"")
                }
            case .empty, .notEmpty:
                break
            }
        }
        return TagRuleExpressions(replacement: replacementExpression, condition: conditionExpression)
    }

    static func compileRegex(_ pattern: String, label: String, ignoreCase: Bool) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw TagRulesError.invalidRule(
                index: 0, line: nil, reason: "\"\(label)\" is not a valid regular expression: \(pattern)")
        }
    }
}

struct TagRuleExpressions {
    let replacement: NSRegularExpression?
    let condition: NSRegularExpression?
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
        let expression: NSRegularExpression?
        if test == .matches, let value {
            expression = try? TagRule.compileRegex(value, label: "when.value", ignoreCase: ignoreCase == true)
        } else {
            expression = nil
        }
        return matches(firstValue: fields[field] ?? "", expression: expression)
    }

    func matches(firstValue current: String, expression: NSRegularExpression?) -> Bool {
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
            guard let expression else { return false }
            let range = NSRange(current.startIndex..., in: current)
            return expression.firstMatch(in: current, range: range) != nil
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

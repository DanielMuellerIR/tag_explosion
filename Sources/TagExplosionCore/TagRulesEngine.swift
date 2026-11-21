import Foundation

/// Eingabe für die Engine: eine Datei mit ihren Feldern.
public struct TagRuleInput: Sendable, Equatable {
    public var url: URL
    public var kind: MediaFormats.Kind
    /// Feldwerte je Schlüssel; Bedingungen und Platzhalter lesen den ersten Wert.
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
        let expressions = try document.validatedExpressions()
        var working = inputs.map(\.values)
        for (ruleIndex, (rule, expressions)) in zip(document.rules, expressions).enumerated() {
            // Betroffene Dateien: Medienart und Bedingung auf dem AKTUELLEN
            // Stand — eine frühere Regel kann die Bedingung erst erfüllen.
            let affected = inputs.indices.filter { index in
                if let kinds = rule.kinds, !kinds.contains(inputs[index].kind) { return false }
                guard let condition = rule.when else { return true }
                return condition.matches(firstValue: working[index][condition.field]?.first ?? "",
                                         expression: expressions.condition)
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
            let transform = textTransform(for: rule, expression: expressions.replacement)
            for index in affected {
                applyValues(rule, to: &working[index], transform: transform)
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
    private static func applyValues(_ rule: TagRule, to values: inout [String: [String]],
                                    transform: (String) -> String) {
        switch rule.action {
        case .trim, .case, .replace:
            let keys = rule.field == "*" ? values.keys.sorted() : [rule.field]
            for key in keys {
                guard let current = values[key] else { continue }
                values[key] = current.map { $0.isEmpty ? $0 : transform($0) }
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

    /// Die bei der Vorprüfung kompilierte Regex und die Wortmenge werden
    /// von der Textfunktion für alle betroffenen Feldwerte wiederverwendet.
    private static func textTransform(for rule: TagRule, expression: NSRegularExpression?) -> (String) -> String {
        switch rule.action {
        case .trim: return TagRuleText.trim
        case .replace:
            return TagRuleText.replacement(search: rule.search ?? "", replacement: rule.replacement ?? "",
                                           ignoreCase: rule.ignoreCase == true, expression: expression)
        case .case:
            let mode = rule.mode ?? .title
            if mode == .title {
                let words = Set((rule.smallWords ?? TagRule.defaultSmallWords).map { $0.lowercased() })
                return { TagRuleText.titleCase($0, smallWords: words) }
            }
            return { TagRuleText.changeCase($0, mode: mode, smallWords: []) }
        default: return { $0 }
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

/// Audio-Regelfelder sind unabhängig von den einwertigen Dateinamenmustern.
public enum TagRuleFields {
    /// Bestehender Regel-Adapter; die allgemeine Gruppierung liegt im Modell.
    public static func values(from properties: [TagProperty]) -> [String: [String]] {
        TagProperty.valuesByKey(properties)
    }

    public static func apply(_ values: [String: [String]], to properties: inout [TagProperty]) {
        for key in values.keys.sorted() {
            properties.removeAll { $0.key == key }
            properties += (values[key] ?? []).map { TagProperty(key: key, value: $0) }
        }
    }
}

import Foundation

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
        let expression = regex ? try TagRule.compileRegex(search, label: "search", ignoreCase: ignoreCase) : nil
        return Self.replacement(search: search, replacement: replacement,
                                ignoreCase: ignoreCase, expression: expression)(text)
    }

    /// Eine vorbereitete Ersetzung kann alle Werte eines Stapels bearbeiten.
    static func replacement(search: String, replacement: String,
                            ignoreCase: Bool, expression: NSRegularExpression?) -> (String) -> String {
        if let expression {
            return { text in
                let range = NSRange(text.startIndex..., in: text)
                return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
            }
        }
        var options: String.CompareOptions = [.literal]
        if ignoreCase { options.insert(.caseInsensitive) }
        return { $0.replacingOccurrences(of: search, with: replacement, options: options) }
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

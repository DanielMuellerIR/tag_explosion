// Kapitel-Austauschformate und Plausibilitätsprüfung.
//
// Zwei Formate, beide von App und CLI genutzt:
//  - JSON: Array aus `{"title": "…", "start": ms, "end": ms}` (oder ein Objekt
//    mit dem Schlüssel `chapters`, wie es `tagx chapters show --json` ausgibt).
//    `end` darf fehlen und wird dann aus dem nächsten Kapitelbeginn ergänzt.
//  - Text: eine Zeile pro Kapitel, `HH:MM:SS.mmm Titel` — das Format gängiger
//    Kapitel-Werkzeuge (mp4chaps, Audiobook-Builder, Podcast-Editoren).
//    Zeilen, die mit `#` beginnen, sind Kommentare.
import Foundation

public enum ChapterList {

    // MARK: - Prüfung

    /// Lehnt Kapitellisten ab, die kein Format sinnvoll speichern kann:
    /// negative Zeiten, Ende vor Beginn, unsortierte Reihenfolge und
    /// Überlappung (ein Kapitel beginnt, bevor das vorige endet). Ein
    /// Beginn genau am Ende des Vorgängers ist die Regel und erlaubt.
    public static func validate(_ chapters: [Chapter]) throws {
        var previousStart = 0
        var previousEnd = 0
        for (index, chapter) in chapters.enumerated() {
            let number = index + 1
            if chapter.startMilliseconds < 0 || chapter.endMilliseconds < 0 {
                throw TagError.invalidChapters(reason: "chapter \(number) has a negative time")
            }
            if chapter.endMilliseconds < chapter.startMilliseconds {
                throw TagError.invalidChapters(reason: "chapter \(number) ends before it starts")
            }
            if chapter.startMilliseconds < previousStart {
                throw TagError.invalidChapters(reason: "chapter \(number) starts before chapter \(number - 1)")
            }
            if chapter.startMilliseconds < previousEnd {
                throw TagError.invalidChapters(
                    reason: "chapter \(number) starts before chapter \(number - 1) ends (overlap)")
            }
            previousStart = chapter.startMilliseconds
            previousEnd = chapter.endMilliseconds
        }
    }

    // MARK: - Zeitstempel

    /// `HH:MM:SS.mmm` — immer mit zwei Stunden-Stellen und drei Millisekunden-
    /// Stellen, damit die Ausgabe zeilenweise sortierbar bleibt.
    public static func formatTimestamp(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds)
        let ms = total % 1000
        let seconds = (total / 1000) % 60
        let minutes = (total / 60_000) % 60
        let hours = total / 3_600_000
        return String(format: "%02lld:%02d:%02d.%03d", Int64(hours), minutes, seconds, ms)
    }

    /// Liest `HH:MM:SS.mmm`, aber auch verkürzte Formen (`MM:SS`, `SS.mmm`,
    /// `1:02:03`), Komma als Dezimaltrenner und beliebig viele Nachkommastellen
    /// (über drei werden abgeschnitten). nil, wenn der Text keine Zeit ist.
    public static func parseTimestamp(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count) else { return nil }

        // Nur der letzte Teil (Sekunden) darf Nachkommastellen haben.
        var fractionMs = 0
        var secondsText = parts[parts.count - 1]
        if let dot = secondsText.firstIndex(of: ".") {
            let fraction = String(secondsText[secondsText.index(after: dot)...])
            secondsText = String(secondsText[..<dot])
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return nil }
            let digits = String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            guard let value = Int(digits) else { return nil }
            fractionMs = value
        }
        var numbers: [Int] = []
        for part in parts.dropLast() + [secondsText] {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        // Stunden/Minuten/Sekunden schrittweise zusammenführen. Auch eine
        // einzeln gültige Ganzzahl kann beim Umrechnen zu groß werden.
        var totalSeconds = 0
        for number in numbers {
            let product = totalSeconds.multipliedReportingOverflow(by: 60)
            let sum = product.partialValue.addingReportingOverflow(number)
            guard !product.overflow, !sum.overflow else { return nil }
            totalSeconds = sum.partialValue
        }
        let product = totalSeconds.multipliedReportingOverflow(by: 1000)
        let sum = product.partialValue.addingReportingOverflow(fractionMs)
        guard !product.overflow, !sum.overflow else { return nil }
        return sum.partialValue
    }

    // MARK: - Fehlende Enden ergänzen

    /// Kapitel ohne bekanntes Ende (nil) bekommen den nächsten Kapitelbeginn;
    /// das letzte die Spielzeit `totalLength` — oder, wenn die fehlt bzw. vor
    /// dem Beginn liegt, den eigenen Beginn.
    public static func fillMissingEnds(_ entries: [(title: String, start: Int, end: Int?)],
                                       totalLength: Int?) -> [Chapter] {
        entries.enumerated().map { index, entry in
            let end: Int
            if let known = entry.end {
                end = known
            } else if index + 1 < entries.count {
                end = max(entry.start, entries[index + 1].start)
            } else {
                end = max(entry.start, totalLength ?? 0)
            }
            return Chapter(title: entry.title, startMilliseconds: entry.start, endMilliseconds: end)
        }
    }

    // MARK: - Textformat

    /// Eine Zeile pro Kapitel: `HH:MM:SS.mmm Titel`.
    public static func renderText(_ chapters: [Chapter]) -> String {
        chapters.map { "\(formatTimestamp($0.startMilliseconds)) \($0.title)" }.joined(separator: "\n")
            + (chapters.isEmpty ? "" : "\n")
    }

    /// Liest das Textformat. Leere und `#`-Zeilen werden übersprungen; ein
    /// fehlender Titel ist erlaubt. Enden ergeben sich aus dem jeweils
    /// nächsten Beginn (siehe `fillMissingEnds`).
    public static func parseText(_ text: String, totalLength: Int?) throws -> [Chapter] {
        var entries: [(title: String, start: Int, end: Int?)] = []
        for (lineIndex, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let timeText = line.prefix { !$0.isWhitespace }
            guard let start = parseTimestamp(String(timeText)) else {
                throw TagError.invalidChapters(
                    reason: "line \(lineIndex + 1) does not start with a time (HH:MM:SS.mmm): \(line)")
            }
            let title = line.dropFirst(timeText.count).trimmingCharacters(in: .whitespaces)
            entries.append((title: title, start: start, end: nil))
        }
        let chapters = fillMissingEnds(entries, totalLength: totalLength)
        try validate(chapters)
        return chapters
    }

    // MARK: - JSON

    /// Hübsches, sortiertes JSON-Array — Gegenstück zu `parseJSON`.
    public static func renderJSON(_ chapters: [Chapter]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(chapters)
    }

    /// Eintrag der JSON-Form; `end` und `title` sind optional.
    private struct LooseChapter: Decodable {
        var title: String?
        var start: Int
        var end: Int?
    }

    /// Umhüllung, wie `tagx chapters show --json` sie ausgibt.
    private struct Envelope: Decodable {
        var chapters: [LooseChapter]
    }

    /// Liest ein JSON-Array aus Kapiteln oder ein Objekt mit `chapters`.
    public static func parseJSON(_ data: Data, totalLength: Int?) throws -> [Chapter] {
        let decoder = JSONDecoder()
        let loose: [LooseChapter]
        if let array = try? decoder.decode([LooseChapter].self, from: data) {
            loose = array
        } else if let envelope = try? decoder.decode(Envelope.self, from: data) {
            loose = envelope.chapters
        } else {
            throw TagError.invalidChapters(
                reason: "expected a JSON array of {title, start, end} or an object with \"chapters\"")
        }
        let chapters = fillMissingEnds(
            loose.map { (title: $0.title ?? "", start: $0.start, end: $0.end) },
            totalLength: totalLength)
        try validate(chapters)
        return chapters
    }

    // MARK: - Datei

    /// Erkennt JSON am ersten sichtbaren Zeichen (`[` oder `{`), alles andere
    /// gilt als Textformat — die Endung ist damit egal.
    public static func load(from url: URL, totalLength: Int?) throws -> [Chapter] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TagError.invalidChapters(reason: "\(url.lastPathComponent) is not UTF-8 text")
        }
        let first = text.first { !$0.isWhitespace }
        if first == "[" || first == "{" {
            return try parseJSON(data, totalLength: totalLength)
        }
        return try parseText(text, totalLength: totalLength)
    }
}

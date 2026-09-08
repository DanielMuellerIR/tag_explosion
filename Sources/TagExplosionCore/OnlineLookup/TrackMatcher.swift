// Zuordnung lokale Datei ↔ Titel eines Kandidaten — reine Funktionen.
//
// Regel: Erst die Tracknummer (plus CD-Nummer, wenn beide Seiten eine haben).
// Bleibt eine Datei ohne Nummer oder ist die Nummer nicht eindeutig, zählt die
// Spieldauer (±3 s) zusammen mit der Ähnlichkeit des Titels. Jeder Titel des
// Kandidaten wird höchstens einer Datei zugeordnet.
import Foundation

/// Ergebnis der Zuordnung für eine Datei.
public struct LookupAssignment: Sendable, Equatable {
    public enum Reason: String, Sendable, Codable, Equatable {
        case trackNumber
        case durationAndTitle
        case titleOnly
        case none
    }

    public var fileURL: URL
    /// nil = keine passende Spur gefunden.
    public var track: LookupTrack?
    public var reason: Reason

    public init(fileURL: URL, track: LookupTrack?, reason: Reason) {
        self.fileURL = fileURL
        self.track = track
        self.reason = reason
    }
}

public enum TrackMatcher {
    /// Toleranz beim Dauervergleich.
    public static let durationToleranceMilliseconds = 3000
    /// Mindestähnlichkeit des Titels, wenn nur der Titel entscheidet.
    public static let titleOnlyThreshold = 0.75
    /// Mindestähnlichkeit, wenn die Dauer bereits passt.
    public static let titleWithDurationThreshold = 0.35

    /// Ordnet jeder Datei höchstens einen Titel zu (Reihenfolge wie `files`).
    public static func assign(files: [LookupFileInfo], tracks: [LookupTrack]) -> [LookupAssignment] {
        var remaining = tracks
        var result: [LookupAssignment?] = Array(repeating: nil, count: files.count)

        // Runde 1: Tracknummer. Nur wenn genau ein Titel dazu passt.
        for (index, file) in files.enumerated() {
            guard let number = file.trackNumber else { continue }
            let hits = remaining.indices.filter { i in
                remaining[i].number == number
                    && (file.discNumber == nil || remaining[i].discNumber == file.discNumber)
            }
            guard hits.count == 1 else { continue }
            result[index] = LookupAssignment(fileURL: file.url, track: remaining[hits[0]], reason: .trackNumber)
            remaining.remove(at: hits[0])
        }

        if result.allSatisfy({ $0 != nil }) { return result.map { $0! } }

        // Runde 2: Dauer ±3 s plus Titelähnlichkeit; sonst nur Titel.
        // Normalisierung und Zeichenlisten einmal je Titel statt je Dateipaar.
        var candidates = remaining.map { (track: $0, title: PreparedTitle($0.title)) }
        for (index, file) in files.enumerated() where result[index] == nil {
            let title = PreparedTitle(file.title)
            var best: (index: Int, score: Double, reason: LookupAssignment.Reason)?
            for (i, prepared) in candidates.enumerated() {
                let track = prepared.track
                let similarity = titleSimilarity(title, prepared.title)
                let durationMatches: Bool
                if let fileDuration = file.durationMilliseconds, let trackDuration = track.durationMilliseconds {
                    let (difference, overflow) = fileDuration.subtractingReportingOverflow(trackDuration)
                    durationMatches = !overflow && (-durationToleranceMilliseconds...durationToleranceMilliseconds).contains(difference)
                } else {
                    durationMatches = false
                }
                let candidate: (score: Double, reason: LookupAssignment.Reason)?
                if durationMatches, similarity >= titleWithDurationThreshold || file.title.isEmpty {
                    candidate = (similarity + 1.0, .durationAndTitle)
                } else if similarity >= titleOnlyThreshold {
                    candidate = (similarity, .titleOnly)
                } else {
                    candidate = nil
                }
                if let candidate, candidate.score > (best?.score ?? -1) {
                    best = (i, candidate.score, candidate.reason)
                }
            }
            if let best {
                result[index] = LookupAssignment(fileURL: file.url, track: candidates[best.index].track, reason: best.reason)
                candidates.remove(at: best.index)
            } else {
                result[index] = LookupAssignment(fileURL: file.url, track: nil, reason: .none)
            }
        }
        return result.map { $0! }
    }

    /// Ähnlichkeit zweier Titel 0…1 (1 = gleich) über die Levenshtein-Distanz
    /// auf normalisiertem Text (Kleinschreibung, ohne Akzente und Satzzeichen).
    ///
    /// Zusätze in Klammern („(Remastered 2009)", „[Live]") zählen als zweite
    /// Wertung mit Abschlag: „Nachtlied (Remaster)" passt so zu „Nachtlied",
    /// ein wörtlich gleicher Titel gewinnt aber weiterhin den Vergleich.
    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        titleSimilarity(PreparedTitle(a), PreparedTitle(b))
    }

    private struct PreparedTitle {
        let full: [Character]
        let stripped: [Character]

        init(_ text: String) {
            full = Array(normalized(text))
            stripped = Array(normalized(stripParentheticals(text)))
        }
    }

    private static func titleSimilarity(_ a: PreparedTitle, _ b: PreparedTitle) -> Double {
        let exact = ratio(a.full, b.full)
        if exact == 1 { return 1 }
        return max(exact, ratio(a.stripped, b.stripped) * 0.9)
    }

    private static func ratio(_ left: [Character], _ right: [Character]) -> Double {
        if left.isEmpty || right.isEmpty { return left == right ? 1 : 0 }
        if left == right { return 1 }
        let distance = levenshtein(left, right)
        let longest = max(left.count, right.count)
        return 1.0 - Double(distance) / Double(longest)
    }

    /// Entfernt Klammerausdrücke „( … )" und „[ … ]" samt Inhalt.
    static func stripParentheticals(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "(" || character == "[" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                out.append(character)
            }
        }
        return out
    }

    /// Kleinbuchstaben ohne Akzente; alles außer Buchstaben/Ziffern wird zu
    /// einem Leerzeichen, Mehrfach-Leerzeichen fallen zusammen.
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: nil)
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

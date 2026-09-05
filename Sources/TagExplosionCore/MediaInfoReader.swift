// Wrapper um das externe Programm `mediainfo` (BSD-2-lizenziert, wird nur
// aufgerufen, nicht gelinkt). Liefert die vollständige technische Sicht auf
// eine Mediendatei — alles, was TagLib nicht abdeckt.
import Foundation

/// Ein Track aus der MediaInfo-Ausgabe (General, Audio, Video, Image, Menu …)
/// als geordnete Key/Value-Liste — wir zeigen alles an, was mediainfo liefert.
public struct MediaInfoTrack: Sendable, Codable, Equatable {
    /// Track-Typ, z.B. "General", "Audio", "Video", "Image", "Menu".
    public var type: String
    /// Felder in Original-Reihenfolge von mediainfo.
    public var fields: [TagProperty]

    public init(type: String, fields: [TagProperty]) {
        self.type = type
        self.fields = fields
    }
}

/// Ergebnis eines MediaInfo-Laufs.
public struct MediaInfoReport: Sendable, Codable, Equatable {
    public var tracks: [MediaInfoTrack]
    /// Menschlich lesbare Textausgabe (`mediainfo <datei>`), fertig formatiert.
    public var text: String

    public init(tracks: [MediaInfoTrack], text: String) {
        self.tracks = tracks
        self.text = text
    }
}

/// Führt `mediainfo` aus und parst dessen JSON- und Textausgabe.
public enum MediaInfoReader {

    /// MediaInfo endete erfolgreich, lieferte aber keinen lesbaren
    /// JSON-Bericht. Ein leerer Erfolg würde Werkzeug- oder Formatfehler in
    /// App und CLI unsichtbar machen.
    enum ReportError: Error, LocalizedError, Sendable, Equatable {
        case invalidJSON

        var errorDescription: String? {
            "mediainfo returned an unreadable JSON report"
        }
    }

    /// Kandidaten-Pfade für das mediainfo-Binary (PATH zuerst, dann übliche Orte).
    public static let executableCandidates: [String] = [
        "mediainfo",
        "/opt/homebrew/bin/mediainfo",
        "/usr/local/bin/mediainfo",
        "/usr/bin/mediainfo",
    ]

    /// Findet das mediainfo-Binary oder wirft `toolNotFound`.
    public static func locateExecutable() throws -> String {
        try ExternalToolRunner.locateTool(candidates: executableCandidates, name: "mediainfo")
    }

    public static func toolArgument(for url: URL) -> String { ExternalToolRunner.toolArgument(for: url) }

    /// Liest den kompletten technischen Report einer Datei.
    public static func read(url: URL) throws -> MediaInfoReport {
        let exe = try locateExecutable()
        let path = toolArgument(for: url)
        let jsonData = try ExternalToolRunner.run(exe, ["--Output=JSON", path])
        let textData = try ExternalToolRunner.run(exe, [path])
        let tracks = try parseTracks(jsonData: jsonData)
        let text = decodeLossyPlainText(textData)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaInfoReport(tracks: tracks, text: text)
    }

    // MARK: - Intern

    /// mediainfo-JSON in Tracks zerlegen. Die Feld-Reihenfolge bleibt erhalten,
    /// deshalb ein kleiner eigener Parser statt JSONDecoder (der verliert Order).
    static func parseTracks(jsonData: Data) throws -> [MediaInfoTrack] {
        // mediainfo liefert gelegentlich kaputtes UTF-8 (rohe Latin1-Bytes aus
        // ID3v1/v2.3) — JSONSerialization lehnt das ab, daher lossy dekodieren
        // und wieder als sauberes UTF-8 einlesen.
        let jsonString = decodeLossyJSON(jsonData)
        guard let cleaned = jsonString.data(using: .utf8) else {
            throw ReportError.invalidJSON
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: cleaned)
        } catch {
            throw ReportError.invalidJSON
        }
        guard let root = decoded as? [String: Any],
              let media = root["media"] as? [String: Any],
              let rawTracks = media["track"] as? [[String: Any]]
        else { throw ReportError.invalidJSON }

        // JSONSerialization gibt Dictionaries ohne Quellreihenfolge zurück.
        // Der kleine Lexer unten ermittelt deshalb für jedes Track-Objekt sein
        // eigenes geordnetes Member-Verzeichnis; eine globale Textsuche würde
        // ab Track 2 wieder die Positionen des ersten Tracks finden.
        let orderedTracks = trackObjects(in: jsonString)
        var result: [MediaInfoTrack] = []
        for (index, raw) in rawTracks.enumerated() {
            let type = (raw["@type"] as? String) ?? "?"
            var fields: [TagProperty] = []
            let members = orderedTracks.indices.contains(index)
                ? objectMembers(in: orderedTracks[index])
                : nil
            var seen: Set<String> = []
            let sourceKeys = (members?.map(\.key) ?? []) + raw.keys.sorted()
            for key in sourceKeys where seen.insert(key).inserted {
                guard key != "@type", key != "@ref" else { continue }
                let value = raw[key]
                if let s = value as? String {
                    fields.append(TagProperty(key: key, value: s))
                } else if let n = value as? NSNumber {
                    fields.append(TagProperty(key: key, value: n.stringValue))
                } else if let dict = value as? [String: Any] {
                    // "extra"-Block: verschachtelte Zusatzfelder flach anhängen
                    let valueSlice = members?.first { $0.key == key }?.value
                    let nestedMembers = valueSlice.flatMap { objectMembers(in: $0) }
                    var seenNested: Set<String> = []
                    let nestedKeys = (nestedMembers?.map(\.key) ?? []) + dict.keys.sorted()
                    for subKey in nestedKeys where seenNested.insert(subKey).inserted {
                        guard let subValue = dict[subKey] else { continue }
                        fields.append(TagProperty(key: "\(key).\(subKey)", value: "\(subValue)"))
                    }
                }
            }
            result.append(MediaInfoTrack(type: type, fields: fields))
        }
        return result
    }

    /// Ein Objekt-Member mit seinem Wert als Ausschnitt desselben JSON-Texts.
    /// Der Ausschnitt erlaubt auch für verschachtelte `extra`-Objekte die
    /// ursprüngliche Reihenfolge zu ermitteln.
    private struct OrderedJSONMember {
        let key: String
        let value: Substring
    }

    /// Die unmittelbaren Objekte des standardisierten `media.track`-Arrays.
    private static func trackObjects(in json: String) -> [Substring] {
        guard let rootMembers = objectMembers(in: json[...]),
              let media = rootMembers.first(where: { $0.key == "media" }),
              let mediaMembers = objectMembers(in: media.value),
              let tracks = mediaMembers.first(where: { $0.key == "track" }),
              let elements = arrayElements(in: tracks.value)
        else { return [] }
        return elements.filter {
            let start = skipWhitespace(from: $0.startIndex, in: $0)
            return start < $0.endIndex && $0[start] == "{"
        }
    }

    /// Geordnete direkte Member eines JSON-Objekts. Strings und
    /// Verschachtelungen werden vollständig übersprungen, daher zählen
    /// gleichnamige Schlüssel in Unterobjekten nicht als Position des Elterns.
    private static func objectMembers(in source: Substring) -> [OrderedJSONMember]? {
        var index = skipWhitespace(from: source.startIndex, in: source)
        guard index < source.endIndex, source[index] == "{" else { return nil }
        index = source.index(after: index)
        var members: [OrderedJSONMember] = []

        while true {
            index = skipWhitespace(from: index, in: source)
            guard index < source.endIndex else { return nil }
            if source[index] == "}" { return members }
            guard let parsedKey = jsonString(at: index, in: source) else { return nil }
            index = skipWhitespace(from: parsedKey.end, in: source)
            guard index < source.endIndex, source[index] == ":" else { return nil }
            index = skipWhitespace(from: source.index(after: index), in: source)
            let valueStart = index
            guard let valueEnd = jsonValueEnd(from: valueStart, in: source) else { return nil }
            members.append(OrderedJSONMember(
                key: parsedKey.value,
                value: source[valueStart..<valueEnd]
            ))
            index = skipWhitespace(from: valueEnd, in: source)
            guard index < source.endIndex else { return nil }
            if source[index] == "," {
                index = source.index(after: index)
            } else if source[index] == "}" {
                return members
            } else {
                return nil
            }
        }
    }

    /// Direkte Werte eines JSON-Arrays als Quellausschnitte.
    private static func arrayElements(in source: Substring) -> [Substring]? {
        var index = skipWhitespace(from: source.startIndex, in: source)
        guard index < source.endIndex, source[index] == "[" else { return nil }
        index = source.index(after: index)
        var elements: [Substring] = []

        while true {
            index = skipWhitespace(from: index, in: source)
            guard index < source.endIndex else { return nil }
            if source[index] == "]" { return elements }
            let valueStart = index
            guard let valueEnd = jsonValueEnd(from: valueStart, in: source) else { return nil }
            elements.append(source[valueStart..<valueEnd])
            index = skipWhitespace(from: valueEnd, in: source)
            guard index < source.endIndex else { return nil }
            if source[index] == "," {
                index = source.index(after: index)
            } else if source[index] == "]" {
                return elements
            } else {
                return nil
            }
        }
    }

    private static func skipWhitespace(
        from start: Substring.Index,
        in source: Substring
    ) -> Substring.Index {
        var index = start
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        return index
    }

    /// JSON-String samt Ende lesen und Escapes über JSONSerialization korrekt
    /// dekodieren. MediaInfo-Schlüssel sind meist ASCII, der Lexer bleibt aber
    /// auch für Anführungszeichen und Unicode-Escapes korrekt.
    private static func jsonString(
        at start: Substring.Index,
        in source: Substring
    ) -> (value: String, end: Substring.Index)? {
        guard start < source.endIndex, source[start] == "\"" else { return nil }
        var index = source.index(after: start)
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let end = source.index(after: index)
                let token = String(source[start..<end])
                guard let data = "[\(token)]".data(using: .utf8),
                      let decoded = try? JSONSerialization.jsonObject(with: data) as? [String],
                      let value = decoded.first
                else { return nil }
                return (value, end)
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Index unmittelbar nach einem JSON-Wert. Bei Objekten und Arrays wird
    /// ein Klammerstapel geführt; Klammern innerhalb von Strings zählen nicht.
    private static func jsonValueEnd(
        from start: Substring.Index,
        in source: Substring
    ) -> Substring.Index? {
        guard start < source.endIndex else { return nil }
        if source[start] == "\"" {
            return jsonString(at: start, in: source)?.end
        }
        if source[start] == "{" || source[start] == "[" {
            var expected: [Character] = [source[start] == "{" ? "}" : "]"]
            var index = source.index(after: start)
            while index < source.endIndex {
                if source[index] == "\"", let parsed = jsonString(at: index, in: source) {
                    index = parsed.end
                    continue
                }
                switch source[index] {
                case "{": expected.append("}")
                case "[": expected.append("]")
                case "}", "]":
                    guard expected.last == source[index] else { return nil }
                    expected.removeLast()
                    if expected.isEmpty { return source.index(after: index) }
                default: break
                }
                index = source.index(after: index)
            }
            return nil
        }

        var index = start
        while index < source.endIndex,
              source[index] != ",", source[index] != "}", source[index] != "]" {
            index = source.index(after: index)
        }
        return index == start ? nil : index
    }

    static func decodeLossyJSON(_ data: Data) -> String { ExternalToolText.decodeLossyJSON(data) }
    static func decodeLossyPlainText(_ data: Data) -> String { ExternalToolText.decodeLossyPlainText(data) }
    static func repairSurrogateEscapes(in data: Data) -> Data { ExternalToolText.repairSurrogateEscapes(in: data) }

    // Kompatible Einstiege für bestehende Core-Nutzer und Regressionstests.
    typealias ProcessTimeoutError = ExternalToolRunner.ProcessTimeoutError
    static func run(_ executable: String, _ arguments: [String], processTimeout: TimeInterval? = nil) throws -> Data {
        try ExternalToolRunner.run(executable, arguments, processTimeout: processTimeout)
    }
    static func locateTool(candidates: [String], name: String) throws -> String {
        try ExternalToolRunner.locateTool(candidates: candidates, name: name)
    }
    static func utf8Environment() -> [String: String] { ExternalToolRunner.utf8Environment() }
}

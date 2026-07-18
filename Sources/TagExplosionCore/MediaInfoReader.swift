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

    /// Kandidaten-Pfade für das mediainfo-Binary (PATH zuerst, dann übliche Orte).
    public static let executableCandidates: [String] = [
        "mediainfo",
        "/opt/homebrew/bin/mediainfo",
        "/usr/local/bin/mediainfo",
        "/usr/bin/mediainfo",
    ]

    /// Findet das mediainfo-Binary oder wirft `toolNotFound`.
    public static func locateExecutable() throws -> String {
        for candidate in executableCandidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if let found = which(candidate) {
                return found
            }
        }
        throw TagError.toolNotFound(name: "mediainfo")
    }

    /// Liest den kompletten technischen Report einer Datei.
    public static func read(url: URL) throws -> MediaInfoReport {
        let exe = try locateExecutable()
        let jsonData = try run(exe, ["--Output=JSON", url.path])
        let textData = try run(exe, [url.path])
        let tracks = try parseTracks(jsonData: jsonData)
        let text = decodeLossy(textData).trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaInfoReport(tracks: tracks, text: text)
    }

    // MARK: - Intern

    /// mediainfo-JSON in Tracks zerlegen. Die Feld-Reihenfolge bleibt erhalten,
    /// deshalb ein kleiner eigener Parser statt JSONDecoder (der verliert Order).
    static func parseTracks(jsonData: Data) throws -> [MediaInfoTrack] {
        // mediainfo liefert gelegentlich kaputtes UTF-8 (rohe Latin1-Bytes aus
        // ID3v1/v2.3) — JSONSerialization lehnt das ab, daher lossy dekodieren
        // und wieder als sauberes UTF-8 einlesen.
        let jsonString = decodeLossy(jsonData)
        guard let cleaned = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any],
              let media = root["media"] as? [String: Any],
              let rawTracks = media["track"] as? [[String: Any]]
        else { return [] }

        // Reihenfolge: JSONSerialization gibt Dictionaries unsortiert zurück.
        // Für stabile Anzeige ermitteln wir die Original-Reihenfolge der Keys
        // direkt aus dem JSON-Text pro Track-Objekt.
        var result: [MediaInfoTrack] = []
        for raw in rawTracks {
            let type = (raw["@type"] as? String) ?? "?"
            var fields: [TagProperty] = []
            for key in orderedKeys(of: raw, in: jsonString) {
                guard key != "@type", key != "@ref" else { continue }
                let value = raw[key]
                if let s = value as? String {
                    fields.append(TagProperty(key: key, value: s))
                } else if let n = value as? NSNumber {
                    fields.append(TagProperty(key: key, value: n.stringValue))
                } else if let dict = value as? [String: Any] {
                    // "extra"-Block: verschachtelte Zusatzfelder flach anhängen
                    for (subKey, subValue) in dict {
                        fields.append(TagProperty(key: "\(key).\(subKey)", value: "\(subValue)"))
                    }
                }
            }
            result.append(MediaInfoTrack(type: type, fields: fields))
        }
        return result
    }

    /// Die Keys eines Track-Dictionaries in der Reihenfolge, in der sie im
    /// JSON-Text stehen. Fallback: alphabetisch.
    private static func orderedKeys(of dict: [String: Any], in json: String) -> [String] {
        var positions: [(String, String.Index)] = []
        for key in dict.keys {
            if let range = json.range(of: "\"\(key)\":") {
                positions.append((key, range.lowerBound))
            }
        }
        if positions.count == dict.count {
            return positions.sorted { $0.1 < $1.1 }.map(\.0)
        }
        return dict.keys.sorted()
    }

    /// Bytes tolerant zu String dekodieren: UTF-8 strikt → Latin1 → lossy UTF-8.
    /// mediainfo gibt rohe Tag-Bytes ungeprüft weiter; ID3v1/v2.3-Tags sind oft
    /// Latin1 und würden als UTF-8 gelesen zu Ersatzzeichen zerfallen.
    static func decodeLossy(_ data: Data) -> String {
        let repaired = repairSurrogateEscapes(in: data)
        if let s = String(data: repaired, encoding: .utf8) { return s }
        if let s = String(data: repaired, encoding: .isoLatin1) { return s }
        return String(decoding: repaired, as: UTF8.self)
    }

    /// mediainfo kodiert nicht-UTF-8-Bytes in JSON als Lone-Surrogates
    /// ("\udcfc" für Byte 0xFC, à la Python surrogateescape). JSON-Parser
    /// lehnen das ab bzw. verlieren die Information — deshalb ersetzen wir
    /// die Escape-Sequenzen im Bytestrom durch die Latin1-Deutung des Bytes.
    static func repairSurrogateEscapes(in data: Data) -> Data {
        // Schneller Vorab-Check, ob überhaupt "\udc" vorkommt
        let marker: [UInt8] = Array("\\udc".utf8)
        guard data.range(of: Data(marker)) != nil else { return data }

        var out = Data(capacity: data.count)
        var i = data.startIndex
        while i < data.endIndex {
            // Muster: \udcXY (6 Bytes ASCII, auch großgeschrieben möglich)
            if data[i] == UInt8(ascii: "\\"),
               data.index(i, offsetBy: 5, limitedBy: data.endIndex) != nil,
               data.distance(from: i, to: data.endIndex) >= 6,
               data[data.index(i, offsetBy: 1)] == UInt8(ascii: "u"),
               (data[data.index(i, offsetBy: 2)] | 0x20) == UInt8(ascii: "d"),
               (data[data.index(i, offsetBy: 3)] | 0x20) == UInt8(ascii: "c") {
                let hexBytes = [data[data.index(i, offsetBy: 4)], data[data.index(i, offsetBy: 5)]]
                if let hex = String(bytes: hexBytes, encoding: .ascii),
                   let byte = UInt8(hex, radix: 16) {
                    // Byte als Latin1-Zeichen in UTF-8 anhängen
                    let scalar = Unicode.Scalar(byte)
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    i = data.index(i, offsetBy: 6)
                    continue
                }
            }
            out.append(data[i])
            i = data.index(after: i)
        }
        return out
    }

    /// Externes Programm ausführen, stdout zurückgeben.
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TagError.toolFailed(
                name: (executable as NSString).lastPathComponent,
                exitCode: process.terminationStatus,
                stderr: decodeLossy(errData)
            )
        }
        return outData
    }

    /// Externes Programm über eine Kandidatenliste finden: Einträge mit "/"
    /// werden als Pfad geprüft, alle anderen über PATH gesucht. Gemeinsamer
    /// Mechanismus für mediainfo/exiftool/ebook-meta.
    static func locateTool(candidates: [String], name: String) throws -> String {
        for candidate in candidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if let found = which(candidate) {
                return found
            }
        }
        throw TagError.toolNotFound(name: name)
    }

    /// `which`-Ersatz: sucht ein Kommando im PATH.
    private static func which(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

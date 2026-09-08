// Untertitel-Sidecars `.srt` (SubRip) und `.vtt` (WebVTT): Anzeige von
// Cue-Anzahl, Zeitspanne, Zeichensatz, Sprache/Flags aus dem Dateinamen und
// bei VTT dem Kopfblock. Bearbeitbar sind nur der VTT-Titel (Text hinter
// `WEBVTT`) und die Kopfzeile `Language:`; SRT kennt keinen Speicherort für
// Metadaten — die Sprache steckt dort allein im Dateinamen (`film.de.srt`).
//
// Dazu die Zeitverschiebung („alle Cues um +1,5 s"): Sie ändert ausschließlich
// die Zeitangaben echter Cue-Zeilen; jede andere Zeile bleibt byteweise
// erhalten, ebenso Zeichensatz, BOM und Zeilenende. Fallen:
// knowledge/kodi-nfo-untertitel.md.
import Foundation

public enum SubtitleFormat: String, Sendable, Codable {
    case srt
    case vtt
}

/// Kopfblock einer WebVTT-Datei.
public struct SubtitleHeader: Sendable, Codable, Equatable {
    /// Text hinter `WEBVTT` in der ersten Zeile.
    public var title: String
    /// Weitere Kopfzeilen bis zur ersten Leerzeile (z.B. `Kind: captions`,
    /// `Language: de`), unverändert.
    public var lines: [String]
    /// Inhalte der `NOTE`-Blöcke.
    public var notes: [String]

    public init(title: String = "", lines: [String] = [], notes: [String] = []) {
        self.title = title
        self.lines = lines
        self.notes = notes
    }
}

/// Aus dem Dateinamen abgeleitete Angaben: `film.en.forced.vtt` →
/// base "film", language "en", flags ["forced"].
public struct SubtitleFilenameParts: Sendable, Equatable {
    public var base: String
    public var language: String?
    public var flags: [String]

    public init(base: String, language: String?, flags: [String]) {
        self.base = base
        self.language = language
        self.flags = flags
    }
}

/// Reine Anzeigeinformationen einer Untertiteldatei.
public struct SubtitleInfo: Sendable, Codable, Equatable {
    public var format: SubtitleFormat
    public var cueCount: Int
    /// Beginn des ersten und Ende des letzten Cues in Millisekunden.
    public var firstStartMilliseconds: Int?
    public var lastEndMilliseconds: Int?
    /// Zeitspanne vom ersten Beginn bis zum letzten Ende (0 ohne Cues).
    public var spanMilliseconds: Int
    /// "UTF-8", "UTF-8 (BOM)", "UTF-16 (BOM)" oder "Latin-1".
    public var encoding: String
    /// "LF", "CRLF" oder "CR".
    public var lineEndings: String
    /// Sprache und Flags (forced, sdh, hi, cc, default) aus dem Dateinamen.
    public var languageFromName: String?
    public var flagsFromName: [String]
    /// Nur VTT.
    public var header: SubtitleHeader?

    public init(format: SubtitleFormat, cueCount: Int, firstStartMilliseconds: Int?,
                lastEndMilliseconds: Int?, spanMilliseconds: Int, encoding: String,
                lineEndings: String, languageFromName: String?, flagsFromName: [String],
                header: SubtitleHeader?) {
        self.format = format
        self.cueCount = cueCount
        self.firstStartMilliseconds = firstStartMilliseconds
        self.lastEndMilliseconds = lastEndMilliseconds
        self.spanMilliseconds = spanMilliseconds
        self.encoding = encoding
        self.lineEndings = lineEndings
        self.languageFromName = languageFromName
        self.flagsFromName = flagsFromName
        self.header = header
    }
}

/// Die beiden editierbaren VTT-Felder (bei SRT immer leer und gesperrt).
public struct SubtitleEditableFields: Sendable, Codable, Equatable {
    public var title: String
    public var language: String

    public init(title: String = "", language: String = "") {
        self.title = title
        self.language = language
    }
}

/// Gelesener Inhalt einer Untertiteldatei.
public struct SubtitleContents: Sendable, Equatable {
    public let info: SubtitleInfo
    public let fields: SubtitleEditableFields

    public init(info: SubtitleInfo, fields: SubtitleEditableFields) {
        self.info = info
        self.fields = fields
    }
}

public enum SubtitleFile {

    public static let extensions: Set<String> = ["srt", "vtt"]

    /// Flags, die im Dateinamen hinter der Sprache stehen dürfen.
    public static let knownFlags: Set<String> = ["forced", "sdh", "hi", "cc", "default"]

    public static func format(of url: URL) -> SubtitleFormat? {
        SubtitleFormat(rawValue: url.pathExtension.lowercased())
    }

    // MARK: - Dateiname

    /// `film.en.forced.vtt` → base "film", language "en", flags ["forced"].
    /// Die Sprache ist ein Kürzel aus 2–3 Buchstaben, optional mit Region
    /// (`pt-BR`); sie braucht davor einen nicht-leeren Basisnamen.
    public static func filenameParts(of url: URL) -> SubtitleFilenameParts {
        let stem = url.deletingPathExtension().lastPathComponent
        var parts = stem.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var flags: [String] = []
        while parts.count > 1, let last = parts.last, knownFlags.contains(last.lowercased()) {
            flags.insert(last.lowercased(), at: 0)
            parts.removeLast()
        }
        var language: String?
        if parts.count > 1, let last = parts.last,
           last.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})?$"#, options: .regularExpression) != nil {
            language = last
            parts.removeLast()
        }
        return SubtitleFilenameParts(base: parts.joined(separator: "."), language: language, flags: flags)
    }

    // MARK: - Zeichensatz

    struct Decoded {
        var text: String
        var encoding: String.Encoding
        var bom: [UInt8]
        var label: String

        /// Text wieder in den Ausgangszeichensatz bringen, BOM voran.
        func encode(_ text: String) -> Data? {
            guard let bytes = text.encoded(as: encoding) else { return nil }
            var out = Data(bom)
            // Foundation stellt bei UTF-16 selbst eine BOM voran.
            if encoding == .utf16 { out = Data() }
            out.append(bytes)
            return out
        }
    }

    /// UTF-8 (mit/ohne BOM) → UTF-16 mit BOM → Latin-1 als Rückfall.
    static func decode(_ data: Data) -> Decoded {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, bom: [0xEF, 0xBB, 0xBF], label: "UTF-8 (BOM)")
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return Decoded(text: text, encoding: .utf16, bom: [], label: "UTF-16 (BOM)")
        }
        if let text = String(data: data, encoding: .utf8) {
            return Decoded(text: text, encoding: .utf8, bom: [], label: "UTF-8")
        }
        let text = String.decoded(data, as: .isoLatin1) ?? ""
        return Decoded(text: text, encoding: .isoLatin1, bom: [], label: "Latin-1")
    }

    // MARK: - Zeilen

    /// Zeilen samt ihrem Zeilenende (Swift fasst "\r\n" als ein Zeichen).
    static func lines(keepingTerminators text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index].isNewline {
                result.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { result.append(text[start...]) }
        return result
    }

    /// Zeileninhalt ohne Zeilenende.
    static func content(of line: Substring) -> Substring {
        guard let last = line.last, last.isNewline else { return line }
        return line.dropLast()
    }

    static func terminator(of line: Substring) -> String {
        guard let last = line.last, last.isNewline else { return "" }
        return String(last)
    }

    // MARK: - Zeiten

    /// Zeitangabe `HH:MM:SS,mmm` (SRT) bzw. `[HH:]MM:SS.mmm` (VTT).
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"^(?:([0-9]+):)?([0-9]{1,2}):([0-9]{2})([.,])([0-9]{1,3})$"#)

    private struct Timestamp {
        var range: Range<String.Index>
        var milliseconds: Int
        var separator: Character
        var withHours: Bool
    }

    private struct Timing {
        var start: Timestamp
        var end: Timestamp
    }

    private static func timestamp(in text: String, range: Range<String.Index>) -> Timestamp? {
        let token = String(text[range])
        guard let match = timestampRegex.firstMatch(in: token, range: NSRange(token.startIndex..., in: token))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: token).map { String(token[$0]) }
        }
        guard let hours = Int(group(1) ?? "0"),
              let minutes = group(2).flatMap(Int.init), (0..<60).contains(minutes),
              let seconds = group(3).flatMap(Int.init), (0..<60).contains(seconds),
              let fraction = group(5),
              let millis = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
        let (wholeHours, hourOverflow) = hours.multipliedReportingOverflow(by: 3_600_000)
        guard !hourOverflow else { return nil }
        let (value, overflow) = wholeHours.addingReportingOverflow((minutes * 60 + seconds) * 1000 + millis)
        guard !overflow else { return nil }
        return Timestamp(range: range, milliseconds: value, separator: group(4)?.first ?? ",",
                         withHours: group(1) != nil)
    }

    /// Nur eine vollständige Zeitzeile zählt; Zeitangaben mitten in einem
    /// gesprochenen Satz bleiben Text. VTT-Einstellungen hinter dem Ende bleiben.
    private static func timing(in body: String) -> Timing? {
        guard let arrow = body.range(of: "-->"),
              let start = body[..<arrow.lowerBound].firstIndex(where: { !$0.isWhitespace }),
              let last = body[..<arrow.lowerBound].lastIndex(where: { !$0.isWhitespace }),
              let endStart = body[arrow.upperBound...].firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = body[endStart...].firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
        guard let first = timestamp(in: body, range: start..<body.index(after: last)),
              let second = timestamp(in: body, range: endStart..<end) else { return nil }
        return Timing(start: first, end: second)
    }

    /// Lesen und Verschieben verwenden dieselben Cue-Zeilen. Nach einer
    /// Zeitzeile gehört der Rest des Blocks zum Text; VTT-Kommentar-, Stil-
    /// und Regionsblöcke sowie der Kopf enthalten keine Cues.
    private static func timings(in allLines: [Substring]) -> [Int: Timing] {
        let isVTT = allLines.first.map { content(of: $0).hasPrefix("WEBVTT") } ?? false
        var atBlockStart = true
        var ignored = false
        var hasCue = false
        var result: [Int: Timing] = [:]
        for (index, line) in allLines.enumerated() {
            let body = String(content(of: line))
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                atBlockStart = true
                ignored = false
                hasCue = false
                continue
            }
            if atBlockStart {
                ignored = isVTT && (index == 0 || trimmed == "NOTE" || trimmed.hasPrefix("NOTE ")
                    || trimmed.hasPrefix("NOTE\t") || trimmed == "STYLE" || trimmed == "REGION")
                atBlockStart = false
            }
            guard !ignored, !hasCue, let timing = timing(in: body) else { continue }
            result[index] = timing
            hasCue = true
        }
        return result
    }

    /// `HH:MM:SS<sep>mmm`; ohne Stunden `MM:SS<sep>mmm` (nur solange < 1 h).
    static func formatTimestamp(_ ms: Int, separator: Character, withHours: Bool) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms / 60_000) % 60
        let seconds = (ms / 1000) % 60
        let millis = ms % 1000
        let tail = String(format: "%02d:%02d%@%03d", minutes, seconds, String(separator), millis)
        if withHours || hours > 0 {
            return (hours < 10 ? "0\(hours)" : "\(hours)") + ":" + tail
        }
        return tail
    }

    // MARK: - Lesen

    public static func read(url: URL) throws -> SubtitleContents {
        guard let format = format(of: url) else { throw TagError.cannotOpen(path: url.path) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: url.path)
        }
        return parse(data, format: format, url: url)
    }

    public static func readSnapshot(url: URL, expecting stamp: FileStamp? = nil)
        throws -> FileSnapshot<SubtitleContents> {
        try FileSnapshot.capture(at: url, expecting: stamp) { try read(url: url) }
    }

    static func parse(_ data: Data, format: SubtitleFormat, url: URL) -> SubtitleContents {
        let decoded = decode(data)
        let allLines = lines(keepingTerminators: decoded.text)
        var cueCount = 0
        var firstStart: Int?
        var lastEnd: Int?
        let cueTimings = timings(in: allLines)
        for index in allLines.indices {
            guard let timing = cueTimings[index] else { continue }
            cueCount += 1
            if firstStart == nil { firstStart = timing.start.milliseconds }
            lastEnd = max(lastEnd ?? 0, timing.end.milliseconds)
        }
        let lineEndings: String
        if decoded.text.contains("\r\n") {
            lineEndings = "CRLF"
        } else if decoded.text.contains("\r") {
            lineEndings = "CR"
        } else {
            lineEndings = "LF"
        }
        let parts = filenameParts(of: url)
        let header = format == .vtt ? parseHeader(allLines) : nil
        let info = SubtitleInfo(
            format: format, cueCount: cueCount,
            firstStartMilliseconds: firstStart, lastEndMilliseconds: lastEnd,
            spanMilliseconds: max(0, (lastEnd ?? 0) - (firstStart ?? 0)),
            encoding: decoded.label, lineEndings: lineEndings,
            languageFromName: parts.language, flagsFromName: parts.flags,
            header: header)
        let fields = SubtitleEditableFields(
            title: header?.title ?? "",
            language: header.flatMap { languageValue(in: $0.lines) } ?? "")
        return SubtitleContents(info: info, fields: fields)
    }

    /// WebVTT-Kopf: erste Zeile `WEBVTT[ Titel]`, weitere Kopfzeilen bis zur
    /// ersten Leerzeile; `NOTE`-Blöcke im ganzen Dokument.
    static func parseHeader(_ allLines: [Substring]) -> SubtitleHeader? {
        guard let first = allLines.first else { return nil }
        let firstContent = content(of: first)
        guard firstContent.hasPrefix("WEBVTT") else { return nil }
        let title = firstContent.dropFirst("WEBVTT".count)
            .trimmingCharacters(in: .whitespaces)
        var headerLines: [String] = []
        var index = 1
        while index < allLines.count {
            let line = content(of: allLines[index])
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            headerLines.append(String(line))
            index += 1
        }
        var notes: [String] = []
        var block: [String] = []
        func flush() {
            defer { block = [] }
            guard let head = block.first, head == "NOTE" || head.hasPrefix("NOTE ") || head.hasPrefix("NOTE\t")
            else { return }
            var text = [String(head.dropFirst("NOTE".count).trimmingCharacters(in: .whitespaces))]
            text.append(contentsOf: block.dropFirst())
            notes.append(text.filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        for line in allLines.dropFirst() {
            let text = String(content(of: line))
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                block.append(text)
            }
        }
        flush()
        return SubtitleHeader(title: title, lines: headerLines, notes: notes)
    }

    /// Wert der Kopfzeile `Language: xx` (Groß-/Kleinschreibung egal).
    static func languageValue(in headerLines: [String]) -> String? {
        for line in headerLines {
            if let range = line.range(of: #"^\s*Language\s*:"#, options: [.regularExpression, .caseInsensitive]) {
                return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - Schreiben (VTT-Kopf)

    /// Was das Format nicht speichern kann, wird VOR Sicherung und Schreibweg
    /// abgelehnt: SRT hat keinen Kopf; Titel und Sprache müssen einzeilig
    /// sein und dürfen keinen Cue-Pfeil enthalten.
    public static func requireWritable(_ fields: SubtitleEditableFields,
                                       original: SubtitleEditableFields, url: URL) throws {
        guard fields != original else { return }
        guard format(of: url) == .vtt else {
            throw TagError.unsupportedDocumentField(
                name: fields.title != original.title ? "title" : "language")
        }
        for (name, value) in [("title", fields.title), ("language", fields.language)] {
            guard !value.contains(where: \.isNewline), !value.contains("-->"),
                  value == value.trimmingCharacters(in: .whitespaces) else {
                throw TagError.invalidDocumentValue(
                    field: name, reason: "must be a single line without \"-->\" or surrounding spaces")
            }
        }
    }

    public static func write(url: URL, fields: SubtitleEditableFields,
                             original: SubtitleEditableFields,
                             expecting stamp: FileStamp? = nil) throws {
        try requireWritable(fields, original: original, url: url)
        guard fields != original else {
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            try rewrite(url: temp, originalPath: url.path) { text in
                try edited(text: text, fields: fields, original: original, path: url.path)
            }
        } validate: { temp in
            let readBack = try read(url: temp)
            guard readBack.fields == fields else { throw TagError.saveFailed(path: url.path) }
        }
    }

    /// Kopfzeilen ändern; alle anderen Zeilen bleiben unverändert.
    static func edited(text: String, fields: SubtitleEditableFields,
                       original: SubtitleEditableFields, path: String) throws -> String {
        var allLines = lines(keepingTerminators: text).map(String.init)
        guard let first = allLines.first, content(of: Substring(first)).hasPrefix("WEBVTT") else {
            throw TagError.cannotOpen(path: path)
        }
        let newline = terminator(of: Substring(first)).isEmpty
            ? (text.contains("\r\n") ? "\r\n" : "\n")
            : terminator(of: Substring(first))
        if fields.title != original.title {
            allLines[0] = "WEBVTT" + (fields.title.isEmpty ? "" : " " + fields.title) + terminator(of: Substring(first))
        }
        if fields.language != original.language {
            // Ende des Kopfblocks: erste Leerzeile.
            var end = 1
            while end < allLines.count,
                  !content(of: Substring(allLines[end])).trimmingCharacters(in: .whitespaces).isEmpty {
                end += 1
            }
            let existing = (1..<end).first {
                content(of: Substring(allLines[$0]))
                    .range(of: #"^\s*Language\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            if let existing {
                if fields.language.isEmpty {
                    allLines.remove(at: existing)
                } else {
                    allLines[existing] = "Language: \(fields.language)" + terminator(of: Substring(allLines[existing]))
                }
            } else if !fields.language.isEmpty {
                // Eine Datei, die nur aus "WEBVTT" ohne Zeilenende besteht,
                // braucht erst eines, damit die neue Zeile eine eigene ist.
                if terminator(of: Substring(allLines[end - 1])).isEmpty {
                    allLines[end - 1] += newline
                }
                let lineEnd = end < allLines.count ? newline : ""
                allLines.insert("Language: \(fields.language)" + lineEnd, at: end)
            }
        }
        return allLines.joined()
    }

    // MARK: - Zeitverschiebung

    /// Größte Verschiebung, die App und CLI annehmen: 1000 Stunden. Alles
    /// darüber ist keine Untertitel-Korrektur mehr, und die Umrechnung in
    /// Millisekunden bleibt so sicher im `Int`-Bereich.
    public static let maxShiftMilliseconds = 1000 * 3_600_000

    /// Sekunden (Eingabe von Person oder Kommandozeile) in Millisekunden.
    /// Wirft `invalidSubtitleShift` statt abzustürzen, wenn der Wert nicht
    /// endlich ist oder über `maxShiftMilliseconds` liegt — `Int(1e16 * 1000)`
    /// wäre sonst ein Laufzeitabbruch.
    public static func shiftMilliseconds(seconds: Double) throws -> Int {
        guard seconds.isFinite,
              abs(seconds) * 1000 <= Double(maxShiftMilliseconds) else {
            throw TagError.invalidSubtitleShift(
                reason: "offset must be a finite number of at most 1000 hours (3600000 s)")
        }
        return Int((seconds * 1000).rounded())
    }

    /// Verschiebt die beiden Zeitangaben jeder Cue-Zeile um `milliseconds`.
    /// Text- und Kommentarblöcke bleiben erhalten; negative Ergebnisse und
    /// Überläufe werden abgelehnt.
    public static func shifted(text: String, milliseconds delta: Int) throws -> String {
        try requireShiftRange(delta)
        let allLines = lines(keepingTerminators: text)
        let cueTimings = timings(in: allLines)
        var out = ""
        func moved(_ timestamp: Timestamp) throws -> String {
            let (value, overflow) = timestamp.milliseconds.addingReportingOverflow(delta)
            guard !overflow, value >= 0 else {
                throw TagError.invalidSubtitleShift(reason: "a cue would leave the supported timestamp range")
            }
            return formatTimestamp(value, separator: timestamp.separator, withHours: timestamp.withHours)
        }
        for (index, line) in allLines.enumerated() {
            guard let timing = cueTimings[index] else {
                out += line
                continue
            }
            let body = String(content(of: line))
            out += body[..<timing.start.range.lowerBound]
            out += try moved(timing.start)
            out += body[timing.start.range.upperBound..<timing.end.range.lowerBound]
            out += try moved(timing.end)
            out += body[timing.end.range.upperBound...]
            out += terminator(of: line)
        }
        return out
    }

    private static func requireShiftRange(_ delta: Int) throws {
        guard (-maxShiftMilliseconds...maxShiftMilliseconds).contains(delta) else {
            throw TagError.invalidSubtitleShift(reason: "offset must be at most 1000 hours")
        }
    }

    /// Verschiebt die Datei atomar (Sicherung macht der Aufrufer). Die
    /// Prüfung vergleicht Cue-Anzahl und ersten Beginn mit der Erwartung.
    public static func shift(url: URL, milliseconds delta: Int,
                             expecting stamp: FileStamp? = nil) throws {
        guard format(of: url) != nil else { throw TagError.cannotOpen(path: url.path) }
        try requireShiftRange(delta)
        guard delta != 0 else {
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }
        let before = try read(url: url).info
        guard before.cueCount > 0 else {
            throw TagError.invalidSubtitleShift(reason: "the file contains no cues")
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            try rewrite(url: temp, originalPath: url.path) { text in
                try shifted(text: text, milliseconds: delta)
            }
        } validate: { temp in
            let after = try read(url: temp).info
            guard after.cueCount == before.cueCount,
                  after.firstStartMilliseconds == before.firstStartMilliseconds.map({ $0 + delta }),
                  after.lastEndMilliseconds == before.lastEndMilliseconds.map({ $0 + delta }) else {
                throw TagError.saveFailed(path: url.path)
            }
        }
    }

    /// Liest die Datei, wandelt den Text und schreibt ihn im selben
    /// Zeichensatz (samt BOM) zurück. UTF-16 wird nur gelesen.
    private static func rewrite(url: URL, originalPath: String,
                                transform: (String) throws -> String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: originalPath)
        }
        let decoded = decode(data)
        guard decoded.encoding != .utf16 else {
            throw TagError.invalidDocumentValue(
                field: "encoding", reason: "UTF-16 subtitles are shown but not written")
        }
        let output = try transform(decoded.text)
        guard let bytes = decoded.encode(output) else { throw TagError.saveFailed(path: originalPath) }
        do {
            try bytes.write(to: url)
        } catch {
            throw TagError.saveFailed(path: originalPath)
        }
    }
}

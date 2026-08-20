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

    /// Interner Fehler für Tests, die einen bewusst kurzen Schutz gegen
    /// festhängende Hilfsprozesse einschalten. Die normalen Aufrufe verwenden
    /// keinen Timeout und behalten dadurch ihr bisheriges Verhalten.
    enum ProcessTimeoutError: Error, LocalizedError, Sendable, Equatable {
        case exceeded

        var errorDescription: String? {
            "External process exceeded its test timeout"
        }
    }

    /// MediaInfo endete erfolgreich, lieferte aber keinen lesbaren
    /// JSON-Bericht. Ein leerer Erfolg würde Werkzeug- oder Formatfehler in
    /// App und CLI unsichtbar machen.
    enum ReportError: Error, LocalizedError, Sendable, Equatable {
        case invalidJSON

        var errorDescription: String? {
            "mediainfo returned an unreadable JSON report"
        }
    }

    /// Sammelt genau einen Pipe-Stream. Die zwei Instanzen pro Prozess werden
    /// auf getrennten festen Queue-Arbeiten gelesen, damit ein volles stderr
    /// niemals stdout (oder umgekehrt) blockieren kann.
    private final class PipeCollector: @unchecked Sendable {
        private let handle: FileHandle
        private var collected = Data()

        init(_ handle: FileHandle) {
            self.handle = handle
        }

        func readToEnd() {
            collected = handle.readDataToEndOfFile()
        }

        func data() -> Data { collected }
    }

    /// Steuert genau einen optionalen Ablauf-Timer für einen Prozess. Das Lock
    /// entscheidet atomar, ob der Prozess normal fertig wurde oder der Timer
    /// ihn beendet; so kann ein bereits beendeter Prozess nicht nachträglich
    /// als Timeout gelten. `Process` ist nicht als Sendable annotiert; der
    /// Controller kapselt deshalb seinen einzigen Zugriff aus der Timer-Queue
    /// und schützt seinen eigenen Zustand mit dem Lock.
    private final class ProcessTimeoutController: @unchecked Sendable {
        private let process: Process
        private let lock = NSLock()
        private var timer: DispatchSourceTimer?
        private var didTimeout = false

        init(process: Process) {
            self.process = process
        }

        /// Startet den einmaligen Timer erst, nachdem der Prozess wirklich
        /// läuft. Eine Referenz auf Argumente wird bewusst nicht gespeichert.
        func start(after timeout: TimeInterval) {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.setEventHandler { [weak self] in
                self?.terminateIfStillRunning()
            }
            timer.schedule(deadline: .now() + timeout)

            lock.lock()
            self.timer = timer
            lock.unlock()
            timer.resume()
        }

        /// Macht den Timer nach einem regulären Prozessende unschädlich und
        /// meldet, ob er zuvor die Beendigung auslösen musste.
        func finish() -> Bool {
            lock.lock()
            let timer = self.timer
            self.timer = nil
            let didTimeout = self.didTimeout
            lock.unlock()

            timer?.cancel()
            return didTimeout
        }

        private func terminateIfStillRunning() {
            lock.lock()
            guard timer != nil, process.isRunning else {
                lock.unlock()
                return
            }
            didTimeout = true
            let timer = self.timer
            self.timer = nil
            lock.unlock()

            // Erst den Einmal-Timer freigeben, dann den noch laufenden
            // Kindprozess beenden. Nach `waitUntilExit()` liefern die beiden
            // Pipe-Reader dadurch zuverlässig EOF.
            timer?.cancel()
            process.terminate()
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
        for candidate in executableCandidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            } else if let found = which(candidate) {
                return found
            }
        }
        throw TagError.toolNotFound(name: "mediainfo")
    }

    /// Dateipfad in der Form, in der externe Programme ihn bekommen dürfen.
    ///
    /// Immer absolut: mediainfo, exiftool und `ebook-meta` lesen jedes Argument
    /// mit führendem Bindestrich als Option. Ein absoluter Pfad beginnt immer
    /// mit „/" und kann deshalb nie als Option missverstanden werden — auch
    /// nicht bei einer Datei namens „-etwas.jpg".
    public static func toolArgument(for url: URL) -> String {
        let path = MediaFormats.canonicalFileURL(url).path
        guard path.hasPrefix("/") else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return path
    }

    /// Liest den kompletten technischen Report einer Datei.
    public static func read(url: URL) throws -> MediaInfoReport {
        let exe = try locateExecutable()
        let path = toolArgument(for: url)
        let jsonData = try run(exe, ["--Output=JSON", path])
        let textData = try run(exe, [path])
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

    /// Bytes tolerant dekodieren: UTF-8 strikt; scheitert das, werden gültige
    /// UTF-8-Sequenzen ERHALTEN und nur die tatsächlich ungültigen Bytes in
    /// einer Ein-Byte-Kodierung gedeutet. Ein komplett umgeschalteter Bericht
    /// würde sonst wegen eines einzigen fremd kodierten Feldes auch korrekte
    /// UTF-8-Tags (etwa Emoji, deren Fortsetzungsbytes zufällig im C1-Bereich
    /// liegen) verstümmeln. mediainfo gibt rohe Tag-Bytes ungeprüft weiter;
    /// ID3v1/v2.3-Tags sind oft in einer Ein-Byte-Kodierung geschrieben und
    /// würden als UTF-8 gelesen zu Ersatzzeichen zerfallen.
    ///
    /// Entschieden wird je TEXTFELD, nicht je ungültigem Byte-Lauf: Ein Feld
    /// enthält seine fremden Bytes oft getrennt durch ASCII
    /// („Bäckereistraße" = 0x8A … 0xA7), und eine Entscheidung pro Lauf mischte
    /// darin zwei Kodierungen (Review-Fund 2026-08-18).
    ///
    /// Zur Wahl stehen MacRoman und Windows-1252. Windows-1252 statt reinem
    /// Latin-1, weil es in ID3v2.3 die real verbreitete Kodierung ist und
    /// 0x80–0x9F mit sichtbaren Zeichen belegt (Gedankenstrich, typografischer
    /// Apostroph, Auslassungspunkte) — für Bytes ab 0xA0 sind beide gleich.
    /// Gewählt wird nicht mehr allein am Vorkommen eines C1-Bytes, sondern über
    /// eine Plausibilitätswertung des ganzen Feldes: Ein C1-Byte neben einem
    /// Umlaut zog sonst ALLE Nicht-ASCII-Zeichen des Feldes auf MacRoman
    /// (Review-Fund 2026-08-20).
    static func decodeLossy(_ data: Data) -> String {
        let repaired = repairSurrogateEscapes(in: data)
        if let s = String(data: repaired, encoding: .utf8) { return s }

        // In Läufe aus gültigen UTF-8-Sequenzen und ungültigen Bytes zerlegen.
        let bytes = [UInt8](repaired)
        var runs: [(valid: Bool, range: Range<Int>)] = []
        var index = 0
        while index < bytes.count {
            let length = utf8SequenceLength(bytes, at: index)
            let valid = length != nil
            let next = index + (length ?? 1)
            if let last = runs.last, last.valid == valid {
                runs[runs.count - 1].range = last.range.lowerBound..<next
            } else {
                runs.append((valid, index..<next))
            }
            index = next
        }

        // Jeden Lauf seinem Textfeld zuordnen und dabei gleich merken, welche
        // Felder überhaupt fremde Bytes enthalten — beides in EINEM Durchlauf,
        // die Feldnummer steht ja schon fest, wenn der Lauf zugeordnet wird.
        //
        // Feldgrenze ist immer der Zeilenumbruch (Klartextausgaben von
        // mediainfo und Calibre); bei JSON zusätzlich das Anführungszeichen.
        // Nur bei JSON: In einer Klartextzeile steht das Anführungszeichen
        // mitten im Wert („Der \"Bär\" aus der Straße") und hätte das Feld
        // fälschlich geteilt (Review-Fund 2026-08-20). Beide Grenzzeichen sind
        // ASCII und können deshalb nie innerhalb eines ungültigen Laufs liegen:
        // Ein Byte unter 0x80 ist immer eine gültige UTF-8-Sequenz für sich.
        let quotesSeparateFields = looksLikeJSON(bytes)
        var fieldOfRun = [Int](repeating: 0, count: runs.count)
        var fieldsWithForeignBytes = Set<Int>()
        var field = 0
        var backslashes = 0
        for (position, run) in runs.enumerated() {
            fieldOfRun[position] = field
            guard run.valid else {
                fieldsWithForeignBytes.insert(field)
                backslashes = 0
                continue
            }
            for index in run.range {
                let byte = bytes[index]
                if byte == 0x0A || byte == 0x0D {
                    field += 1
                } else if byte == 0x22, quotesSeparateFields, backslashes % 2 == 0 {
                    // Ein maskiertes \" gehört zum Wert und trennt nicht.
                    field += 1
                }
                backslashes = byte == 0x5C ? backslashes + 1 : 0
            }
        }

        // Je Feld die plausiblere der beiden Kodierungen wählen.
        var encodingOfField: [Int: SingleByteEncoding] = [:]
        for field in fieldsWithForeignBytes {
            encodingOfField[field] = betterEncoding(
                runs: runs, fieldOfRun: fieldOfRun, field: field, bytes: bytes)
        }

        var out = ""
        for (position, run) in runs.enumerated() {
            if run.valid {
                out += String(decoding: bytes[run.range], as: UTF8.self)
            } else {
                let encoding = encodingOfField[fieldOfRun[position]] ?? .windows1252
                out += decode(bytes[run.range], as: encoding)
            }
        }
        return out
    }

    /// Beginnt die Ausgabe — nach führendem Weißraum — mit `{` oder `[`?
    /// Nur dann ist das Anführungszeichen eine Feldgrenze.
    private static func looksLikeJSON(_ bytes: [UInt8]) -> Bool {
        for byte in bytes {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { continue }
            return byte == 0x7B || byte == 0x5B
        }
        return false
    }

    /// Die beiden Ein-Byte-Kodierungen, zwischen denen entschieden wird.
    enum SingleByteEncoding { case macRoman, windows1252 }

    /// Windows-1252 belegt 0x80–0x9F abweichend von Latin-1; ab 0xA0 sind
    /// beide identisch. Die Tabelle steht hier ausgeschrieben, weil
    /// `String.Encoding.windowsCP1252` nicht auf jeder Plattform verfügbar ist
    /// und der Core Linux-portabel bleiben soll. nil = in Windows-1252 nicht
    /// belegt; dort bleibt das Latin-1-Steuerzeichen stehen.
    private static let windows1252C1: [Character?] = [
        "€", nil, "‚", "ƒ", "„", "…", "†", "‡", "ˆ", "‰", "Š", "‹", "Œ", nil, "Ž", nil,
        nil, "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "•", "–", "—", "˜", "™",
        "š", "›", "œ", nil, "ž", "Ÿ"
    ]

    private static func decode(_ slice: ArraySlice<UInt8>,
                               as encoding: SingleByteEncoding) -> String {
        switch encoding {
        case .macRoman:
            // MacRoman bildet jedes Byte ab; der Rückfall auf lossy UTF-8 ist
            // reine Vorsicht.
            return String(data: Data(slice), encoding: .macOSRoman)
                ?? String(decoding: slice, as: UTF8.self)
        case .windows1252:
            var out = ""
            for byte in slice {
                if (0x80...0x9F).contains(byte), let mapped = windows1252C1[Int(byte) - 0x80] {
                    out.append(mapped)
                } else {
                    // Latin-1: Byte-Wert = Unicode-Codepoint.
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
            return out
        }
    }

    /// Wählt die Kodierung, unter der die fremden Bytes eines Feldes im
    /// Zusammenhang plausibler aussehen. Bewertet wird jedes aus einem fremden
    /// Byte entstandene Zeichen: Ein Buchstabe wiegt schwerer als ein Symbol,
    /// und ein Großbuchstabe mitten in einem klein geschriebenen Wort
    /// („BŠckerei") ist ein starkes Gegenargument. Bei Gleichstand entscheidet
    /// wie bisher das C1-Byte für MacRoman — dort fehlt schlicht der
    /// Zusammenhang (etwa ein Feld aus einem einzigen Byte).
    private static func betterEncoding(runs: [(valid: Bool, range: Range<Int>)],
                                       fieldOfRun: [Int],
                                       field: Int,
                                       bytes: [UInt8]) -> SingleByteEncoding {
        var macRomanScore = 0
        var windowsScore = 0
        var hasC1 = false
        for (position, run) in runs.enumerated()
        where !run.valid && fieldOfRun[position] == field {
            if bytes[run.range].contains(where: { (0x80...0x9F).contains($0) }) { hasC1 = true }
            let before = precedingCharacter(runs: runs, position: position, bytes: bytes)
            macRomanScore += score(decode(bytes[run.range], as: .macRoman), before: before)
            windowsScore += score(decode(bytes[run.range], as: .windows1252), before: before)
        }
        if macRomanScore != windowsScore {
            return macRomanScore > windowsScore ? .macRoman : .windows1252
        }
        return hasC1 ? .macRoman : .windows1252
    }

    /// Bewertung einer Kandidaten-Dekodierung im Zusammenhang des Zeichens,
    /// das links davor steht.
    private static func score(_ text: String, before: Character?) -> Int {
        var total = 0
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let left = index == 0 ? before : characters[index - 1]
            if character.isLetter {
                total += 2
                // Ein Großbuchstabe MITTEN im Wort („BŠckerei") kommt in echten
                // Tags praktisch nicht vor; am Wortanfang („Ärger") dagegen
                // ständig. Entscheidend ist deshalb allein, ob links ein
                // Buchstabe steht.
                if character.isUppercase, left?.isLetter ?? false { total -= 3 }
            } else if let scalar = character.unicodeScalars.first,
                      scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                // Steuerzeichen sind in einem Textfeld immer falsch.
                total -= 2
            }
        }
        return total
    }

    /// Letztes Zeichen vor dem Lauf, sofern es aus gültigem UTF-8 stammt.
    private static func precedingCharacter(runs: [(valid: Bool, range: Range<Int>)],
                                           position: Int, bytes: [UInt8]) -> Character? {
        guard position > 0, runs[position - 1].valid else { return nil }
        return String(decoding: bytes[runs[position - 1].range], as: UTF8.self).last
    }


    /// Länge der gültigen UTF-8-Sequenz an `index`, sonst nil. Prüft
    /// Fortsetzungsbytes, Überlang-Kodierungen, Surrogate und die
    /// Unicode-Obergrenze — nur echte Sequenzen zählen als gültig.
    private static func utf8SequenceLength(_ bytes: [UInt8], at index: Int) -> Int? {
        let first = bytes[index]
        if first < 0x80 { return 1 }
        let length: Int
        let minScalar: UInt32
        switch first {
        case 0xC2...0xDF: length = 2; minScalar = 0x80
        case 0xE0...0xEF: length = 3; minScalar = 0x800
        case 0xF0...0xF4: length = 4; minScalar = 0x10000
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        var scalar = UInt32(first) & (0xFF >> UInt32(length + 1))
        for offset in 1..<length {
            let byte = bytes[index + offset]
            guard (0x80...0xBF).contains(byte) else { return nil }
            scalar = (scalar << 6) | UInt32(byte & 0x3F)
        }
        guard scalar >= minScalar, scalar <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(scalar) else { return nil }
        return length
    }

    /// mediainfo kodiert nicht-UTF-8-Bytes in JSON als Lone-Surrogates
    /// ("\udcfc" für Byte 0xFC, à la Python surrogateescape). JSON-Parser
    /// lehnen das ab bzw. verlieren die Information — deshalb stellen wir das
    /// ROHE Originalbyte wieder her. Es bleibt dadurch bis zur
    /// Kodierungsentscheidung in `decodeLossy` erhalten und wird dort wie
    /// jedes andere ungültige Byte als MacRoman/Latin1 gedeutet ("\udc8a" ist
    /// MacRomans "ä" und würde als vorschnelles Latin1 zum Steuerzeichen
    /// U+008A).
    static func repairSurrogateEscapes(in data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = Data(capacity: bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\\") else {
                out.append(bytes[i])
                i += 1
                continue
            }
            // Backslash-Lauf am Stück betrachten: In JSON ist jedes PAAR ein
            // literaler Backslash und leitet nichts ein. `\\udcfc` meint den
            // Text „udcfc" und wurde vorher fälschlich zum Rohbyte umgebaut
            // (Review-Fund 2026-08-17).
            var run = 0
            while i + run < bytes.count, bytes[i + run] == UInt8(ascii: "\\") { run += 1 }
            let literals = run - (run % 2)
            out.append(contentsOf: repeatElement(UInt8(ascii: "\\"), count: literals))
            i += literals
            guard run % 2 == 1 else { continue }

            // Ab hier steht ein einzelner Backslash, der wirklich eine
            // Escape-Folge einleitet.
            guard let value = unicodeEscapeValue(bytes, at: i) else {
                out.append(bytes[i])
                i += 1
                continue
            }
            if (0xD800...0xDBFF).contains(value) {
                // Hohes Surrogat. Folgt unmittelbar ein niedriges, ist das ein
                // GÜLTIGES Paar (etwa `\ud83d\udcfc`) und beschreibt ein
                // echtes Zeichen jenseits der BMP — beide Hälften bleiben
                // unangetastet. Vorher wurde die zweite Hälfte zum Rohbyte
                // umgebaut und das Zeichen zerstört.
                if let low = unicodeEscapeValue(bytes, at: i + 6),
                   (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[i..<(i + 12)])
                    i += 12
                    continue
                }
                out.append(contentsOf: bytes[i..<(i + 6)])
                i += 6
                continue
            }
            // Nur die von mediainfo erzeugten Byte-Fluchten DC80–DCFF werden zum
            // Rohbyte zurückgebaut — und nur, wenn sie allein stehen.
            if (0xDC80...0xDCFF).contains(value) {
                out.append(UInt8(value & 0xFF))
                i += 6
                continue
            }
            out.append(contentsOf: bytes[i..<(i + 6)])
            i += 6
        }
        return out
    }

    /// Wert der `\uXXXX`-Folge, die an `index` beginnt — sonst nil.
    /// JSON kennt nur das kleine `u`; die Hexziffern dürfen beide Schreibweisen
    /// haben.
    private static func unicodeEscapeValue(_ bytes: [UInt8], at index: Int) -> UInt16? {
        guard index >= 0, index + 6 <= bytes.count,
              bytes[index] == UInt8(ascii: "\\"),
              bytes[index + 1] == UInt8(ascii: "u") else { return nil }
        var value: UInt16 = 0
        for offset in 2..<6 {
            guard let digit = hexDigitValue(bytes[index + offset]) else { return nil }
            value = value << 4 | UInt16(digit)
        }
        return value
    }

    private static func hexDigitValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// Externes Programm ausführen, stdout zurückgeben. Der optionale Timeout
    /// ist nur für Regressionstests gedacht; Produktivaufrufe übergeben nil.
    static func run(
        _ executable: String,
        _ arguments: [String],
        processTimeout: TimeInterval? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Ein einziger Timer schützt den Hänger-Regressionstest. Er wird nach
        // einem normalen Ende sofort abgebrochen und speichert keine Argumente.
        let timeoutController = processTimeout.map { timeout in
            let controller = ProcessTimeoutController(process: process)
            controller.start(after: timeout)
            return controller
        }

        // Niemals zuerst stdout und danach stderr synchron lesen: Schreibt ein
        // Tool beide Pipes über ihren Kernel-Puffer hinaus, würde es beim
        // ungelesenen zweiten Stream blockieren und `waitUntilExit()` nie
        // erreichen. Genau zwei Queue-Arbeiten pro Prozess reichen aus; sie
        // lesen jeweils bis EOF und erzeugen keine Arbeit pro Daten-Chunk.
        let outCollector = PipeCollector(stdout.fileHandleForReading)
        let errCollector = PipeCollector(stderr.fileHandleForReading)
        let drainGroup = DispatchGroup()
        let drainQueue = DispatchQueue(label: "io.github.tagexplosion.pipe-drain",
                                       qos: .userInitiated, attributes: .concurrent)
        drainGroup.enter()
        drainQueue.async {
            outCollector.readToEnd()
            drainGroup.leave()
        }
        drainGroup.enter()
        drainQueue.async {
            errCollector.readToEnd()
            drainGroup.leave()
        }
        process.waitUntilExit()
        let didTimeout = timeoutController?.finish() ?? false
        // EOF erst nach dem Prozessende abwarten, damit die Fehlerdiagnose die
        // vollständige stderr-Ausgabe enthält, nicht nur ihren ersten Puffer.
        drainGroup.wait()
        if didTimeout {
            throw ProcessTimeoutError.exceeded
        }
        let outData = outCollector.data()
        let errData = errCollector.data()
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

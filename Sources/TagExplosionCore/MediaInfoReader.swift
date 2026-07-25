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

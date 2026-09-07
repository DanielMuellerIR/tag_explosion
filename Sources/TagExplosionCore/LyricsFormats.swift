// Synchronisierte Lyrics als Austauschformat LRC und als Sidecar-Datei.
//
// LRC: eine Zeile je Textzeile, davor ein oder mehrere Zeitstempel
// `[mm:ss.xx]` (auch `[mm:ss]`, `[mm:ss.xxx]`, `[h:mm:ss.xx]`). Mehrere
// Zeitstempel vor einem Text bedeuten: dieselbe Zeile zu mehreren Zeiten
// (Refrain). Metadaten-Tags wie `[ar:Interpret]`, `[ti:Titel]`, `[al:Album]`,
// `[offset:+500]` bleiben als Metadaten erhalten; `offset` wird bewusst NICHT
// auf die Zeiten angewendet, weil Player das Vorzeichen unterschiedlich
// deuten. Wort-Zeitstempel `<mm:ss.xx>` (Enhanced LRC) werden entfernt.
//
// Sidecar: Formate ohne ID3v2 (FLAC, Ogg, Opus, MP4 …) haben keinen
// SYLT-Frame; dort liegen synchronisierte Lyrics in `<name>.lrc` neben der
// Mediendatei. Gelesen und geschrieben wird sie über `LRC.loadSidecar` /
// `LRC.writeSidecar` (Papierkorb-Sicherung + atomarer Austausch).
import Foundation

public enum LRC {

    /// Inhalt einer LRC-Datei: Zeilen (nach Zeit sortiert) und Metadaten in
    /// Dateireihenfolge.
    public struct Document: Sendable, Equatable {
        public var lines: [SyncedLyricLine]
        public var metadata: [(key: String, value: String)]

        public init(lines: [SyncedLyricLine], metadata: [(key: String, value: String)] = []) {
            self.lines = lines
            self.metadata = metadata
        }

        public static func == (lhs: Document, rhs: Document) -> Bool {
            lhs.lines == rhs.lines
                && lhs.metadata.map(\.key) == rhs.metadata.map(\.key)
                && lhs.metadata.map(\.value) == rhs.metadata.map(\.value)
        }
    }

    // MARK: - Zeitstempel

    /// `mm:ss.xx` mit Hundertstelsekunden — die verbreitete LRC-Form. Minuten
    /// laufen über 59 hinaus (LRC kennt keine Stunden).
    public static func formatTimestamp(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds)
        let hundredths = (total % 1000) / 10
        let seconds = (total / 1000) % 60
        let minutes = total / 60_000
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }

    /// Liest `mm:ss.xx`, `mm:ss`, `mm:ss.xxx` und `h:mm:ss.xx`; nil, wenn
    /// der Text keine Zeit ist. Nutzt den Kapitel-Parser (gleiche Regeln).
    public static func parseTimestamp(_ text: String) -> Int? {
        ChapterList.parseTimestamp(text)
    }

    // MARK: - Lesen

    /// Liest LRC-Text. Zeilen ohne Zeitstempel und ohne Metadaten-Tag werden
    /// übersprungen (Kommentare, Leerzeilen). Wirft `invalidLyrics`, wenn
    /// der Text gar keinen Zeitstempel enthält.
    public static func parse(_ text: String) throws -> Document {
        var lines: [SyncedLyricLine] = []
        var metadata: [(key: String, value: String)] = []
        var sawTimestamp = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            // Alle führenden `[…]`-Blöcke abtrennen.
            var rest = Substring(line)
            var times: [Int] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let inner = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
                if let time = parseTimestamp(inner) {
                    times.append(time)
                    sawTimestamp = true
                } else if let colon = inner.firstIndex(of: ":"),
                          !inner[..<colon].isEmpty,
                          inner[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                    metadata.append((key: String(inner[..<colon]).lowercased(),
                                     value: String(inner[inner.index(after: colon)...])
                                         .trimmingCharacters(in: .whitespaces)))
                } else {
                    break
                }
            }
            if times.isEmpty { continue }
            let content = stripWordTimestamps(String(rest)).trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append(SyncedLyricLine(milliseconds: time, text: content))
            }
        }
        guard sawTimestamp else {
            throw TagError.invalidLyrics(reason: "no [mm:ss.xx] timestamps found")
        }
        // Stabil sortieren: gleiche Zeit behält die Dateireihenfolge.
        lines = lines.enumerated().sorted {
            ($0.element.milliseconds, $0.offset) < ($1.element.milliseconds, $1.offset)
        }.map(\.element)
        return Document(lines: lines, metadata: metadata)
    }

    /// Entfernt Wort-Zeitstempel `<mm:ss.xx>` aus einer Zeile (Enhanced LRC).
    static func stripWordTimestamps(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">"),
                  parseTimestamp(String(rest[rest.index(after: open)..<close])) != nil else {
                result += rest[...open]
                rest = rest[rest.index(after: open)...]
                continue
            }
            result += rest[..<open]
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        // Doppelte Leerzeichen, die die Marker hinterlassen, zusammenziehen.
        return result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    // MARK: - Schreiben

    /// Erzeugt LRC-Text: Metadaten zuerst, dann eine Zeile je Zeitstempel.
    public static func render(_ lines: [SyncedLyricLine],
                              metadata: [(key: String, value: String)] = []) -> String {
        var out = metadata.map { "[\($0.key):\($0.value)]" }
        out += lines.map { "[\(formatTimestamp($0.milliseconds))]\($0.text)" }
        return out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")
    }

    /// Nur der Text der Zeilen (ohne Zeiten) — z.B. um aus einer LRC-Datei
    /// auch die unsynchronisierten Lyrics zu füllen.
    public static func plainText(_ lines: [SyncedLyricLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// Lehnt Zeilen mit negativer Zeit ab (SYLT speichert vorzeichenlos).
    public static func validate(_ lines: [SyncedLyricLine]) throws {
        if let bad = lines.firstIndex(where: { $0.milliseconds < 0 }) {
            throw TagError.invalidLyrics(reason: "line \(bad + 1) has a negative time")
        }
    }

    // MARK: - Datei und Sidecar

    /// Liest eine LRC-Datei (UTF-8).
    public static func load(from url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TagError.invalidLyrics(reason: "\(url.lastPathComponent) is not UTF-8 text")
        }
        return try parse(text)
    }

    /// `<name>.lrc` neben der Mediendatei.
    public static func sidecarURL(for mediaURL: URL) -> URL {
        mediaURL.deletingPathExtension().appendingPathExtension("lrc")
    }

    /// Zeilen der Sidecar oder nil, wenn es keine gibt.
    public static func loadSidecar(for mediaURL: URL) throws -> [SyncedLyricLine]? {
        let url = sidecarURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load(from: url).lines
    }

    /// Schreibt die Sidecar (leere Liste = Sidecar löschen). Vorhandene
    /// Sidecars wandern vorher in den Papierkorb (abgesicherter Modus) und
    /// werden atomar ersetzt; eine neue entsteht exklusiv.
    ///
    /// Der Stempel-Einstieg bleibt für bestehende Aufrufer erhalten. nil heißt
    /// hier ausdrücklich „ohne bekannten Lesestand“. Neue Aufrufer reichen
    /// `SidecarState.absent` weiter, wenn beim Lesen keine Sidecar existierte.
    public static func writeSidecar(_ lines: [SyncedLyricLine], for mediaURL: URL,
                                    expecting stamp: FileStamp? = nil,
                                    backUp: Bool = true) throws {
        try writeSidecar(lines, for: mediaURL,
                         expecting: stamp.map(SidecarState.present) ?? .unknown, backUp: backUp)
    }

    /// Prüft auch fremdes Anlegen und Löschen vor Sicherung und Austausch.
    /// `backUp: false` gilt nur nach vorheriger Sicherung durch den Aufrufer.
    public static func writeSidecar(_ lines: [SyncedLyricLine], for mediaURL: URL,
                                    expecting state: SidecarState,
                                    backUp: Bool = true) throws {
        try validate(lines)
        let url = sidecarURL(for: mediaURL)
        let observed = state == .unknown ? SidecarState.current(of: url) : state
        try observed.requireUnchanged(at: url)
        let stamp: FileStamp?
        if case .present(let value) = observed { stamp = value } else { stamp = nil }
        let exists = stamp != nil
        if lines.isEmpty {
            guard exists else { return }
            if backUp { try TrashBackup.shared.backUp(url) }
            try observed.requireUnchanged(at: url)
            try FileManager.default.removeItem(at: url)
            return
        }
        let data = Data(render(lines).utf8)
        let mutate: (URL) throws -> Void = { temp in
            try data.write(to: temp, options: .atomic)
        }
        let validate: (URL) throws -> Void = { temp in
            guard try load(from: temp).lines == lines else { throw TagError.saveFailed(path: url.path) }
        }
        if exists {
            if backUp { try TrashBackup.shared.backUp(url) }
            try AtomicFileRewrite.run(url: url, expecting: stamp, mutate: mutate, validate: validate)
        } else {
            try AtomicFileRewrite.create(url: url, replacingOriginal: true, beforeReplace: {},
                                         mutate: mutate, validate: validate)
        }
    }

    /// Stempel der Sidecar beim Lesen — nil, wenn keine daneben liegt. Wird
    /// zusammen mit dem Medium erhoben und beim Schreiben als `expecting`
    /// zurückgegeben.
    public static func sidecarStamp(for mediaURL: URL) -> FileStamp? {
        FileStamp.current(of: sidecarURL(for: mediaURL))
    }
}

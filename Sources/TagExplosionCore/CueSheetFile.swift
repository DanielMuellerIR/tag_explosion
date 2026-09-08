// Cue-Sheet (.cue): Album-Kopf (REM-Zeilen, CATALOG, PERFORMER, TITLE,
// SONGWRITER), dann je Audiodatei eine FILE-Zeile und darunter die Tracks
// (TRACK nn AUDIO mit TITLE, PERFORMER, ISRC, FLAGS, PREGAP, INDEX …).
//
//   REM GENRE Rock
//   REM DATE 1999
//   PERFORMER "Die Band"
//   TITLE "Das Album"
//   FILE "album.flac" WAVE
//     TRACK 01 AUDIO
//       TITLE "Erstes Lied"
//       PERFORMER "Die Band"
//       INDEX 01 00:00:00
//
// Lesen: Kopf und Trackliste. Schreiben: nur TITLE/PERFORMER (Kopf und
// Track) sowie REM DATE/REM GENRE werden ersetzt, eingefügt oder entfernt;
// alle übrigen Zeilen, ihre Reihenfolge, Einrückung und Zeilenenden bleiben.
// Nach jeder Einzeländerung wird neu geparst — die Dateien sind winzig, und
// so verschieben Einfügungen keine gemerkten Zeilennummern.
import Foundation

enum CueSheetFile: PlaylistBackend {

    static let supportedFields: Set<PlaylistField> = [
        .title, .performer, .date, .genre, .entryTitle, .entryPerformer,
    ]

    // MARK: - Zerlegte Struktur

    /// Ein Track: die TRACK-Zeile und die Zeilen bis zum nächsten TRACK/FILE.
    struct Track {
        var number: Int
        var lineIndex: Int
        /// Zeilen NACH der TRACK-Zeile, die zu diesem Track gehören.
        var body: Range<Int>
        /// Name aus der zuletzt gesehenen FILE-Zeile ("" ohne FILE).
        var file: String
        var title = ""
        var performer = ""
        var isrc = ""
        /// INDEX 01 in Millisekunden.
        var start: Int?
    }

    struct Parsed {
        var file: PlaylistTextFile
        /// Zeilen vor dem ersten TRACK (der Album-Kopf, FILE eingeschlossen).
        var header: Range<Int>
        var tracks: [Track]
        var title = ""
        var performer = ""
        var date = ""
        var genre = ""
        var info: [DocumentInfoItem] = []
    }

    /// Befehl (Großschreibung) und Rest einer Zeile; nil für Leerzeilen.
    static func command(of text: String) -> (name: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let name = String(parts[0]).uppercased()
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (name, rest)
    }

    /// `"Wert"` → Wert; ohne Anführungszeichen der ganze Rest.
    static func unquote(_ rest: String) -> String {
        guard rest.hasPrefix("\""), rest.count >= 2,
              let close = rest.dropFirst().lastIndex(of: "\"") else { return rest }
        return String(rest[rest.index(after: rest.startIndex)..<close])
    }

    /// `"name.wav" WAVE` → name.wav (unquotiert: alles vor dem letzten Wort).
    static func fileName(from rest: String) -> String {
        if rest.hasPrefix("\"") { return unquote(rest) }
        let parts = rest.split(separator: " ")
        guard parts.count > 1 else { return rest }
        return parts.dropLast().joined(separator: " ")
    }

    /// `mm:ss:ff` (75 Frames je Sekunde) → Millisekunden.
    static func milliseconds(fromIndex text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let mm = parts[0], let ss = parts[1], let ff = parts[2],
              mm >= 0, (0..<60).contains(ss), (0..<75).contains(ff) else { return nil }
        let (minutes, minutesOverflow) = mm.multipliedReportingOverflow(by: 60_000)
        guard !minutesOverflow else { return nil }
        // Frames sind auf 0…74 begrenzt; ganzzahlig auf Millisekunden runden.
        let remainder = ss * 1000 + (ff * 1000 + 37) / 75
        let (result, overflow) = minutes.addingReportingOverflow(remainder)
        return overflow ? nil : result
    }

    static func parse(_ file: PlaylistTextFile) -> Parsed {
        var parsed = Parsed(file: file, header: 0..<0, tracks: [])
        var currentFile = ""
        var firstTrackLine: Int?
        var remInfo: [DocumentInfoItem] = []
        for (index, line) in file.lines.enumerated() {
            guard let (name, rest) = command(of: line.text) else { continue }
            if var track = parsed.tracks.last, firstTrackLine != nil, name != "TRACK" {
                // Zeile gehört zum laufenden Track.
                track.body = track.body.lowerBound..<(index + 1)
                switch name {
                case "TITLE": track.title = unquote(rest)
                case "PERFORMER": track.performer = unquote(rest)
                case "ISRC": track.isrc = rest
                case "INDEX":
                    let parts = rest.split(separator: " ")
                    if parts.count == 2, parts[0] == "01" || parts[0] == "1" {
                        track.start = milliseconds(fromIndex: String(parts[1]))
                    }
                case "FILE":
                    // Eine FILE-Zeile mitten in der Trackliste gilt für die
                    // folgenden Tracks (seltene, aber gültige Form).
                    currentFile = fileName(from: rest)
                default: break
                }
                parsed.tracks[parsed.tracks.count - 1] = track
                continue
            }
            switch name {
            case "TRACK":
                if firstTrackLine == nil { firstTrackLine = index }
                let number = Int(rest.split(separator: " ").first ?? "") ?? parsed.tracks.count + 1
                parsed.tracks.append(Track(number: number, lineIndex: index,
                                           body: (index + 1)..<(index + 1), file: currentFile))
            case "FILE": currentFile = fileName(from: rest)
            case "TITLE": parsed.title = unquote(rest)
            case "PERFORMER": parsed.performer = unquote(rest)
            case "REM":
                let parts = rest.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                guard let key = parts.first.map({ String($0).uppercased() }) else { break }
                let value = parts.count > 1 ? unquote(String(parts[1]).trimmingCharacters(in: .whitespaces)) : ""
                switch key {
                case "DATE": parsed.date = value
                case "GENRE": parsed.genre = value
                default: remInfo.append(DocumentInfoItem(label: "REM \(key)", value: value))
                }
            case "CATALOG", "SONGWRITER", "CDTEXTFILE":
                parsed.info.append(DocumentInfoItem(label: name, value: unquote(rest)))
            default: break
            }
        }
        parsed.header = 0..<(firstTrackLine ?? file.lines.count)
        parsed.info.append(contentsOf: remInfo)
        return parsed
    }

    // MARK: - Lesen

    static func read(url: URL, base: URL) throws -> PlaylistContents {
        let file = try PlaylistTextFile.load(url: url)
        let parsed = parse(file)
        // Ein Cue-Sheet ohne jeden TRACK und ohne FILE ist keins.
        guard !parsed.tracks.isEmpty || file.lines.contains(where: { command(of: $0.text)?.name == "FILE" })
        else { throw TagError.cannotOpen(path: url.path) }

        var entries: [PlaylistEntry] = []
        for track in parsed.tracks {
            entries.append(PlaylistTool.makeEntry(
                number: track.number, location: track.file, base: base,
                title: track.title, performer: track.performer,
                startMilliseconds: track.start, isrc: track.isrc))
        }
        fillDurations(&entries)

        let fields = PlaylistCoreFields(
            title: parsed.title, performer: parsed.performer, date: parsed.date,
            genre: parsed.genre, entries: entries.map(\.fields))
        var info = parsed.info
        let files = Set(parsed.tracks.map(\.file)).filter { !$0.isEmpty }
        info.append(DocumentInfoItem(label: "files", value: "\(files.count)"))
        return PlaylistContents(format: .cue, fields: fields, entries: entries, info: info,
                                usedEncodingFallback: file.usedEncodingFallback)
    }

    /// Spielzeit je Track: bis zum nächsten Track derselben Datei; der letzte
    /// Track einer Datei reicht bis zu deren Ende (Länge per TagLib, sofern
    /// die Datei existiert und lesbar ist).
    private static func fillDurations(_ entries: inout [PlaylistEntry]) {
        var fileLengths: [String: Int?] = [:]
        var nextByPath: [String?: Int] = [:]
        // Rückwärts genügt ein gemerkter nächster Track je Datei. Vorwärts
        // müsste jeder Eintrag den verbleibenden Rest der Liste durchsuchen.
        for index in entries.indices.reversed() {
            let next = nextByPath.updateValue(index, forKey: entries[index].resolvedPath)
            guard let start = entries[index].startMilliseconds else { continue }
            if let next, let nextStart = entries[next].startMilliseconds, nextStart >= start {
                entries[index].durationMilliseconds = nextStart - start
                continue
            }
            guard let path = entries[index].resolvedPath, entries[index].exists else { continue }
            if fileLengths[path] == nil {
                let length = (try? TagFile.read(at: URL(fileURLWithPath: path)))?.audio?.lengthMilliseconds
                fileLengths[path] = .some(length)
            }
            if let length = fileLengths[path] ?? nil, length >= start {
                entries[index].durationMilliseconds = length - start
            }
        }
    }

    // MARK: - Schreiben

    static func validate(_ fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {
        // Cue kennt kein Escape für Anführungszeichen.
        for (name, value) in [("title", fields.title), ("performer", fields.performer),
                              ("date", fields.date), ("genre", fields.genre)]
        where value.contains("\"") {
            throw TagError.invalidDocumentValue(field: name, reason: "cue values cannot contain '\"'")
        }
        for (index, entry) in fields.entries.enumerated()
        where entry.title.contains("\"") || entry.performer.contains("\"") {
            throw TagError.invalidDocumentValue(
                field: "entry \(index + 1)", reason: "cue values cannot contain '\"'")
        }
    }

    static func mutate(url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {
        var file = try PlaylistTextFile.load(url: url)
        if fields.title != original.title {
            setHeader(&file, command: "TITLE", value: fields.title)
        }
        if fields.performer != original.performer {
            setHeader(&file, command: "PERFORMER", value: fields.performer)
        }
        if fields.date != original.date {
            setRem(&file, key: "DATE", value: fields.date)
        }
        if fields.genre != original.genre {
            setRem(&file, key: "GENRE", value: fields.genre)
        }
        for (index, entry) in fields.entries.enumerated() where entry != original.entries[index] {
            if entry.title != original.entries[index].title {
                setTrackField(&file, trackIndex: index, command: "TITLE", value: entry.title)
            }
            if entry.performer != original.entries[index].performer {
                setTrackField(&file, trackIndex: index, command: "PERFORMER", value: entry.performer)
            }
        }
        try file.write(to: url)
    }

    /// `"Wert"`; REM-Werte nur bei Leerraum in Anführungszeichen (EAC-Stil).
    private static func quoted(_ value: String) -> String { "\"\(value)\"" }

    private static func remValue(_ value: String) -> String {
        value.contains(" ") || value.contains("\t") ? quoted(value) : value
    }

    /// Ersetzt die Zeile: Einrückung und Befehlswort bleiben, nur der Wert wechselt.
    private static func rewrite(_ file: inout PlaylistTextFile, at index: Int, value: String) {
        let old = file.lines[index].text
        let indent = PlaylistTextFile.indentation(of: old)
        let word = old.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })[0]
        file.replace("\(indent)\(word) \(value)", at: index)
    }

    /// Kopfzeile TITLE/PERFORMER setzen, einfügen oder entfernen.
    private static func setHeader(_ file: inout PlaylistTextFile, command: String, value: String) {
        let parsed = parse(file)
        let header = parsed.header
        if let index = header.first(where: { Self.command(of: file.lines[$0].text)?.name == command }) {
            if value.isEmpty {
                file.remove(at: index)
            } else {
                rewrite(&file, at: index, value: quoted(value))
            }
            return
        }
        guard !value.isEmpty else { return }
        // PERFORMER steht vor TITLE; beide hinter REM/CATALOG und vor FILE.
        let anchors: Set<String> = command == "TITLE"
            ? ["REM", "CATALOG", "PERFORMER", "SONGWRITER"]
            : ["REM", "CATALOG"]
        let position = header.last { anchors.contains(Self.command(of: file.lines[$0].text)?.name ?? "") }
            .map { $0 + 1 }
            ?? header.first { Self.command(of: file.lines[$0].text) != nil } ?? 0
        let indent = header.first.map { PlaylistTextFile.indentation(of: file.lines[$0].text) } ?? ""
        file.insert("\(indent)\(command) \(quoted(value))", at: position)
    }

    /// `REM KEY value` im Kopf setzen, einfügen oder entfernen.
    private static func setRem(_ file: inout PlaylistTextFile, key: String, value: String) {
        let parsed = parse(file)
        let header = parsed.header
        func remKey(_ index: Int) -> String? {
            guard let (name, rest) = command(of: file.lines[index].text), name == "REM" else { return nil }
            return rest.split(separator: " ").first.map { String($0).uppercased() }
        }
        if let index = header.first(where: { remKey($0) == key }) {
            if value.isEmpty {
                file.remove(at: index)
            } else {
                let indent = PlaylistTextFile.indentation(of: file.lines[index].text)
                file.replace("\(indent)REM \(key) \(remValue(value))", at: index)
            }
            return
        }
        guard !value.isEmpty else { return }
        // Hinter die letzte REM-Zeile, sonst ganz nach oben.
        let position = header.last { remKey($0) != nil }.map { $0 + 1 } ?? 0
        file.insert("REM \(key) \(remValue(value))", at: position)
    }

    /// TITLE/PERFORMER eines Tracks setzen, einfügen oder entfernen.
    private static func setTrackField(_ file: inout PlaylistTextFile, trackIndex: Int,
                                      command: String, value: String) {
        let parsed = parse(file)
        guard trackIndex < parsed.tracks.count else { return }
        let track = parsed.tracks[trackIndex]
        if let index = track.body.first(where: { Self.command(of: file.lines[$0].text)?.name == command }) {
            if value.isEmpty {
                file.remove(at: index)
            } else {
                rewrite(&file, at: index, value: quoted(value))
            }
            return
        }
        guard !value.isEmpty else { return }
        // TITLE direkt hinter TRACK, PERFORMER hinter TITLE (falls vorhanden).
        var position = track.lineIndex + 1
        if command == "PERFORMER",
           let title = track.body.first(where: { Self.command(of: file.lines[$0].text)?.name == "TITLE" }) {
            position = title + 1
        }
        // Einrückung wie die vorhandenen Feldzeilen des Tracks, sonst eine
        // Stufe tiefer als die TRACK-Zeile.
        let trackIndent = PlaylistTextFile.indentation(of: file.lines[track.lineIndex].text)
        let indent = track.body.first { Self.command(of: file.lines[$0].text) != nil }
            .map { PlaylistTextFile.indentation(of: file.lines[$0].text) }
            ?? (trackIndent.isEmpty ? "  " : trackIndent + trackIndent)
        file.insert("\(indent)\(command) \(quoted(value))", at: position)
    }
}

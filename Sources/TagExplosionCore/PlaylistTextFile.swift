// Zeilenweises Lesen und Schreiben der Text-Playlists (cue, m3u/m3u8, pls).
// Jede Zeile behält ihr Zeilenende ("\n" oder "\r\n"); eine Byte-Order-Mark
// am Anfang bleibt erhalten. Beim Schreiben werden nur die Zeilen ersetzt
// oder eingefügt, die das Backend anfasst — alles andere kommt unverändert
// zurück (Vorbild: MarkdownFrontmatter).
//
// Encoding: UTF-8 ist der Normalfall (m3u8, moderne cue-Dateien). Ältere
// Dateien liegen oft in Latin1 oder MacRoman vor; dann greift dieselbe
// Reparatur wie beim mediainfo-JSON (`MediaInfoReader.decodeLossyPlainText`:
// UTF-8-Läufe behalten, Restbytes als MacRoman/Latin1 werten). Eine so
// gelesene Datei wird beim Schreiben als UTF-8 abgelegt — der Rest der
// Zeilen wird also mit umkodiert (siehe knowledge/playlists-cue.md).
import Foundation

/// Eine Zeile ohne Zeilenende plus das Zeilenende, wie es in der Datei stand.
struct PlaylistTextLine: Equatable {
    var text: String
    /// "\n", "\r\n" oder "" (letzte Zeile ohne Zeilenende).
    var ending: String
}

/// Zerlegte Textdatei.
struct PlaylistTextFile: Equatable {
    var hasBOM: Bool
    var lines: [PlaylistTextLine]
    /// Datei war kein gültiges UTF-8 (Fallback-Dekodierung).
    var usedEncodingFallback: Bool

    private static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Liest und zerlegt die Datei.
    static func load(url: URL) throws -> PlaylistTextFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: url.path)
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> PlaylistTextFile {
        var bytes = [UInt8](data)
        var hasBOM = false
        if bytes.starts(with: bomBytes) {
            hasBOM = true
            bytes.removeFirst(bomBytes.count)
        }
        let payload = Data(bytes)
        let usedFallback: Bool
        let text: String
        if let utf8 = String(data: payload, encoding: .utf8) {
            text = utf8
            usedFallback = false
        } else {
            text = MediaInfoReader.decodeLossyPlainText(payload)
            usedFallback = true
        }
        return PlaylistTextFile(hasBOM: hasBOM, lines: splitLines(text),
                                usedEncodingFallback: usedFallback)
    }

    /// Zerlegt an "\n"; ein "\r" direkt davor gehört zum Zeilenende. Ein
    /// einzelnes "\r" (klassisches Mac OS) zählt nicht als Zeilenende.
    static func splitLines(_ text: String) -> [PlaylistTextLine] {
        var lines: [PlaylistTextLine] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if current.hasSuffix("\r") {
                    current.removeLast()
                    lines.append(PlaylistTextLine(text: current, ending: "\r\n"))
                } else {
                    lines.append(PlaylistTextLine(text: current, ending: "\n"))
                }
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty {
            lines.append(PlaylistTextLine(text: current, ending: ""))
        }
        return lines
    }

    /// Das vorherrschende Zeilenende — für neu eingefügte Zeilen.
    var dominantEnding: String {
        let crlf = lines.filter { $0.ending == "\r\n" }.count
        let lf = lines.filter { $0.ending == "\n" }.count
        return crlf > lf ? "\r\n" : "\n"
    }

    /// Fügt eine Zeile an Position `index` ein (Ende = anhängen). Hat die
    /// bisher letzte Zeile kein Zeilenende, bekommt sie eines, damit die neue
    /// Zeile nicht an sie klebt.
    mutating func insert(_ text: String, at index: Int) {
        let ending = dominantEnding
        if index >= lines.count {
            if let last = lines.indices.last, lines[last].ending.isEmpty {
                lines[last].ending = ending
            }
            lines.append(PlaylistTextLine(text: text, ending: ending))
        } else {
            lines.insert(PlaylistTextLine(text: text, ending: ending), at: index)
        }
    }

    /// Ersetzt den Text einer Zeile; das Zeilenende bleibt.
    mutating func replace(_ text: String, at index: Int) {
        lines[index].text = text
    }

    /// Entfernt eine Zeile. War sie die letzte ohne Zeilenende, verliert die
    /// neue letzte Zeile ihr Zeilenende, damit die Datei nicht länger wird.
    mutating func remove(at index: Int) {
        let removed = lines.remove(at: index)
        if removed.ending.isEmpty, let last = lines.indices.last {
            lines[last].ending = ""
        }
    }

    /// Serialisiert als UTF-8 (BOM, falls vorhanden, bleibt).
    func serialize() -> Data {
        var output = Data()
        if hasBOM { output.append(contentsOf: Self.bomBytes) }
        for line in lines {
            output.append(Data(line.text.utf8))
            output.append(Data(line.ending.utf8))
        }
        return output
    }

    func write(to url: URL) throws {
        do {
            try serialize().write(to: url)
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
    }

    /// Führende Leerzeichen/Tabs einer Zeile (für gleich eingerückte Einfügungen).
    static func indentation(of text: String) -> String {
        String(text.prefix { $0 == " " || $0 == "\t" })
    }
}

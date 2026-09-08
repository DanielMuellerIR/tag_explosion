// PLS-Playlist: INI-artig mit Abschnitt `[playlist]` und je Eintrag
// `FileN=<Pfad>`, `TitleN=<Text>`, `LengthN=<Sekunden>` (-1 = unbekannt),
// dazu `NumberOfEntries=` und `Version=2`. Schlüssel sind nicht
// case-sensitiv. Einen Titel für die ganze Liste kennt PLS nicht.
//
// Bearbeitbar ist der Eintragstitel (TitleN). Fehlt die Zeile, entsteht sie
// direkt hinter der FileN-Zeile; ein leerer Wert entfernt sie.
import Foundation

enum PLSPlaylistFile: PlaylistBackend {

    static let supportedFields: Set<PlaylistField> = [.entryTitle]

    struct Item {
        var number: Int
        var fileLine: Int
        var titleLine: Int?
        var title = ""
        var seconds: Double?
    }

    /// `TitleN=…` → (schlüssel: "TITLE", nummer: N, wert)
    static func keyValue(of text: String) -> (key: String, number: Int?, value: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("["), !trimmed.hasPrefix(";"),
              !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let rawKey = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        let digits = rawKey.reversed().prefix { $0.isNumber }
        let number = digits.isEmpty ? nil : Int(String(digits.reversed()))
        let key = String(rawKey.dropLast(digits.count)).uppercased()
        return (key, number, value)
    }

    /// Nur der Abschnitt [playlist] besitzt PLS-Felder. Gleichnamige
    /// Schlüssel fremder Abschnitte bleiben beim Lesen und Schreiben fremd.
    private static func playlistLines(in file: PlaylistTextFile) -> [(index: Int, text: String)] {
        var active = false
        var result: [(index: Int, text: String)] = []
        for (index, line) in file.lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                active = trimmed.lowercased() == "[playlist]"
            } else if active {
                result.append((index, line.text))
            }
        }
        return result
    }

    /// Einträge nach ihrer Nummer sortiert (so spielen Player sie ab).
    static func parse(_ file: PlaylistTextFile) -> [Item] {
        var items: [Int: Item] = [:]
        var titles: [Int: (line: Int, value: String)] = [:]
        var lengths: [Int: Double] = [:]
        for (index, text) in playlistLines(in: file) {
            guard let (key, number, value) = keyValue(of: text), let number else { continue }
            switch key {
            case "FILE": items[number] = Item(number: number, fileLine: index)
            case "TITLE": titles[number] = (index, value)
            case "LENGTH": lengths[number] = PlaylistTool.parseSeconds(value)
            default: break
            }
        }
        return items.keys.sorted().map { number in
            var item = items[number]!
            item.titleLine = titles[number]?.line
            item.title = titles[number]?.value ?? ""
            item.seconds = lengths[number]
            return item
        }
    }

    // MARK: - Lesen

    static func read(url: URL, base: URL) throws -> PlaylistContents {
        let file = try PlaylistTextFile.load(url: url)
        guard file.lines.contains(where: {
            $0.text.trimmingCharacters(in: .whitespaces).lowercased() == "[playlist]"
        }) else { throw TagError.cannotOpen(path: url.path) }
        let items = parse(file)
        var entries: [PlaylistEntry] = []
        for item in items {
            let location = keyValue(of: file.lines[item.fileLine].text)?.value ?? ""
            entries.append(PlaylistTool.makeEntry(
                number: item.number, location: location, base: base, title: item.title,
                performer: "", durationMilliseconds: item.seconds.map(PlaylistTool.milliseconds(fromSeconds:))))
        }
        var info: [DocumentInfoItem] = []
        for (_, text) in playlistLines(in: file) {
            guard let (key, number, value) = keyValue(of: text), number == nil else { continue }
            if key == "NUMBEROFENTRIES" || key == "VERSION" {
                info.append(DocumentInfoItem(label: key == "VERSION" ? "Version" : "NumberOfEntries",
                                             value: value))
            }
        }
        return PlaylistContents(format: .pls,
                                fields: PlaylistCoreFields(entries: entries.map(\.fields)),
                                entries: entries, info: info,
                                usedEncodingFallback: file.usedEncodingFallback)
    }

    // MARK: - Schreiben

    static func validate(_ fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {}

    static func mutate(url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {
        var file = try PlaylistTextFile.load(url: url)
        let items = parse(file)
        guard items.count == fields.entries.count else { throw TagError.saveFailed(path: url.path) }
        let edits: [PlaylistTextFile.Edit] = fields.entries.indices.compactMap { index in
            let entry = fields.entries[index]
            guard entry.title != original.entries[index].title else { return nil }
            let item = items[index]
            let text = "Title\(item.number)=\(entry.title)"
            if let line = item.titleLine {
                return entry.title.isEmpty ? .remove(line) : .replace(line, text)
            }
            return entry.title.isEmpty ? nil : .insert(item.fileLine + 1, text)
        }
        file.apply(edits)
        try file.write(to: url)
    }
}

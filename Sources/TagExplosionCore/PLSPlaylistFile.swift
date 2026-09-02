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

    /// Einträge nach ihrer Nummer sortiert (so spielen Player sie ab).
    static func parse(_ file: PlaylistTextFile) -> [Item] {
        var items: [Int: Item] = [:]
        var titles: [Int: (line: Int, value: String)] = [:]
        var lengths: [Int: Double] = [:]
        for (index, line) in file.lines.enumerated() {
            guard let (key, number, value) = keyValue(of: line.text), let number else { continue }
            switch key {
            case "FILE": items[number] = Item(number: number, fileLine: index)
            case "TITLE": titles[number] = (index, value)
            case "LENGTH": lengths[number] = Double(value).flatMap { $0 >= 0 ? $0 : nil }
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
                performer: "", durationMilliseconds: item.seconds.map { Int(($0 * 1000).rounded()) }))
        }
        var info: [DocumentInfoItem] = []
        for line in file.lines {
            guard let (key, number, value) = keyValue(of: line.text), number == nil else { continue }
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
        for (index, entry) in fields.entries.enumerated()
        where entry.title != original.entries[index].title {
            let items = parse(file)
            guard index < items.count else { continue }
            let item = items[index]
            if let titleLine = item.titleLine {
                if entry.title.isEmpty {
                    file.remove(at: titleLine)
                } else {
                    file.replace("Title\(item.number)=\(entry.title)", at: titleLine)
                }
            } else if !entry.title.isEmpty {
                file.insert("Title\(item.number)=\(entry.title)", at: item.fileLine + 1)
            }
        }
        try file.write(to: url)
    }
}

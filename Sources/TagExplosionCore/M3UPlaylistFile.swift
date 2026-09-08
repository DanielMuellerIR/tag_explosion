// M3U/M3U8-Playlist: eine Pfadzeile je Eintrag, davor optional
// `#EXTINF:<Sekunden>,<Anzeigetext>` (Extended M3U, Kopfzeile `#EXTM3U`)
// und `#PLAYLIST:<Titel>` für den Namen der Liste. Andere `#`-Zeilen sind
// Kommentare oder fremde Erweiterungen und bleiben unverändert.
//
// Der EXTINF-Anzeigetext ist üblicherweise „Interpret - Titel", aber ohne
// verlässliche Trennregel (ein Titel kann selbst „ - " enthalten). Deshalb
// wird der Text als GANZES als Eintragstitel geführt; ein getrennter
// Interpret hat in M3U keinen Speicherort. Der Exporter schreibt
// „Interpret - Titel" in genau dieser Form.
import Foundation

enum M3UPlaylistFile: PlaylistBackend {

    static let supportedFields: Set<PlaylistField> = [.title, .entryTitle]

    /// Ein Eintrag: Pfadzeile plus zugehörige EXTINF-Zeile (falls vorhanden).
    struct Item {
        var locationLine: Int
        var extinfLine: Int?
        var seconds: Double?
        var text: String
    }

    struct Parsed {
        var items: [Item] = []
        var playlistLine: Int?
        var title = ""
        var hasHeader = false
    }

    static func parse(_ file: PlaylistTextFile) -> Parsed {
        var parsed = Parsed()
        var pendingExtinf: (line: Int, seconds: Double?, text: String)?
        for (index, line) in file.lines.enumerated() {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            if text.hasPrefix("#") {
                let upper = text.uppercased()
                if upper.hasPrefix("#EXTM3U") {
                    parsed.hasHeader = true
                } else if upper.hasPrefix("#PLAYLIST:") {
                    parsed.playlistLine = index
                    parsed.title = String(text.dropFirst("#PLAYLIST:".count))
                        .trimmingCharacters(in: .whitespaces)
                } else if upper.hasPrefix("#EXTINF:") {
                    let body = String(text.dropFirst("#EXTINF:".count))
                    // "<Sekunden>[ attr=…],<Text>" — die Sekunden bis zum
                    // ersten Komma; -1 = unbekannt.
                    let comma = body.firstIndex(of: ",")
                    let durationPart = comma.map { String(body[..<$0]) } ?? body
                    let display = comma.map { String(body[body.index(after: $0)...]) } ?? ""
                    let secondsToken = durationPart.split(separator: " ").first.map(String.init) ?? ""
                    let seconds = PlaylistTool.parseSeconds(secondsToken)
                    pendingExtinf = (index, seconds, display.trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            parsed.items.append(Item(locationLine: index, extinfLine: pendingExtinf?.line,
                                     seconds: pendingExtinf?.seconds, text: pendingExtinf?.text ?? ""))
            pendingExtinf = nil
        }
        return parsed
    }

    // MARK: - Lesen

    static func read(url: URL, base: URL) throws -> PlaylistContents {
        let file = try PlaylistTextFile.load(url: url)
        let parsed = parse(file)
        var entries: [PlaylistEntry] = []
        for (offset, item) in parsed.items.enumerated() {
            let location = file.lines[item.locationLine].text.trimmingCharacters(in: .whitespaces)
            entries.append(PlaylistTool.makeEntry(
                number: offset + 1, location: location, base: base, title: item.text,
                performer: "", durationMilliseconds: item.seconds.map(PlaylistTool.milliseconds(fromSeconds:))))
        }
        let fields = PlaylistCoreFields(title: parsed.title, entries: entries.map(\.fields))
        let format: PlaylistFormat = url.pathExtension.lowercased() == "m3u8" ? .m3u8 : .m3u
        let info = [DocumentInfoItem(label: "extended", value: parsed.hasHeader ? "yes" : "no")]
        return PlaylistContents(format: format, fields: fields, entries: entries, info: info,
                                usedEncodingFallback: file.usedEncodingFallback)
    }

    // MARK: - Schreiben

    static func validate(_ fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {}

    static func mutate(url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields) throws {
        var file = try PlaylistTextFile.load(url: url)
        if fields.title != original.title {
            setTitle(&file, fields.title)
        }
        let changed = fields.entries.indices.filter { fields.entries[$0].title != original.entries[$0].title }
        var parsed = parse(file)
        guard parsed.items.count == fields.entries.count else { throw TagError.saveFailed(path: url.path) }
        if !parsed.hasHeader, changed.contains(where: {
            parsed.items[$0].extinfLine == nil && !fields.entries[$0].title.isEmpty
        }) {
            _ = ensureHeader(&file)
            parsed = parse(file)
        }
        let edits: [PlaylistTextFile.Edit] = changed.compactMap { index in
            let item = parsed.items[index]
            let text = fields.entries[index].title
            guard let lineIndex = item.extinfLine else {
                return text.isEmpty ? nil : .insert(item.locationLine, "#EXTINF:-1,\(text)")
            }
            let line = file.lines[lineIndex].text
            // Sekunden und fremde Attribute vor dem Komma bleiben erhalten.
            let prefix = line.firstIndex(of: ",").map { String(line[...$0]) } ?? (line + ",")
            return .replace(lineIndex, prefix + text)
        }
        file.apply(edits)
        try file.write(to: url)
    }

    /// Sorgt für die `#EXTM3U`-Kopfzeile, ohne die ein Player die
    /// Erweiterungszeilen ignorieren darf. Liefert die Zeile hinter dem Kopf.
    private static func ensureHeader(_ file: inout PlaylistTextFile) -> Int {
        if let index = file.lines.firstIndex(where: {
            $0.text.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("#EXTM3U")
        }) {
            return index + 1
        }
        file.insert("#EXTM3U", at: 0)
        return 1
    }

    private static func setTitle(_ file: inout PlaylistTextFile, _ title: String) {
        let parsed = parse(file)
        if let index = parsed.playlistLine {
            if title.isEmpty {
                file.remove(at: index)
            } else {
                file.replace("#PLAYLIST:\(title)", at: index)
            }
            return
        }
        guard !title.isEmpty else { return }
        let position = ensureHeader(&file)
        file.insert("#PLAYLIST:\(title)", at: position)
    }

}

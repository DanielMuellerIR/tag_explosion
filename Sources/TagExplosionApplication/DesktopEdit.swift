import TagExplosionCore

/// Vollständig gelesener Editorauftrag. Die Übernahme kann nicht mehr werfen.
@MainActor
enum DesktopEdit {
    case audio(properties: [TagProperty], chapters: [Chapter], lyrics: [SyncedLyricLine],
               language: String, nfo: NFOFields?)
    case image(ImageCoreFields)
    case ebook(EbookCoreFields)
    case document(DocumentCoreFields)
    case nfo(NFOFields)
    case subtitle(SubtitleEditableFields)
    case playlist(PlaylistCoreFields)

    static func prepare(_ entry: FileEntry, values: DesktopValue) throws -> Self {
        try requireEditable(entry)
        switch entry.kind {
        case .audio:
            return try audio(
                entry, properties: values["properties"].decode([TagProperty].self),
                chapters: values["chapters"].decode([Chapter].self),
                lyrics: values["syncedLyrics"].decode([SyncedLyricLine].self),
                language: values["lyricsLanguage"].text,
                nfo: values["videoNFO"] == .null ? nil : values["videoNFO"].decode(NFOFields.self))
        default:
            return try fields(for: entry, values: values["fields"], partial: false)
        }
    }

    static func prepareBatch(_ entries: [FileEntry], changes: DesktopValue) throws -> [Self] {
        if entries.first?.kind == .audio {
            let changes = try changes.decode([String: [String]].self)
            return try entries.map { entry in
                try requireEditable(entry)
                var properties = entry.properties
                TagRuleFields.apply(changes, to: &properties)
                return try audio(entry, properties: properties, chapters: entry.chapters,
                                 lyrics: entry.syncedLyrics, language: entry.lyricsLanguage, nfo: nil)
            }
        }
        return try entries.map { entry in
            try requireEditable(entry)
            return try fields(for: entry, values: changes, partial: true)
        }
    }

    private static func fields(for entry: FileEntry, values: DesktopValue, partial: Bool) throws -> Self {
        func decode<T: Codable>(_ existing: T, optional: Set<String> = []) throws -> T {
            if partial { return try overlay(existing, with: values, optional: optional) }
            return try values.decode(T.self)
        }
        switch entry.kind {
        case .image: return .image(try decode(entry.imageFields, optional: ["rating"]))
        case .ebook: return .ebook(try decode(entry.ebookFields))
        case .document: return .document(try decode(entry.documentFields))
        case .playlist: return .playlist(try decode(entry.playlistFields))
        case .sidecar:
            switch entry.sidecarContents {
            case .nfo: return .nfo(try decode(entry.nfoFields))
            case .subtitle: return .subtitle(try decode(entry.subtitleFields))
            case nil: throw DesktopFailure("read_only", String(localized: "Die Datei enthält keine bearbeitbaren Metadaten."))
            }
        case .audio, .invoice: throw DesktopFailure("read_only", String(localized: "Die Datei ist schreibgeschützt."))
        }
    }

    func apply(to entry: FileEntry) {
        switch self {
        case .audio(let properties, let chapters, let lyrics, let language, let nfo):
            entry.properties = properties
            entry.chapters = chapters
            entry.syncedLyrics = lyrics
            entry.lyricsLanguage = language
            if let nfo { entry.videoNFOFields = nfo }
        case .image(let fields): entry.imageFields = fields
        case .ebook(let fields): entry.ebookFields = fields
        case .document(let fields): entry.documentFields = fields
        case .nfo(let fields): entry.nfoFields = fields
        case .subtitle(let fields): entry.subtitleFields = fields
        case .playlist(let fields): entry.playlistFields = fields
        }
    }

    private static func requireEditable(_ entry: FileEntry) throws {
        guard entry.kind != .invoice, !entry.isReadOnly || entry.videoNFO?.isEditable == true else {
            throw DesktopFailure("read_only", String(localized: "Die Datei ist schreibgeschützt."))
        }
    }

    private static func audio(_ entry: FileEntry, properties: [TagProperty], chapters: [Chapter],
                              lyrics: [SyncedLyricLine], language: String?, nfo: NFOFields?) throws -> Self {
        if entry.isReadOnly {
            guard properties == entry.properties, chapters == entry.chapters, lyrics == entry.syncedLyrics,
                  language == entry.lyricsLanguage else {
                throw DesktopFailure("read_only", String(localized: "Bearbeitbar ist nur die NFO-Datei neben der schreibgeschützten Mediendatei."))
            }
        }
        return .audio(properties: properties, chapters: chapters, lyrics: lyrics,
                      language: language ?? entry.lyricsLanguage, nfo: nfo)
    }

    // Der IPC-Auftrag enthält offene Feldschlüssel. Codable bleibt für diesen
    // kleinen Teil des Vertrags die einzige Zuordnung der Schlüsselnamen.
    private static func overlay<Fields: Codable>(_ fields: Fields, with changes: DesktopValue,
                                                  optional: Set<String> = []) throws -> Fields {
        var result = try DesktopValue.encoding(fields).fields
        for (key, value) in changes.fields where result[key] != nil || optional.contains(key) {
            result[key] = value
        }
        return try DesktopValue.object(result).decode(Fields.self)
    }
}

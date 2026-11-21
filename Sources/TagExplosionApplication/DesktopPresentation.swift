import Foundation
import TagExplosionCore

@MainActor
enum DesktopPresentation {
    static func batchInfo(_ entries: [FileEntry], preferSidecar: Bool) throws -> DesktopValue {
        guard let first = entries.first, entries.allSatisfy({ $0.kind == first.kind }) else {
            throw DesktopFailure("mixed_selection", String(localized: "Wählen Sie Dateien desselben Typs."))
        }
        let fields = try entries.map { entry -> [String: DesktopValue] in
            if entry.kind == .audio {
                return TagProperty.valuesByKey(entry.properties).mapValues { .array($0.map(DesktopValue.string)) }
            }
            return try editableFields(entry)?.fields ?? [:]
        }
        let keys = Set(fields.flatMap { $0.keys }).union(first.kind == .image ? ["rating"] : [])
        let absent: DesktopValue = first.kind == .audio ? .array([]) : .null
        var common: [String: DesktopValue] = [:]
        var mixed: [String] = []
        for key in keys.sorted() {
            let value = fields[0][key] ?? absent
            if fields.dropFirst().allSatisfy({ ($0[key] ?? absent) == value }) {
                common[key] = value
            } else {
                mixed.append(key)
            }
        }
        let restrictions = entries.compactMap { MediaFormats.writableTagKeys(for: $0.url) }
        let writable = restrictions.first.map { initial in
            restrictions.dropFirst().reduce(initial) { $0.intersection($1) }
        }
        var supported = first.kind == .audio ? [] : Set(fields[0].keys)
        if first.kind == .image { supported.insert("rating") }
        for entry in entries {
            if let fields = supportedFields(entry) { supported.formIntersection(fields) }
        }
        if first.kind == .ebook, entries.contains(where: { !EbookTool.supportsSeries(url: $0.url) }) {
            supported.subtract(["series", "seriesIndex"])
        }
        let supportsR128 = entries.allSatisfy { FixedFields.supportsR128($0.url) }
        let loudness = entries.allSatisfy { FixedFields.supportsLoudness($0.url) }
            ? FixedFields.loudnessKeys.filter { supportsR128 || ![FixedFields.r128TrackGain, FixedFields.r128AlbumGain].contains($0) }
            : []
        return .object([
            "first": try describe(first, preferSidecar: preferSidecar),
            "common": .object(common),
            "mixed": try .encoding(mixed),
            "sourceKeys": try .encoding(keys.sorted()),
            "writableKeys": try .encoding(writable?.sorted()),
            "supportedFields": try .encoding(supported.sorted()),
            "readOnly": .bool(entries.contains(where: readOnly)),
            "loudnessKeys": try .encoding(loudness),
        ])
    }

    static func describe(_ entry: FileEntry, preferSidecar: Bool) throws -> DesktopValue {
        var result: [String: DesktopValue] = [
            "path": .string(entry.url.path),
            "kind": .string(entry.kind.rawValue),
            "title": .string(entry.displayTitle),
            "dirty": .bool(entry.isDirty),
            "readOnly": .bool(readOnly(entry)),
            "supportsChapters": .bool(entry.supportsChapters),
            "supportsSyncedLyrics": .bool(entry.supportsSyncedLyrics),
            "supportsFilenamePatterns": .bool(entry.supportsFilenamePatterns),
        ]
        result["fields"] = try editableFields(entry)
        if let fields = supportedFields(entry) { result["supportedFields"] = try .encoding(fields) }
        switch entry.kind {
        case .audio:
            result["properties"] = try .encoding(entry.properties)
            result["writableKeys"] = try .encoding(MediaFormats.writableTagKeys(for: entry.url)?.sorted())
            result["supportsLyrics"] = .bool(FixedFields.supportsLyrics(entry.url))
            result["supportsLoudness"] = .bool(FixedFields.supportsLoudness(entry.url))
            result["supportsPodcast"] = .bool(FixedFields.supportsPodcast(entry.url))
            result["loudnessKeys"] = try .encoding(FixedFields.loudnessKeys.sorted())
            result["podcastKeys"] = try .encoding(FixedFields.podcastKeys.sorted())
            result["artworks"] = .array(entry.artworks.enumerated().map { describeArtwork($0.offset, $0.element) })
            result["audio"] = try .encoding(entry.audio)
            result["chapters"] = try .encoding(entry.chapters)
            result["lyricsLanguage"] = .string(entry.lyricsLanguage)
            result["syncedLyrics"] = try .encoding(entry.syncedLyrics)
            result["layers"] = try .encoding(entry.layers)
            if entry.videoNFO?.isEditable == true { result["videoNFO"] = try .encoding(entry.videoNFOFields) }
        case .image:
            let destination = ExifTool.writeDestination(for: entry.url, preferSidecar: preferSidecar)
            result["writeDestination"] = destination.isSidecar ? .string(ImagePresentation.destinationText(destination)) : .null
            result["ratingOptions"] = .array(RatingPicker.options(current: entry.imageFields.rating).map { option in
                .object(["value": option.value.map { .number(Double($0)) } ?? .null, "label": .string(option.label)])
            })
            result["sidecarFields"] = try .encoding(entry.imageReading.sidecarFields.map(\.rawValue))
            result["sidecar"] = entry.imageReading.sidecarURL.map { .string($0.path) } ?? .null
        case .ebook:
            result["supportsSeries"] = .bool(EbookTool.supportsSeries(url: entry.url))
            result["supportsCover"] = .bool(EbookTool.supportsCover(url: entry.url))
            result["hasCover"] = .bool((entry.ebookCoverReplacement ?? entry.ebookOriginalCover) != nil)
        case .document:
            result["info"] = try .encoding(entry.documentInfo)
            result["hasCover"] = .bool(entry.documentCover != nil)
        case .invoice:
            result["invoice"] = try .encoding(entry.invoiceDocument)
        case .sidecar:
            switch entry.sidecarContents {
            case .nfo(let contents):
                result["subkind"] = .string("nfo")
                result["info"] = try .encoding(contents.info)
                result["urls"] = try .encoding(contents.urls)
            case .subtitle(let contents):
                result["subkind"] = .string("subtitle")
                result["info"] = try .encoding(contents.info)
            case nil: break
            }
        case .playlist:
            result["playlist"] = try .encoding(entry.playlistContents)
        }
        return .object(result)
    }

    private static func describeArtwork(_ index: Int, _ artwork: Artwork) -> DesktopValue {
        let analysis = CoverTools.analyze(artwork.data)
        return .object([
            "index": .number(Double(index)),
            "mimeType": .string(artwork.resolvedMimeType),
            "pictureType": .string(artwork.pictureType),
            "description": .string(artwork.description),
            "analysis": (try? .encoding(analysis)) ?? .null,
            "summary": .string(analysis.summary),
            "issues": .array(analysis.issues.map { .string(CoverToolActions.issueText($0.code)) }),
        ])
    }

    private static func editableFields(_ entry: FileEntry) throws -> DesktopValue? {
        switch entry.kind {
        case .audio, .invoice: nil
        case .image: try .encoding(entry.imageFields)
        case .ebook: try .encoding(entry.ebookFields)
        case .document: try .encoding(entry.documentFields)
        case .playlist: try .encoding(entry.playlistFields)
        case .sidecar:
            switch entry.sidecarContents {
            case .nfo: try .encoding(entry.nfoFields)
            case .subtitle: try .encoding(entry.subtitleFields)
            case nil: nil
            }
        }
    }

    private static func supportedFields(_ entry: FileEntry) -> [String]? {
        switch entry.kind {
        case .document: return DocumentTool.supportedFields(url: entry.url).map(\.rawValue)
        case .playlist: return PlaylistTool.supportedFields(url: entry.url).map(\.rawValue)
        case .sidecar:
            if case .subtitle(let contents) = entry.sidecarContents {
                return contents.info.format == .vtt ? ["title", "language"] : []
            }
            return nil
        default: return nil
        }
    }

    private static func readOnly(_ entry: FileEntry) -> Bool {
        if entry.kind == .invoice || entry.isReadOnly { return true }
        if case .nfo(let contents) = entry.sidecarContents { return contents.isURLOnly }
        return false
    }
}

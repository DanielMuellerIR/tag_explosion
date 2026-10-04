import Foundation
import TagExplosionCore

public struct MetadataPreview: Sendable {
    public let fileName: String
    public let rows: [(String, String)]
    public let cover: Artwork?

    public init(fileName: String, rows: [(String, String)], cover: Artwork? = nil) {
        self.fileName = fileName
        self.rows = rows
        self.cover = cover
    }

    // Die Erweiterung liest ausschließlich native Backends: Fremde CLI-Tools
    // sind im Quick-Look-Sandboxprozess weder verfügbar noch erforderlich.
    public static func read(url: URL) throws -> MetadataPreview {
        if url.pathExtension.lowercased() == "epub" {
            let contents = try EbookTool.readSnapshot(url: url, includeCover: true).value
            let f = contents.fields
            return MetadataPreview(fileName: url.lastPathComponent, rows: [
                ("TITLE", f.title), ("AUTHOR", f.authors.joined(separator: "; ")),
                ("SERIES", f.series), ("SERIESINDEX", f.seriesIndex), ("DESCRIPTION", f.description),
                ("ISBN", f.isbn), ("PUBLISHER", f.publisher), ("LANGUAGE", f.language),
                ("DATE", f.date), ("SUBJECT", f.subjects.joined(separator: "; ")),
            ].filter { !$0.1.isEmpty }, cover: contents.cover)
        }
        let data = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }.value
        var rows = data.properties.map { ($0.key, $0.value) }
        if let audio = data.audio {
            rows += [("DURATION", String(format: "%.3f s", Double(audio.lengthMilliseconds) / 1000)),
                     ("BITRATE", "\(audio.bitrateKbps) kbit/s"),
                     ("SAMPLE RATE", "\(audio.sampleRateHz) Hz"), ("CHANNELS", "\(audio.channels)")]
        }
        for chapter in data.chapters {
            rows.append(("CHAPTER", "\(chapter.startMilliseconds) ms · \(chapter.title)"))
        }
        return MetadataPreview(fileName: url.lastPathComponent, rows: rows,
            cover: data.artworks.first(where: { $0.pictureType == "Front Cover" }) ?? data.artworks.first)
    }

}

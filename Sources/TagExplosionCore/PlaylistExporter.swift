// Playlist aus einer Dateiauswahl erzeugen (m3u, m3u8, pls, xspf). Titel,
// Interpret, Album und Spielzeit kommen aus den Tags und den TagLib-
// Audioeigenschaften; Dateien ohne lesbare Tags erscheinen mit ihrem
// Dateinamen und ohne Dauer. Pfade sind relativ zur Playlist-Datei, auf
// Wunsch absolut. Cue-Sheets werden nicht exportiert (sie beschreiben ein
// Image, keine Dateiliste).
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum PlaylistExporter {

    /// Ein Eintrag der zu schreibenden Liste.
    public struct Item: Sendable, Equatable {
        public var url: URL
        public var title: String
        public var artist: String
        public var album: String
        public var durationMilliseconds: Int?
        /// Tags konnten nicht gelesen werden (Titel = Dateiname).
        public var untagged: Bool

        public init(url: URL, title: String, artist: String = "", album: String = "",
                    durationMilliseconds: Int? = nil, untagged: Bool = false) {
            self.url = url
            self.title = title
            self.artist = artist
            self.album = album
            self.durationMilliseconds = durationMilliseconds
            self.untagged = untagged
        }
    }

    public struct Summary: Sendable, Equatable {
        public var playlist: URL
        public var count: Int
        /// Dateien, deren Tags nicht lesbar waren.
        public var untagged: [URL]
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case unsupportedFormat(PlaylistFormat)
        case outputExists(String)
        case nothingToExport

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "Playlists cannot be exported as .\(format.rawValue) (use m3u, m3u8, pls or xspf)"
            case .outputExists(let path):
                return "Output file already exists: \(path)"
            case .nothingToExport:
                return "No files to export"
            }
        }
    }

    // MARK: - Sammeln

    /// Liest Titel, Interpret, Album und Spielzeit jeder Datei.
    public static func collect(files: [URL]) -> [Item] {
        files.map { url in
            guard let data = try? TagFile.read(at: url) else {
                return Item(url: url, title: url.deletingPathExtension().lastPathComponent,
                            untagged: true)
            }
            let title = data.firstValue(for: "TITLE") ?? ""
            return Item(
                url: url,
                title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                artist: data.firstValue(for: "ARTIST") ?? "",
                album: data.firstValue(for: "ALBUM") ?? "",
                durationMilliseconds: data.audio?.lengthMilliseconds)
        }
    }

    // MARK: - Rendern

    /// Pfad eines Eintrags, wie er in der Playlist steht.
    static func location(of url: URL, playlist: URL, absolute: Bool, asURI: Bool) -> String {
        if absolute {
            let canonical = url.standardizedFileURL
            return asURI ? canonical.absoluteString : canonical.path
        }
        let relative = TagArchiveIO.relativePath(of: url, to: playlist.deletingLastPathComponent())
        guard asURI else { return relative }
        // Relative URI: jedes Segment prozentkodiert, "/" bleibt Trenner.
        return relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed
                .subtracting(CharacterSet(charactersIn: "/;"))) ?? String($0) }
            .joined(separator: "/")
    }

    /// „Interpret - Titel" bzw. nur Titel.
    static func displayText(_ item: Item) -> String {
        item.artist.isEmpty ? item.title : "\(item.artist) - \(item.title)"
    }

    public static func render(items: [Item], format: PlaylistFormat, playlist: URL,
                              absolutePaths: Bool, title: String) throws -> Data {
        switch format {
        case .m3u, .m3u8:
            var lines = ["#EXTM3U"]
            if !title.isEmpty { lines.append("#PLAYLIST:\(title)") }
            for item in items {
                let seconds = item.durationMilliseconds.map { ($0 + 500) / 1000 } ?? -1
                lines.append("#EXTINF:\(seconds),\(displayText(item))")
                lines.append(location(of: item.url, playlist: playlist, absolute: absolutePaths, asURI: false))
            }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .pls:
            var lines = ["[playlist]"]
            for (offset, item) in items.enumerated() {
                let number = offset + 1
                lines.append("File\(number)=\(location(of: item.url, playlist: playlist, absolute: absolutePaths, asURI: false))")
                lines.append("Title\(number)=\(displayText(item))")
                lines.append("Length\(number)=\(item.durationMilliseconds.map { ($0 + 500) / 1000 } ?? -1)")
            }
            lines.append("NumberOfEntries=\(items.count)")
            lines.append("Version=2")
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .xspf:
            let root = XMLElement(name: "playlist")
            XMLTools.setAttribute(root, "version", "1")
            XMLTools.setAttribute(root, "xmlns", XSPFPlaylistFile.namespaceURI)
            if !title.isEmpty { root.addChild(XMLTools.element("title", prefix: "", value: title)) }
            let trackList = XMLElement(name: "trackList")
            for item in items {
                let track = XMLElement(name: "track")
                track.addChild(XMLTools.element(
                    "location", prefix: "",
                    value: location(of: item.url, playlist: playlist, absolute: absolutePaths, asURI: true)))
                track.addChild(XMLTools.element("title", prefix: "", value: item.title))
                if !item.artist.isEmpty {
                    track.addChild(XMLTools.element("creator", prefix: "", value: item.artist))
                }
                if !item.album.isEmpty {
                    track.addChild(XMLTools.element("album", prefix: "", value: item.album))
                }
                if let duration = item.durationMilliseconds {
                    track.addChild(XMLTools.element("duration", prefix: "", value: "\(duration)"))
                }
                trackList.addChild(track)
            }
            root.addChild(trackList)
            let document = XMLDocument(rootElement: root)
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
            return XMLTools.serialize(document)
        case .cue:
            throw ExportError.unsupportedFormat(format)
        }
    }

    // MARK: - Schreiben

    /// Erzeugt die Playlist-Datei. Auch ein Export ist ein Schreibweg: Ohne
    /// `overwrite` wird eine vorhandene Datei nie ersetzt (exklusives
    /// Anlegen, kein Zeitfenster zwischen Prüfung und Schreiben).
    @discardableResult
    public static func export(files: [URL], to playlist: URL, format: PlaylistFormat,
                              absolutePaths: Bool = false, title: String = "",
                              overwrite: Bool = false) throws -> Summary {
        guard format != .cue else { throw ExportError.unsupportedFormat(format) }
        guard !files.isEmpty else { throw ExportError.nothingToExport }
        let items = collect(files: files)
        let data = try render(items: items, format: format, playlist: playlist,
                              absolutePaths: absolutePaths, title: title)
        do {
            try data.write(to: playlist, options: overwrite ? .atomic : .withoutOverwriting)
        } catch where !overwrite && FileManager.default.fileExists(atPath: playlist.path) {
            throw ExportError.outputExists(playlist.path)
        } catch {
            throw TagError.saveFailed(path: playlist.path)
        }
        return Summary(playlist: playlist, count: items.count,
                       untagged: items.filter(\.untagged).map(\.url))
    }
}

// tagx nfo — Kodi-/Jellyfin-NFO anzeigen und setzen. Schreibt nur die NFO,
// nie das Video daneben; eine Nur-URL-NFO wird angezeigt und abgelehnt.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Nfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nfo",
        abstract: "Show and edit Kodi/Jellyfin .nfo sidecars (movie, episodedetails, tvshow, musicvideo, album, artist).",
        subcommands: [NfoShow.self, NfoSet.self],
        defaultSubcommand: NfoShow.self
    )
}

/// `.nfo` direkt oder das Video daneben (`film.mkv` → `film.nfo`).
func resolveNFO(_ path: String) throws -> URL {
    let url = try resolveFile(path)
    if SidecarTool.isNFO(url) { return url }
    guard let nfo = MediaFormats.nfoURL(forVideo: url) else {
        throw ValidationError("No .nfo sidecar next to: \(path)")
    }
    return nfo
}

struct NfoShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show NFO fields and display-only entries (actors, ids, artwork).")

    @Argument(help: "NFO file or the video next to it") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var file: String
        /// Wurzelelement; nil bei einer Nur-URL-NFO.
        var type: String?
        var urlOnly: Bool
        var fields: NFOFields
        var info: [DocumentInfoItem]
        var urls: [String]
        /// Video neben der NFO (nil = keines).
        var video: String?
    }

    func run() throws {
        let url = try resolveNFO(file)
        let contents = try KodiNFOFile.readSnapshot(url: url).value
        let video = MediaFormats.videoURL(forNFO: url)?.path
        if json {
            try printJSON(Report(file: url.path, type: contents.rootName, urlOnly: contents.isURLOnly,
                                 fields: contents.fields, info: contents.info, urls: contents.urls,
                                 video: video))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        if contents.isURLOnly {
            print("# url-only NFO (read-only)")
        }
        let f = contents.fields
        line("TITLE", f.title)
        line("ORIGINALTITLE", f.originalTitle)
        line("SORTTITLE", f.sortTitle)
        line("YEAR", f.year)
        line("PREMIERED", f.premiered)
        line("TAGLINE", f.tagline)
        line("OUTLINE", f.outline)
        line("PLOT", f.plot)
        line("GENRE", f.genres.joined(separator: ", "))
        line("TAG", f.tags.joined(separator: ", "))
        line("STUDIO", f.studio)
        line("DIRECTOR", f.directors.joined(separator: ", "))
        line("CREDITS", f.credits)
        line("RATING", f.rating)
        line("USERRATING", f.userRating)
        line("MPAA", f.mpaa)
        line("RUNTIME", f.runtime)
        line("SHOWTITLE", f.showTitle)
        line("SEASON", f.season)
        line("EPISODE", f.episode)
        for item in contents.info {
            print("INFO.\(item.label)=\(item.value)")
        }
    }
}

struct NfoSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set NFO fields (an empty value deletes the element). Only the .nfo is written, never the video.")

    @Argument(help: "NFO file or the video next to it") var file: String
    @Option(help: "Title") var title: String?
    @Option(name: .customLong("original-title"), help: "Original title") var originalTitle: String?
    @Option(name: .customLong("sort-title"), help: "Sort title") var sortTitle: String?
    @Option(help: "Year (four digits)") var year: String?
    @Option(help: "Premiere/air date (YYYY-MM-DD)") var premiered: String?
    @Option(help: "Plot") var plot: String?
    @Option(help: "Outline (short plot)") var outline: String?
    @Option(help: "Tagline") var tagline: String?
    @Option(help: "Genres, comma-separated") var genre: String?
    @Option(help: "Tags, comma-separated") var tag: String?
    @Option(help: "Studio") var studio: String?
    @Option(help: "Director(s), comma-separated") var director: String?
    @Option(help: "Writer (credits)") var credits: String?
    @Option(help: "Rating 0-10, e.g. 7.5") var rating: String?
    @Option(name: .customLong("user-rating"), help: "User rating") var userRating: String?
    @Option(help: "Age rating (mpaa), e.g. 'FSK 12'") var mpaa: String?
    @Option(help: "Runtime in minutes") var runtime: String?
    @Option(help: "Season (episodes)") var season: String?
    @Option(help: "Episode number (episodes)") var episode: String?
    @Option(name: .customLong("show-title"), help: "Show title (episodes)") var showTitle: String?
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveNFO(file)
        let snapshot = try KodiNFOFile.readSnapshot(url: url)
        guard !snapshot.value.isURLOnly else {
            throw ValidationError(TagError.urlOnlyNFO(path: url.path).localizedDescription)
        }
        let original = snapshot.value.fields
        var fields = original
        if let title { fields.title = title }
        if let originalTitle { fields.originalTitle = originalTitle }
        if let sortTitle { fields.sortTitle = sortTitle }
        if let year { fields.year = year }
        if let premiered { fields.premiered = premiered }
        if let plot { fields.plot = plot }
        if let outline { fields.outline = outline }
        if let tagline { fields.tagline = tagline }
        if let genre { fields.genres = genre.splitCommaList() }
        if let tag { fields.tags = tag.splitCommaList() }
        if let studio { fields.studio = studio }
        if let director { fields.directors = director.splitCommaList() }
        if let credits { fields.credits = credits }
        if let rating { fields.rating = rating }
        if let userRating { fields.userRating = userRating }
        if let mpaa { fields.mpaa = mpaa }
        if let runtime { fields.runtime = runtime }
        if let season { fields.season = season }
        if let episode { fields.episode = episode }
        if let showTitle { fields.showTitle = showTitle }

        // Unbrauchbare Werte vor Sicherung und Schreibweg ablehnen.
        do {
            try KodiNFOFile.validate(fields, original: original)
        } catch TagError.invalidDocumentValue(let field, let reason) {
            throw ValidationError(TagError.invalidDocumentValue(field: field, reason: reason).localizedDescription)
        }
        guard fields != original else {
            try snapshot.requireCurrent(at: url)
            print("No changes")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url)
        try KodiNFOFile.write(url: url, fields: fields, original: original, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent)")
    }
}

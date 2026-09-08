// Datenmodell des Online-Lookups (MusicBrainz, Discogs, AcoustID).
//
// Alles hier sind reine Werttypen ohne Netzzugriff: Die Clients füllen sie,
// die Zuordnung (`TrackMatcher`) und der Änderungsplan (`LookupPlanner`)
// rechnen nur damit. So können App, CLI und Tests dieselben Strukturen nutzen.
import Foundation

/// Die drei Dienste, die `tagx lookup --source` und das App-Sheet kennen.
/// Die Roh-Werte sind zugleich die CLI-Schreibweise.
public enum LookupSource: String, Sendable, Codable, CaseIterable, Hashable {
    case musicbrainz
    case discogs
    /// AcoustID identifiziert eine Datei über ihren Audio-Fingerabdruck
    /// (`fpcalc`) und liefert MusicBrainz-Kennungen zurück.
    case acoustid

    /// Anzeigename, wie die Dienste sich selbst schreiben.
    public var displayName: String {
        switch self {
        case .musicbrainz: return "MusicBrainz"
        case .discogs: return "Discogs"
        case .acoustid: return "AcoustID"
        }
    }
}

/// Ein Titel aus der Trackliste eines Kandidaten.
public struct LookupTrack: Sendable, Codable, Equatable, Hashable {
    /// Nummer innerhalb des Mediums (1-basiert).
    public var number: Int
    /// Medium (CD 1, CD 2 …), 1-basiert.
    public var discNumber: Int
    public var title: String
    /// Spieldauer in Millisekunden; nil, wenn der Dienst keine liefert.
    public var durationMilliseconds: Int?
    /// Interpret dieses Titels, falls er vom Album-Interpreten abweicht.
    public var artist: String?
    /// MusicBrainz-Recording-ID (wird als MUSICBRAINZ_TRACKID geschrieben).
    public var recordingID: String?
    /// AcoustID-Kennung, wenn der Titel per Fingerabdruck gefunden wurde.
    public var acoustID: String?

    public init(number: Int, discNumber: Int = 1, title: String,
                durationMilliseconds: Int? = nil, artist: String? = nil,
                recordingID: String? = nil, acoustID: String? = nil) {
        self.number = number
        self.discNumber = discNumber
        self.title = title
        self.durationMilliseconds = durationMilliseconds
        self.artist = artist
        self.recordingID = recordingID
        self.acoustID = acoustID
    }
}

/// Kennungen der Dienste. Welche gefüllt sind, hängt von der Quelle ab.
public struct LookupIdentifiers: Sendable, Codable, Equatable, Hashable {
    public var musicBrainzReleaseID: String?
    public var musicBrainzReleaseGroupID: String?
    public var musicBrainzArtistID: String?
    public var discogsReleaseID: String?

    public init(musicBrainzReleaseID: String? = nil, musicBrainzReleaseGroupID: String? = nil,
                musicBrainzArtistID: String? = nil, discogsReleaseID: String? = nil) {
        self.musicBrainzReleaseID = musicBrainzReleaseID
        self.musicBrainzReleaseGroupID = musicBrainzReleaseGroupID
        self.musicBrainzArtistID = musicBrainzArtistID
        self.discogsReleaseID = discogsReleaseID
    }
}

/// Ein Treffer (ein Release/Album) aus der Suche.
public struct LookupCandidate: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var source: LookupSource
    /// Trefferwahrscheinlichkeit 0–100, wie der Dienst sie liefert.
    public var score: Int
    public var artist: String
    public var album: String
    /// Jahr als Text ("1999"); leer, wenn unbekannt.
    public var year: String
    public var label: String
    public var catalogNumber: String
    /// Ländercode (ISO 3166-1, z.B. "DE"); leer, wenn unbekannt.
    public var country: String
    /// Gesamtzahl der Titel laut Suche; nil, wenn der Dienst sie nicht nennt.
    public var trackCount: Int?
    /// Trackliste. Bei Suchergebnissen oft leer oder unvollständig — erst
    /// `OnlineLookupService.details(for:)` holt sie komplett.
    public var tracks: [LookupTrack]
    /// Ob `tracks` die vollständige Liste des Releases ist.
    public var hasFullTracklist: Bool
    public var coverURL: URL?
    public var identifiers: LookupIdentifiers

    public init(source: LookupSource, score: Int, artist: String, album: String,
                year: String = "", label: String = "", catalogNumber: String = "",
                country: String = "", trackCount: Int? = nil, tracks: [LookupTrack] = [],
                hasFullTracklist: Bool = false, coverURL: URL? = nil,
                identifiers: LookupIdentifiers = LookupIdentifiers()) {
        self.source = source
        self.score = score
        self.artist = artist
        self.album = album
        self.year = year
        self.label = label
        self.catalogNumber = catalogNumber
        self.country = country
        self.trackCount = trackCount
        self.tracks = tracks
        self.hasFullTracklist = hasFullTracklist
        self.coverURL = coverURL
        self.identifiers = identifiers
    }

    /// Stabile Kennung für Listen: Quelle plus Release-ID des Dienstes.
    public var id: String {
        let key = identifiers.musicBrainzReleaseID
            ?? identifiers.discogsReleaseID
            ?? "\(artist)|\(album)|\(year)"
        return "\(source.rawValue):\(key)"
    }

    /// Einzeilige Zusammenfassung für CLI und Listen.
    public var summary: String {
        var parts: [String] = []
        if !year.isEmpty { parts.append(year) }
        if !country.isEmpty { parts.append(country) }
        if !label.isEmpty { parts.append(label) }
        if !catalogNumber.isEmpty { parts.append(catalogNumber) }
        if let trackCount { parts.append("\(trackCount) tracks") }
        let details = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "\(artist) – \(album)\(details)"
    }
}

/// Suchbegriffe. Die App belegt sie aus den Tags vor, die CLI liest sie aus
/// den Dateien oder aus Optionen.
public struct LookupQuery: Sendable, Equatable, Codable {
    public var artist: String
    public var album: String
    /// Titel — nur für die Recording-Suche (einzelner Titel ohne Album).
    public var title: String
    public var year: String
    public var trackCount: Int?

    public init(artist: String = "", album: String = "", title: String = "",
                year: String = "", trackCount: Int? = nil) {
        self.artist = artist
        self.album = album
        self.title = title
        self.year = year
        self.trackCount = trackCount
    }

    /// Ob überhaupt etwas zum Suchen da ist.
    public var isEmpty: Bool {
        artist.trimmingCharacters(in: .whitespaces).isEmpty
            && album.trimmingCharacters(in: .whitespaces).isEmpty
            && title.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Was der Matcher über eine lokale Datei wissen muss.
public struct LookupFileInfo: Sendable, Equatable {
    public var url: URL
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationMilliseconds: Int?
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var year: String

    public init(url: URL, trackNumber: Int? = nil, discNumber: Int? = nil,
                durationMilliseconds: Int? = nil, title: String = "", artist: String = "",
                albumArtist: String = "", album: String = "", year: String = "") {
        self.url = url
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationMilliseconds = durationMilliseconds
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
    }

    /// Aus gelesenen Tags: "3/12" → Track 3, "2/2" → CD 2; Jahr = erste vier
    /// Ziffern von DATE.
    public init(url: URL, data: TagData) {
        self.init(
            url: url,
            trackNumber: Self.leadingNumber(data.firstValue(for: "TRACKNUMBER")),
            discNumber: Self.leadingNumber(data.firstValue(for: "DISCNUMBER")),
            durationMilliseconds: data.audio?.lengthMilliseconds,
            title: data.firstValue(for: "TITLE") ?? "",
            artist: data.firstValue(for: "ARTIST") ?? "",
            albumArtist: data.firstValue(for: "ALBUMARTIST") ?? "",
            album: data.firstValue(for: "ALBUM") ?? "",
            year: Self.year(from: data.firstValue(for: "DATE"))
        )
    }

    /// Die führende Zahl eines Feldes wie "3/12" oder "03"; nil ohne Zahl.
    public static func leadingNumber(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        return Int(digits)
    }

    /// Vier führende Ziffern eines Datums ("2001-05-02" → "2001").
    public static func year(from value: String?) -> String {
        guard let value else { return "" }
        let digits = value.prefix { $0.isNumber }
        return digits.count >= 4 ? String(digits.prefix(4)) : ""
    }

    /// Suchbegriffe für eine Dateigruppe (Album): gemeinsamer Interpret und
    /// gemeinsames Album; bei einer einzelnen Datei zusätzlich der Titel.
    public static func query(for files: [LookupFileInfo]) -> LookupQuery {
        func common(_ values: [String]) -> String {
            let nonEmpty = values.filter { !$0.isEmpty }
            guard let first = nonEmpty.first, nonEmpty.allSatisfy({ $0 == first }) else { return "" }
            return first
        }
        let albumArtist = common(files.map(\.albumArtist))
        let artist = albumArtist.isEmpty ? common(files.map(\.artist)) : albumArtist
        let query = LookupQuery(
            artist: artist,
            album: common(files.map(\.album)),
            title: files.count == 1 ? files[0].title : "",
            year: common(files.map(\.year)),
            trackCount: files.count > 1 ? files.count : nil
        )
        return query
    }
}

/// Fehler des Online-Lookups. Texte englisch wie in `TagError`; die App
/// stellt deutsche Kontextzeilen voran.
public enum LookupError: Error, LocalizedError, Sendable, Equatable {
    /// Online-Dienste sind nicht freigegeben (Einstellung bzw. `TAGX_ONLINE`).
    case onlineDisabled
    /// Die Suche lieferte keinen Kandidaten (CLI: Exit 5).
    case noResults
    /// Der Dienst bremst (HTTP 429/503); `retryAfterSeconds` aus dem Header.
    case rateLimited(source: LookupSource, retryAfterSeconds: Int)
    case httpStatus(source: LookupSource, status: Int)
    case invalidResponse(source: LookupSource, reason: String)
    /// Discogs-Token oder AcoustID-Key fehlt, obwohl der Dienst ihn braucht.
    case missingCredential(source: LookupSource, name: String)
    /// Der Kandidat hat keine Kennung, über die sich Details holen lassen.
    case noDetailsAvailable
    /// Suchbegriffe leer — nichts, womit sich suchen ließe.
    case emptyQuery

    public var errorDescription: String? {
        switch self {
        case .onlineDisabled:
            return "Online services are disabled. Enable them in the settings "
                + "(app) or set TAGX_ONLINE=1 (CLI) after reading the privacy notice."
        case .noResults:
            return "No matching release found"
        case .rateLimited(let source, let seconds):
            return "\(source.displayName) asks to slow down; retry in \(seconds) s"
        case .httpStatus(let source, let status):
            return "\(source.displayName) answered with HTTP status \(status)"
        case .invalidResponse(let source, let reason):
            return "\(source.displayName) returned an unreadable answer: \(reason)"
        case .missingCredential(let source, let name):
            return "\(source.displayName) needs a \(name) — see the settings (app) "
                + "or the environment variable (CLI)"
        case .noDetailsAvailable:
            return "This candidate carries no release id to fetch details for"
        case .emptyQuery:
            return "Nothing to search for: provide artist, album or title"
        }
    }
}

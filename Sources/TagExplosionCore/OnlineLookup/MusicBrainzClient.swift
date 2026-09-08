// MusicBrainz WS/2 (JSON) und Cover Art Archive. Nur Lesen: Release-Suche,
// Recording-Suche, Release-Details mit Trackliste. Die Pflichten aus den
// MusicBrainz-Regeln (User-Agent mit Kontakt, höchstens eine Anfrage pro
// Sekunde, 503 abwarten) erledigt `LookupTransport`.
import Foundation

struct MusicBrainzClient: Sendable {
    let transport: LookupTransport
    /// `https://musicbrainz.org/ws/2`
    let baseURL: URL
    /// `https://coverartarchive.org`
    let coverArtBaseURL: URL

    // MARK: Anfragen

    /// Release-Suche nach Interpret + Album (+ Titelanzahl).
    func searchReleases(_ query: LookupQuery, limit: Int = 10) async throws -> [LookupCandidate] {
        var terms: [String] = []
        if !query.album.isEmpty { terms.append("release:\(Self.luceneQuoted(query.album))") }
        if !query.artist.isEmpty { terms.append("artist:\(Self.luceneQuoted(query.artist))") }
        if let count = query.trackCount, count > 0 { terms.append("tracks:\(count)") }
        guard !terms.isEmpty else { throw LookupError.emptyQuery }
        let url = try makeURL(path: "release", query: [
            ("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "\(limit)"),
        ])
        let response = try await transport.send(LookupHTTPRequest(url: url), source: .musicbrainz)
        return try Self.parseReleaseSearch(response.body, coverArtBaseURL: coverArtBaseURL)
    }

    /// Recording-Suche nach Interpret + Titel; jeder Treffer wird je Release
    /// ein Kandidat mit genau dem einen bekannten Titel.
    func searchRecordings(_ query: LookupQuery, limit: Int = 10) async throws -> [LookupCandidate] {
        var terms: [String] = []
        if !query.title.isEmpty { terms.append("recording:\(Self.luceneQuoted(query.title))") }
        if !query.artist.isEmpty { terms.append("artist:\(Self.luceneQuoted(query.artist))") }
        guard !terms.isEmpty else { throw LookupError.emptyQuery }
        let url = try makeURL(path: "recording", query: [
            ("query", terms.joined(separator: " AND ")), ("fmt", "json"), ("limit", "\(limit)"),
        ])
        let response = try await transport.send(LookupHTTPRequest(url: url), source: .musicbrainz)
        return try Self.parseRecordingSearch(response.body, coverArtBaseURL: coverArtBaseURL)
    }

    /// Release mit vollständiger Trackliste, Labels und Release-Gruppe.
    func release(id: String) async throws -> LookupCandidate {
        let url = try makeURL(path: "release/\(id)", query: [
            ("inc", "recordings+artist-credits+labels+release-groups"), ("fmt", "json"),
        ])
        let response = try await transport.send(LookupHTTPRequest(url: url), source: .musicbrainz)
        let object = try LookupJSON.object(from: response.body, source: .musicbrainz)
        return try Self.parseRelease(object, score: 100, coverArtBaseURL: coverArtBaseURL)
    }

    private func makeURL(path: String, query: [(String, String)]) throws -> URL {
        // "+" in `inc` muss wörtlich stehen bleiben; `encodeQuery` kodiert es
        // als %2B, was MusicBrainz genauso liest.
        let string = baseURL.absoluteString + "/" + path + "?" + LookupJSON.encodeQuery(query)
        guard let url = URL(string: string) else {
            throw LookupError.invalidResponse(source: .musicbrainz, reason: "cannot build URL")
        }
        return url
    }

    /// Lucene-Phrase: Anführungszeichen und Backslash maskieren.
    static func luceneQuoted(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    // MARK: Parser

    static func parseReleaseSearch(_ data: Data, coverArtBaseURL: URL) throws -> [LookupCandidate] {
        let object = try LookupJSON.object(from: data, source: .musicbrainz)
        return try LookupJSON.array(object["releases"]).map { release in
            try parseRelease(release, score: LookupJSON.int(release["score"]) ?? 0,
                             coverArtBaseURL: coverArtBaseURL)
        }
    }

    static func parseRecordingSearch(_ data: Data, coverArtBaseURL: URL) throws -> [LookupCandidate] {
        let object = try LookupJSON.object(from: data, source: .musicbrainz)
        var candidates: [LookupCandidate] = []
        for recording in LookupJSON.array(object["recordings"]) {
            let recordingID = LookupJSON.string(recording["id"])
            let recordingTitle = LookupJSON.string(recording["title"])
            let recordingArtist = artistCredit(recording["artist-credit"])
            let score = LookupJSON.int(recording["score"]) ?? 0
            let length = LookupJSON.int(recording["length"])
            for release in LookupJSON.array(recording["releases"]) {
                var candidate = try parseRelease(release, score: score, coverArtBaseURL: coverArtBaseURL)
                if candidate.artist.isEmpty { candidate.artist = recordingArtist.name }
                if candidate.identifiers.musicBrainzArtistID == nil {
                    candidate.identifiers.musicBrainzArtistID = recordingArtist.id
                }
                // Position des Titels auf dem Release, falls mitgeliefert.
                var number = 0
                var disc = 1
                for medium in LookupJSON.array(release["media"]) {
                    if let track = LookupJSON.array(medium["track"]).first {
                        number = LookupJSON.int(track["number"]) ?? 0
                        disc = LookupJSON.int(medium["position"]) ?? 1
                        break
                    }
                }
                candidate.tracks = [LookupTrack(
                    number: number, discNumber: disc, title: recordingTitle,
                    durationMilliseconds: length,
                    artist: recordingArtist.name.isEmpty ? nil : recordingArtist.name,
                    recordingID: recordingID.isEmpty ? nil : recordingID)]
                candidate.hasFullTracklist = false
                candidates.append(candidate)
            }
        }
        return candidates
    }

    /// Ein Release-Objekt (aus Suche oder Detailabruf) in einen Kandidaten.
    static func parseRelease(_ release: [String: Any], score: Int, coverArtBaseURL: URL) throws -> LookupCandidate {
        let id = LookupJSON.string(release["id"])
        guard !id.isEmpty else {
            throw LookupError.invalidResponse(source: .musicbrainz, reason: "release without id")
        }
        let credit = artistCredit(release["artist-credit"])
        let labelInfo = LookupJSON.array(release["label-info"]).first
        let label = labelInfo.flatMap { $0["label"] as? [String: Any] }.map { LookupJSON.string($0["name"]) } ?? ""
        let catalog = labelInfo.map { LookupJSON.string($0["catalog-number"]) } ?? ""
        let group = release["release-group"] as? [String: Any]

        let media = LookupJSON.array(release["media"])
        var tracks: [LookupTrack] = []
        var hasFull = false
        for medium in media {
            let disc = LookupJSON.int(medium["position"]) ?? 1
            let list = LookupJSON.array(medium["tracks"])
            if !list.isEmpty { hasFull = true }
            for track in list {
                let recording = track["recording"] as? [String: Any]
                let trackCredit = artistCredit(track["artist-credit"] ?? recording?["artist-credit"])
                let title = LookupJSON.string(track["title"]).isEmpty
                    ? LookupJSON.string(recording?["title"])
                    : LookupJSON.string(track["title"])
                tracks.append(LookupTrack(
                    number: LookupJSON.int(track["position"]) ?? LookupJSON.int(track["number"]) ?? tracks.count + 1,
                    discNumber: disc,
                    title: title,
                    durationMilliseconds: LookupJSON.int(track["length"]) ?? LookupJSON.int(recording?["length"]),
                    artist: trackCredit.name.isEmpty || trackCredit.name == credit.name ? nil : trackCredit.name,
                    recordingID: recording.map { LookupJSON.string($0["id"]) }.flatMap { $0.isEmpty ? nil : $0 }))
            }
        }
        // Gesamtzahl: aus "track-count" (Suche) oder der Summe der Medien.
        let trackCount = LookupJSON.int(release["track-count"]) ?? media.reduce(Optional(0)) { total, medium in
            guard let total else { return nil }
            let count = LookupJSON.int(medium["track-count"]) ?? 0
            let (sum, overflow) = total.addingReportingOverflow(count)
            return count >= 0 && !overflow ? sum : nil
        }

        return LookupCandidate(
            source: .musicbrainz,
            score: score,
            artist: credit.name,
            album: LookupJSON.string(release["title"]),
            year: LookupFileInfo.year(from: LookupJSON.string(release["date"])),
            label: label,
            catalogNumber: catalog,
            country: LookupJSON.string(release["country"]),
            trackCount: trackCount == 0 ? nil : trackCount,
            tracks: tracks,
            hasFullTracklist: hasFull,
            coverURL: coverURL(releaseID: id, base: coverArtBaseURL),
            identifiers: LookupIdentifiers(
                musicBrainzReleaseID: id,
                musicBrainzReleaseGroupID: group.map { LookupJSON.string($0["id"]) }.flatMap { $0.isEmpty ? nil : $0 },
                musicBrainzArtistID: credit.id)
        )
    }

    /// Vorderseite in 500 px; das Archiv leitet auf archive.org weiter.
    static func coverURL(releaseID: String, base: URL) -> URL? {
        URL(string: base.absoluteString + "/release/\(releaseID)/front-500")
    }

    /// "artist-credit": Namen samt Verbindungswörtern ("A feat. B") und die
    /// ID des ersten Interpreten.
    static func artistCredit(_ value: Any?) -> (name: String, id: String?) {
        let credits = LookupJSON.array(value)
        var name = ""
        var firstID: String?
        for credit in credits {
            let artist = credit["artist"] as? [String: Any]
            let creditName = LookupJSON.string(credit["name"]).isEmpty
                ? LookupJSON.string(artist?["name"])
                : LookupJSON.string(credit["name"])
            name += creditName + LookupJSON.string(credit["joinphrase"])
            if firstID == nil, let id = artist.map({ LookupJSON.string($0["id"]) }), !id.isEmpty {
                firstID = id
            }
        }
        return (name.trimmingCharacters(in: .whitespaces), firstID)
    }
}

// Discogs-API (JSON): Release-Suche und Release-Details mit Trackliste.
// Ohne Token antwortet Discogs nur eingeschränkt (25 Anfragen/Minute, keine
// Bilder in der Suche); ein persönlicher Token wandert ausschließlich in den
// `Authorization`-Header — nie in die URL, nie ins Log.
import Foundation

struct DiscogsClient: Sendable {
    let transport: LookupTransport
    /// `https://api.discogs.com`
    let baseURL: URL
    let token: String?

    func searchReleases(_ query: LookupQuery, limit: Int = 10) async throws -> [LookupCandidate] {
        var items: [(String, String)] = [("type", "release"), ("per_page", "\(limit)")]
        if !query.artist.isEmpty { items.append(("artist", query.artist)) }
        if !query.album.isEmpty { items.append(("release_title", query.album)) }
        if !query.title.isEmpty, query.album.isEmpty { items.append(("track", query.title)) }
        if !query.year.isEmpty { items.append(("year", query.year)) }
        guard items.count > 2 else { throw LookupError.emptyQuery }
        let response = try await send(path: "database/search", query: items)
        return try Self.parseSearch(response.body)
    }

    func release(id: String) async throws -> LookupCandidate {
        let response = try await send(path: "releases/\(id)", query: [])
        return try Self.parseRelease(LookupJSON.object(from: response.body, source: .discogs))
    }

    private func send(path: String, query: [(String, String)]) async throws -> LookupHTTPResponse {
        var string = baseURL.absoluteString + "/" + path
        if !query.isEmpty { string += "?" + LookupJSON.encodeQuery(query) }
        guard let url = URL(string: string) else {
            throw LookupError.invalidResponse(source: .discogs, reason: "cannot build URL")
        }
        var headers: [String: String] = [:]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Discogs token=\(token)"
        }
        // Discogs meldet das Kontingent in `X-Discogs-Ratelimit-Remaining`;
        // ist es aufgebraucht, kommt 429 — das wiederholt der Transport nach
        // `Retry-After`, sonst nach seiner Vorgabe.
        return try await transport.send(LookupHTTPRequest(url: url, headers: headers), source: .discogs)
    }

    // MARK: Parser

    static func parseSearch(_ data: Data) throws -> [LookupCandidate] {
        let object = try LookupJSON.object(from: data, source: .discogs)
        let results = LookupJSON.array(object["results"])
        return results.enumerated().compactMap { index, result in
            let id = LookupJSON.string(result["id"])
            guard !id.isEmpty else { return nil }
            // Discogs liefert "Interpret - Album" als einen Titel.
            let combined = LookupJSON.string(result["title"])
            let (artist, album) = splitTitle(combined)
            let labels = (result["label"] as? [String]) ?? []
            let cover = LookupJSON.string(result["cover_image"])
            return LookupCandidate(
                source: .discogs,
                // Discogs kennt keinen Score; die Reihenfolge ist die Relevanz.
                score: max(0, 100 - index * 5),
                artist: artist,
                album: album,
                year: LookupFileInfo.year(from: LookupJSON.string(result["year"])),
                label: labels.first ?? "",
                catalogNumber: LookupJSON.string(result["catno"]),
                country: LookupJSON.string(result["country"]),
                trackCount: nil,
                tracks: [],
                hasFullTracklist: false,
                coverURL: cover.isEmpty ? nil : URL(string: cover),
                identifiers: LookupIdentifiers(discogsReleaseID: id))
        }
    }

    static func parseRelease(_ release: [String: Any]) throws -> LookupCandidate {
        let id = LookupJSON.string(release["id"])
        guard !id.isEmpty else {
            throw LookupError.invalidResponse(source: .discogs, reason: "release without id")
        }
        let artists = LookupJSON.array(release["artists"])
        let artist = artists.map { LookupJSON.string($0["name"]) }
            .map(cleanArtistName).filter { !$0.isEmpty }.joined(separator: ", ")
        let label = LookupJSON.array(release["labels"]).first
        let images = LookupJSON.array(release["images"])
        let primary = images.first { LookupJSON.string($0["type"]) == "primary" } ?? images.first
        let coverString = primary.map { LookupJSON.string($0["uri"]) } ?? ""

        var tracks: [LookupTrack] = []
        var running = 0
        for item in LookupJSON.array(release["tracklist"]) {
            // Überschriften ("Side A", "Bonus") haben type_ "heading".
            let type = LookupJSON.string(item["type_"])
            guard type.isEmpty || type == "track" else { continue }
            running += 1
            let position = parsePosition(LookupJSON.string(item["position"]), fallback: running)
            let trackArtists = LookupJSON.array(item["artists"]).map { cleanArtistName(LookupJSON.string($0["name"])) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            tracks.append(LookupTrack(
                number: position.number,
                discNumber: position.disc,
                title: LookupJSON.string(item["title"]),
                durationMilliseconds: LookupJSON.milliseconds(fromClock: LookupJSON.string(item["duration"])),
                artist: trackArtists.isEmpty ? nil : trackArtists))
        }
        return LookupCandidate(
            source: .discogs,
            score: 100,
            artist: artist,
            album: LookupJSON.string(release["title"]),
            year: LookupFileInfo.year(from: LookupJSON.string(release["year"])),
            label: label.map { LookupJSON.string($0["name"]) } ?? "",
            catalogNumber: label.map { LookupJSON.string($0["catno"]) } ?? "",
            country: LookupJSON.string(release["country"]),
            trackCount: tracks.isEmpty ? nil : tracks.count,
            tracks: tracks,
            hasFullTracklist: !tracks.isEmpty,
            coverURL: coverString.isEmpty ? nil : URL(string: coverString),
            identifiers: LookupIdentifiers(discogsReleaseID: id))
    }

    /// "Miles Davis - Kind Of Blue" → ("Miles Davis", "Kind Of Blue").
    static func splitTitle(_ combined: String) -> (artist: String, album: String) {
        guard let range = combined.range(of: " - ") else { return ("", combined) }
        return (cleanArtistName(String(combined[..<range.lowerBound])),
                String(combined[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Discogs hängt an Namensdubletten " (2)" an — das gehört nicht ins Tag.
    static func cleanArtistName(_ name: String) -> String {
        var cleaned = name.trimmingCharacters(in: .whitespaces)
        if let range = cleaned.range(of: #" \(\d+\)$"#, options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        return cleaned
    }

    /// Positionen: "7" → Track 7; "2-3" → CD 2, Track 3; "A1"/"B2" (Vinyl)
    /// → laufende Nummer, weil Seiten keine Nummern tragen.
    static func parsePosition(_ position: String, fallback: Int) -> (disc: Int, number: Int) {
        let trimmed = position.trimmingCharacters(in: .whitespaces)
        if let number = Int(trimmed) { return (1, number) }
        let parts = trimmed.split(separator: "-")
        if parts.count == 2, let disc = Int(parts[0]), let number = Int(parts[1]) {
            return (disc, number)
        }
        return (1, fallback)
    }
}

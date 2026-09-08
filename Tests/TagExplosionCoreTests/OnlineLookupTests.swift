// Online-Lookup ohne Netz: Parser der drei Dienste gegen kleine, selbst
// verfasste JSON-Antworten (Feldnamen wie die echten APIs), Ratenbegrenzer
// und 503-Wiederholung mit Testuhr, Zuordnung Datei ↔ Titel und der
// Änderungsplan. Ein Stub ersetzt URLSession; `swift test` greift nie ins
// Netz.
import Foundation
import Testing
@testable import TagExplosionCore

/// Stub-Transport: bildet Anfragen über eine Closure auf Antworten ab und
/// protokolliert alles, was gesendet wurde.
private final class StubClient: LookupHTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (LookupHTTPRequest) throws -> LookupHTTPResponse
    private let lock = NSLock()
    private var log: [LookupHTTPRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: LookupHTTPRequest) async throws -> LookupHTTPResponse {
        lock.withLock { log.append(request) }
        return try handler(request)
    }

    var requests: [LookupHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }
}

/// Protokoll der Schlafzeiten des Ratenbegrenzers.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func record(_ seconds: TimeInterval) { lock.lock(); values.append(seconds); lock.unlock() }
    var all: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return values }
}

private func json(_ text: String) -> LookupHTTPResponse {
    LookupHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
}

// MARK: - Fixtures (selbst verfasst, Struktur wie die echten APIs)

private let mbReleaseSearchJSON = """
{"created":"2026-09-02T10:00:00Z","count":1,"offset":0,"releases":[
 {"id":"11111111-aaaa-bbbb-cccc-000000000001","score":97,"title":"Blaue Stunde","status":"Official",
  "date":"2004-03-15","country":"DE","track-count":2,
  "artist-credit":[{"name":"Testkapelle","joinphrase":" & ","artist":{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"Testkapelle"}},
                   {"name":"Gast","artist":{"id":"aaaaaaaa-0000-0000-0000-000000000002","name":"Gast"}}],
  "release-group":{"id":"22222222-aaaa-bbbb-cccc-000000000001","primary-type":"Album"},
  "label-info":[{"catalog-number":"TK-004","label":{"id":"l1","name":"Testlabel"}}],
  "media":[{"format":"CD","track-count":2}]}]}
"""

private let mbReleaseDetailsJSON = """
{"id":"11111111-aaaa-bbbb-cccc-000000000001","title":"Blaue Stunde","date":"2004-03-15","country":"DE",
 "artist-credit":[{"name":"Testkapelle","artist":{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"Testkapelle"}}],
 "release-group":{"id":"22222222-aaaa-bbbb-cccc-000000000001"},
 "label-info":[{"catalog-number":"TK-004","label":{"name":"Testlabel"}}],
 "media":[{"position":1,"format":"CD","track-count":2,"tracks":[
   {"id":"t1","position":1,"number":"1","title":"Morgenlied","length":181000,
    "recording":{"id":"rrrrrrrr-0000-0000-0000-000000000001","title":"Morgenlied","length":181000}},
   {"id":"t2","position":2,"number":"2","title":"Abendlied","length":240500,
    "artist-credit":[{"name":"Gast","artist":{"id":"aaaaaaaa-0000-0000-0000-000000000002","name":"Gast"}}],
    "recording":{"id":"rrrrrrrr-0000-0000-0000-000000000002","title":"Abendlied","length":240500}}]},
  {"position":2,"format":"CD","track-count":1,"tracks":[
   {"id":"t3","position":1,"number":"1","title":"Bonus","length":60000,
    "recording":{"id":"rrrrrrrr-0000-0000-0000-000000000003","title":"Bonus"}}]}]}
"""

private let mbRecordingSearchJSON = """
{"count":1,"recordings":[{"id":"rrrrrrrr-0000-0000-0000-000000000001","score":88,"title":"Morgenlied","length":181000,
 "artist-credit":[{"name":"Testkapelle","artist":{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"Testkapelle"}}],
 "releases":[{"id":"11111111-aaaa-bbbb-cccc-000000000001","title":"Blaue Stunde","date":"2004","country":"DE",
   "release-group":{"id":"22222222-aaaa-bbbb-cccc-000000000001"},"track-count":2,
   "media":[{"position":1,"format":"CD","track-count":2,"track":[{"id":"t1","number":"1","title":"Morgenlied"}]}]}]}]}
"""

private let discogsSearchJSON = """
{"pagination":{"page":1,"pages":1,"per_page":10,"items":1},"results":[
 {"id":123456,"type":"release","title":"Testkapelle (2) - Blaue Stunde","year":"2004","country":"Germany",
  "label":["Testlabel"],"catno":"TK-004","format":["CD","Album"],"cover_image":"https://img.example.test/cover.jpg",
  "resource_url":"https://api.discogs.com/releases/123456"}]}
"""

private let discogsReleaseJSON = """
{"id":123456,"title":"Blaue Stunde","year":2004,"country":"Germany",
 "artists":[{"name":"Testkapelle (2)","id":77}],
 "labels":[{"name":"Testlabel","catno":"TK-004"}],
 "images":[{"type":"secondary","uri":"https://img.example.test/back.jpg"},{"type":"primary","uri":"https://img.example.test/front.jpg"}],
 "tracklist":[{"position":"","type_":"heading","title":"Seite A"},
              {"position":"A1","type_":"track","title":"Morgenlied","duration":"3:01"},
              {"position":"A2","type_":"track","title":"Abendlied","duration":"4:00","artists":[{"name":"Gast"}]},
              {"position":"2-1","type_":"track","title":"Bonus","duration":"1:00"}]}
"""

private let acoustIDLookupJSON = """
{"status":"ok","results":[{"id":"ffffffff-1111-2222-3333-444444444444","score":0.96,
 "recordings":[{"id":"rrrrrrrr-0000-0000-0000-000000000001","title":"Morgenlied","duration":181,
   "artists":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"Testkapelle"}],
   "releasegroups":[{"id":"22222222-aaaa-bbbb-cccc-000000000001","type":"Album","title":"Blaue Stunde",
     "releases":[{"id":"11111111-aaaa-bbbb-cccc-000000000001","title":"Blaue Stunde","country":"DE",
       "date":{"year":2004,"month":3,"day":15},"track_count":2,
       "mediums":[{"position":1,"track_count":2,"tracks":[{"id":"t1","position":1,"title":"Morgenlied"}]}]}]}]}]}]}
"""

private let caa = URL(string: "https://coverartarchive.org")!

// MARK: - Tests

@Suite("Online-Lookup: Freigabe und Ratenbegrenzer")
struct OnlineLookupPolicyTests {
    @Test("HTTP-Header vertragen unterschiedliche Schreibweisen desselben Namens")
    func headerNormalization() {
        let response = LookupHTTPResponse(statusCode: 503, headers: ["Retry-After": "2", "retry-after": "3"])
        #expect(response.headers == ["retry-after": "3"])
    }

    @Test("User-Agent trägt Version und Kontaktadresse")
    func userAgent() {
        #expect(OnlineLookupConsent.userAgent(version: "0.34.0")
                == "TagExplosion/0.34.0 (https://github.com/DanielMuellerIR/tag_explosion)")
        #expect(OnlineLookupConsent.userAgent(version: " ") == "TagExplosion/dev (https://github.com/DanielMuellerIR/tag_explosion)")
    }

    @Test("TAGX_ONLINE gibt nur bei 1/true/yes frei; ohne Freigabe fliegt onlineDisabled")
    func consent() throws {
        #expect(OnlineLookupConsent.isEnabled(environment: ["TAGX_ONLINE": "1"]))
        #expect(OnlineLookupConsent.isEnabled(environment: ["TAGX_ONLINE": "true"]))
        #expect(!OnlineLookupConsent.isEnabled(environment: ["TAGX_ONLINE": "0"]))
        #expect(!OnlineLookupConsent.isEnabled(environment: [:]))
        #expect(throws: LookupError.onlineDisabled) { try OnlineLookupConsent.require(enabled: false) }
        try OnlineLookupConsent.require(enabled: true)
    }

    @Test("Ratenbegrenzer: erste Anfrage sofort, danach je eine Sekunde Abstand")
    func rateLimiter() async throws {
        let sleeps = SleepLog()
        let limiter = RateLimiter(minimumInterval: 1.0, now: { 100 }, sleep: { sleeps.record($0) })
        try await limiter.waitTurn()
        try await limiter.waitTurn()
        try await limiter.waitTurn()
        #expect(sleeps.all == [1.0, 2.0])
    }

    @Test("Ratenbegrenzer mit echter Uhr und echtem Schlafen wartet wirklich (Regression: Task-Allocator-Absturz)")
    func rateLimiterReal() async throws {
        let limiter = RateLimiter(minimumInterval: 0.05)
        let start = Date()
        try await limiter.waitTurn()
        try await limiter.waitTurn()
        try await limiter.waitTurn()
        #expect(Date().timeIntervalSince(start) >= 0.09)
    }

    @Test("503 mit Retry-After wird abgewartet und wiederholt; danach rateLimited")
    func retryOn503() async throws {
        let counter = SleepLog()
        let client = StubClient { _ in
            counter.record(0)
            return counter.all.count < 3
                ? LookupHTTPResponse(statusCode: 503, headers: ["Retry-After": "3"])
                : json(#"{"releases":[]}"#)
        }
        let sleeps = SleepLog()
        let transport = LookupTransport(client: client,
                                        limiter: RateLimiter(minimumInterval: 1, now: { 0 }, sleep: { _ in }),
                                        userAgent: "UA/1", sleep: { sleeps.record($0) }, maximumRetries: 2)
        let response = try await transport.send(LookupHTTPRequest(url: URL(string: "https://x.test/a")!), source: .musicbrainz)
        #expect(response.statusCode == 200)
        #expect(sleeps.all == [3, 3])
        #expect(client.requests.allSatisfy { $0.headers["User-Agent"] == "UA/1" })

        // Dauerhaft 503: nach den Wiederholungen ein sprechender Fehler.
        let stubborn = StubClient { _ in LookupHTTPResponse(statusCode: 503) }
        let strict = LookupTransport(client: stubborn,
                                     limiter: RateLimiter(minimumInterval: 1, now: { 0 }, sleep: { _ in }),
                                     userAgent: "UA/1", sleep: { _ in }, maximumRetries: 1)
        await #expect(throws: LookupError.rateLimited(source: .discogs, retryAfterSeconds: 2)) {
            _ = try await strict.send(LookupHTTPRequest(url: URL(string: "https://x.test/a")!), source: .discogs)
        }
        #expect(stubborn.requests.count == 2)
    }

    @Test("Andere Fehlercodes werden nicht wiederholt")
    func httpError() async throws {
        let client = StubClient { _ in LookupHTTPResponse(statusCode: 404) }
        let transport = LookupTransport(client: client,
                                        limiter: RateLimiter(minimumInterval: 1, now: { 0 }, sleep: { _ in }),
                                        userAgent: "UA/1", sleep: { _ in })
        await #expect(throws: LookupError.httpStatus(source: .musicbrainz, status: 404)) {
            _ = try await transport.send(LookupHTTPRequest(url: URL(string: "https://x.test/a")!), source: .musicbrainz)
        }
        #expect(client.requests.count == 1)
    }
}

@Suite("Online-Lookup: Parser")
struct OnlineLookupParserTests {
    @Test("MusicBrainz-Release-Suche: Felder, Kennungen, Cover-URL")
    func musicBrainzReleaseSearch() throws {
        let candidates = try MusicBrainzClient.parseReleaseSearch(Data(mbReleaseSearchJSON.utf8), coverArtBaseURL: caa)
        #expect(candidates.count == 1)
        let c = try #require(candidates.first)
        #expect(c.source == .musicbrainz)
        #expect(c.score == 97)
        #expect(c.artist == "Testkapelle & Gast")
        #expect(c.album == "Blaue Stunde")
        #expect(c.year == "2004")
        #expect(c.country == "DE")
        #expect(c.label == "Testlabel")
        #expect(c.catalogNumber == "TK-004")
        #expect(c.trackCount == 2)
        #expect(c.tracks.isEmpty && !c.hasFullTracklist)
        #expect(c.identifiers.musicBrainzReleaseID == "11111111-aaaa-bbbb-cccc-000000000001")
        #expect(c.identifiers.musicBrainzReleaseGroupID == "22222222-aaaa-bbbb-cccc-000000000001")
        #expect(c.identifiers.musicBrainzArtistID == "aaaaaaaa-0000-0000-0000-000000000001")
        #expect(c.coverURL?.absoluteString
                == "https://coverartarchive.org/release/11111111-aaaa-bbbb-cccc-000000000001/front-500")
        #expect(c.summary == "Testkapelle & Gast – Blaue Stunde (2004, DE, Testlabel, TK-004, 2 tracks)")
    }

    @Test("MusicBrainz-Release-Details: Trackliste über zwei Medien mit Dauer und Recording-ID")
    func musicBrainzDetails() throws {
        let object = try LookupJSON.object(from: Data(mbReleaseDetailsJSON.utf8), source: .musicbrainz)
        let c = try MusicBrainzClient.parseRelease(object, score: 100, coverArtBaseURL: caa)
        #expect(c.hasFullTracklist)
        #expect(c.trackCount == 3)
        #expect(c.tracks.map(\.title) == ["Morgenlied", "Abendlied", "Bonus"])
        #expect(c.tracks.map(\.number) == [1, 2, 1])
        #expect(c.tracks.map(\.discNumber) == [1, 1, 2])
        #expect(c.tracks[0].durationMilliseconds == 181000)
        #expect(c.tracks[0].recordingID == "rrrrrrrr-0000-0000-0000-000000000001")
        #expect(c.tracks[0].artist == nil, "Album-Interpret wird nicht je Titel wiederholt")
        #expect(c.tracks[1].artist == "Gast")
        let oversized: [String: Any] = ["id": "r", "media": [["track-count": Int.max], ["track-count": 1]]]
        #expect(try MusicBrainzClient.parseRelease(oversized, score: 0, coverArtBaseURL: caa).trackCount == nil)
    }

    @Test("MusicBrainz-Recording-Suche: ein Kandidat je Release mit dem einen Titel")
    func musicBrainzRecordingSearch() throws {
        let candidates = try MusicBrainzClient.parseRecordingSearch(Data(mbRecordingSearchJSON.utf8), coverArtBaseURL: caa)
        let c = try #require(candidates.first)
        #expect(c.score == 88)
        #expect(c.album == "Blaue Stunde" && c.artist == "Testkapelle")
        #expect(!c.hasFullTracklist)
        #expect(c.tracks == [LookupTrack(number: 1, discNumber: 1, title: "Morgenlied", durationMilliseconds: 181000,
                                         artist: "Testkapelle", recordingID: "rrrrrrrr-0000-0000-0000-000000000001")])
    }

    @Test("Lucene-Phrasen maskieren Anführungszeichen")
    func lucene() {
        #expect(MusicBrainzClient.luceneQuoted(#"Say "Hi" \ Bye"#) == #""Say \"Hi\" \\ Bye""#)
    }

    @Test("Discogs-Suche: Interpret und Album trennen, Dubletten-Suffix entfernen")
    func discogsSearch() throws {
        let candidates = try DiscogsClient.parseSearch(Data(discogsSearchJSON.utf8))
        let c = try #require(candidates.first)
        #expect(c.source == .discogs)
        #expect(c.artist == "Testkapelle" && c.album == "Blaue Stunde")
        #expect(c.year == "2004" && c.country == "Germany" && c.label == "Testlabel" && c.catalogNumber == "TK-004")
        #expect(c.identifiers.discogsReleaseID == "123456")
        #expect(c.coverURL?.absoluteString == "https://img.example.test/cover.jpg")
        #expect(!c.hasFullTracklist)
    }

    @Test("Discogs-Release: Überschriften überspringen, Vinyl- und CD-Positionen, mm:ss-Dauern")
    func discogsRelease() throws {
        let object = try LookupJSON.object(from: Data(discogsReleaseJSON.utf8), source: .discogs)
        let c = try DiscogsClient.parseRelease(object)
        #expect(c.artist == "Testkapelle")
        #expect(c.hasFullTracklist && c.trackCount == 3)
        #expect(c.tracks.map(\.title) == ["Morgenlied", "Abendlied", "Bonus"])
        #expect(c.tracks.map(\.number) == [1, 2, 1])
        #expect(c.tracks.map(\.discNumber) == [1, 1, 2])
        #expect(c.tracks.map(\.durationMilliseconds) == [181000, 240000, 60000])
        #expect(c.tracks[1].artist == "Gast")
        #expect(c.coverURL?.absoluteString == "https://img.example.test/front.jpg", "primary vor secondary")
    }

    @Test("AcoustID: Kandidaten aus Release-Gruppen mit AcoustID- und MusicBrainz-Kennungen")
    func acoustID() throws {
        let candidates = try AcoustIDClient.parseLookup(Data(acoustIDLookupJSON.utf8), coverArtBaseURL: caa)
        let c = try #require(candidates.first)
        #expect(c.source == .acoustid && c.score == 96)
        #expect(c.artist == "Testkapelle" && c.album == "Blaue Stunde" && c.year == "2004" && c.country == "DE")
        #expect(c.trackCount == 2)
        #expect(c.identifiers.musicBrainzReleaseID == "11111111-aaaa-bbbb-cccc-000000000001")
        #expect(c.identifiers.musicBrainzReleaseGroupID == "22222222-aaaa-bbbb-cccc-000000000001")
        #expect(c.identifiers.musicBrainzArtistID == "aaaaaaaa-0000-0000-0000-000000000001")
        let track = try #require(c.tracks.first)
        #expect(track.number == 1 && track.title == "Morgenlied" && track.durationMilliseconds == 181000)
        #expect(track.acoustID == "ffffffff-1111-2222-3333-444444444444")
        #expect(track.recordingID == "rrrrrrrr-0000-0000-0000-000000000001")

        #expect(throws: LookupError.invalidResponse(source: .acoustid, reason: "invalid API key")) {
            _ = try AcoustIDClient.parseLookup(
                Data(#"{"status":"error","error":{"code":4,"message":"invalid API key"}}"#.utf8), coverArtBaseURL: caa)
        }
    }

    @Test("AcoustID: übergroße Dauer und Bewertung beenden den Parser nicht")
    func acoustIDNumericBounds() throws {
        let input = acoustIDLookupJSON.replacingOccurrences(of: "0.96", with: "1e308")
            .replacingOccurrences(of: "\"duration\":181", with: "\"duration\":\(Int.max)")
        let candidates = try AcoustIDClient.parseLookup(Data(input.utf8), coverArtBaseURL: caa)
        let candidate = try #require(candidates.first)
        #expect(candidate.score == 100)
        #expect(candidate.tracks.first?.durationMilliseconds == nil)
    }

    @Test("fpcalc-JSON: Dauer gerundet, Fingerabdruck Pflicht")
    func fpcalc() throws {
        let fp = try Fpcalc.parse(Data(#"{"duration": 181.42, "fingerprint": "AQADtEmSJEmSJ"}"#.utf8))
        #expect(fp == AudioFingerprint(durationSeconds: 181, fingerprint: "AQADtEmSJEmSJ"))
        #expect(throws: (any Error).self) { _ = try Fpcalc.parse(Data(#"{"duration": 1}"#.utf8)) }
        for duration in ["1e308", "-1", "\"nan\"", "\"inf\""] {
            let input = "{\"duration\": \(duration), \"fingerprint\": \"AQAD\"}"
            #expect(throws: (any Error).self) { _ = try Fpcalc.parse(Data(input.utf8)) }
        }
    }

    @Test("Hilfen: mm:ss, Query-Kodierung, führende Zahl, Jahr")
    func helpers() {
        #expect(LookupJSON.milliseconds(fromClock: "3:01") == 181000)
        #expect(LookupJSON.milliseconds(fromClock: "1:02:03") == 3723000)
        #expect(LookupJSON.milliseconds(fromClock: "") == nil)
        for invalid in ["1::2", "-1:20", "1:", "\(Int.max):00", "\(Int.max)"] {
            #expect(LookupJSON.milliseconds(fromClock: invalid) == nil)
        }
        #expect(LookupJSON.encodeQuery([("q", "a b&c+d"), ("fmt", "json")]) == "q=a%20b%26c%2Bd&fmt=json")
        #expect(LookupFileInfo.leadingNumber("03/12") == 3)
        #expect(LookupFileInfo.leadingNumber("x") == nil)
        #expect(LookupFileInfo.year(from: "2004-03-15") == "2004")
        #expect(LookupFileInfo.year(from: "04") == "")
    }
}

@Suite("Online-Lookup: Zuordnung und Plan")
struct OnlineLookupMatchingTests {
    private let tracks = [
        LookupTrack(number: 1, title: "Morgenlied", durationMilliseconds: 181000, recordingID: "r1"),
        LookupTrack(number: 2, title: "Abendlied", durationMilliseconds: 240500, recordingID: "r2"),
        LookupTrack(number: 3, title: "Nachtlied", durationMilliseconds: 200000, recordingID: "r3"),
    ]

    private func file(_ name: String, track: Int? = nil, duration: Int? = nil, title: String = "") -> LookupFileInfo {
        LookupFileInfo(url: URL(fileURLWithPath: "/tmp/\(name)"), trackNumber: track,
                       durationMilliseconds: duration, title: title)
    }

    @Test("Tracknummer zuerst, dann Dauer ±3 s mit Titel, sonst keine Zuordnung")
    func assignment() {
        let files = [
            file("a.mp3", track: 2),
            file("b.mp3", duration: 182500, title: "morgen-lied"),
            file("c.mp3", duration: 250000, title: "Etwas ganz anderes"),
            file("d.mp3", title: "Nachtlied (Remaster)"),
        ]
        let result = TrackMatcher.assign(files: files, tracks: tracks)
        #expect(result[0].track?.number == 2 && result[0].reason == .trackNumber)
        #expect(result[1].track?.number == 1 && result[1].reason == .durationAndTitle)
        #expect(result[2].track == nil && result[2].reason == .none)
        #expect(result[3].track?.number == 3 && result[3].reason == .titleOnly)
        let extremes = TrackMatcher.assign(files: [file("extreme.mp3", duration: Int.min, title: "Morgenlied")],
            tracks: [LookupTrack(number: 1, title: "Morgenlied", durationMilliseconds: Int.max)])
        #expect(extremes[0].reason == .titleOnly)
    }

    @Test("Jeder Titel nur einmal; eine doppelte Tracknummer entscheidet nicht")
    func uniqueness() {
        let twoDiscs = [
            LookupTrack(number: 1, discNumber: 1, title: "Eins", durationMilliseconds: 100000),
            LookupTrack(number: 1, discNumber: 2, title: "Zwei", durationMilliseconds: 200000),
        ]
        let files = [file("x.mp3", track: 1, duration: 200000, title: "Zwei"),
                     file("y.mp3", track: 1, duration: 100000, title: "Eins")]
        let result = TrackMatcher.assign(files: files, tracks: twoDiscs)
        #expect(result[0].track?.title == "Zwei" && result[0].reason == .durationAndTitle)
        #expect(result[1].track?.title == "Eins")
    }

    @Test("Titelähnlichkeit ignoriert Groß-/Kleinschreibung, Akzente und Satzzeichen")
    func similarity() {
        #expect(TrackMatcher.titleSimilarity("Café — Nächte!", "cafe nachte") == 1)
        #expect(TrackMatcher.titleSimilarity("Morgenlied", "Abendlied") < 0.75)
        #expect(TrackMatcher.titleSimilarity("Nachtlied (Remastered 2009)", "Nachtlied") == 0.9)
        #expect(TrackMatcher.titleSimilarity("Nachtlied", "Nachtlied") == 1)
        #expect(TrackMatcher.titleSimilarity("", "x") == 0)
    }

    @Test("Plan: nur echte Änderungen, Nummer n/gesamt, Kennungen; fill-only lässt Bestand")
    func plan() {
        let candidate = LookupCandidate(
            source: .musicbrainz, score: 97, artist: "Testkapelle", album: "Blaue Stunde", year: "2004",
            label: "Testlabel", catalogNumber: "TK-004", country: "DE", trackCount: 3, tracks: tracks,
            hasFullTracklist: true, coverURL: URL(string: "https://caa.test/front"),
            identifiers: LookupIdentifiers(musicBrainzReleaseID: "rel", musicBrainzReleaseGroupID: "grp",
                                           musicBrainzArtistID: "art", discogsReleaseID: nil))
        let existing = [TagProperty(key: "TITLE", value: "Morgenlied"),
                        TagProperty(key: "ARTIST", value: "Testkapelle"),
                        TagProperty(key: "ALBUM", value: "blaue stunde"),
                        TagProperty(key: "GENRE", value: "Folk")]
        var track = tracks[0]
        track.acoustID = "acoust"
        let url = URL(fileURLWithPath: "/tmp/a.mp3")

        let plan = LookupPlanner.plan(for: url, existing: existing, candidate: candidate, track: track,
                                      options: LookupPlanOptions(includeCover: true))
        let byKey = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.key, $0) })
        #expect(byKey["TITLE"] == nil, "gleicher Titel = keine Änderung")
        #expect(byKey["ALBUM"] == LookupFieldChange(key: "ALBUM", oldValue: "blaue stunde", newValue: "Blaue Stunde"))
        #expect(byKey["ALBUMARTIST"]?.newValue == "Testkapelle" && byKey["ALBUMARTIST"]?.oldValue == nil)
        #expect(byKey["TRACKNUMBER"]?.newValue == "1/3")
        #expect(byKey["DISCNUMBER"] == nil, "eine CD → keine CD-Nummer")
        #expect(byKey["DATE"]?.newValue == "2004")
        #expect(byKey["LABEL"]?.newValue == "Testlabel" && byKey["CATALOGNUMBER"]?.newValue == "TK-004")
        #expect(byKey["RELEASECOUNTRY"]?.newValue == "DE")
        #expect(byKey["MUSICBRAINZ_ALBUMID"]?.newValue == "rel")
        #expect(byKey["MUSICBRAINZ_RELEASEGROUPID"]?.newValue == "grp")
        #expect(byKey["MUSICBRAINZ_ARTISTID"]?.newValue == "art")
        #expect(byKey["MUSICBRAINZ_TRACKID"]?.newValue == "r1")
        #expect(byKey["ACOUSTID_ID"]?.newValue == "acoust")
        #expect(byKey["DISCOGS_RELEASE_ID"] == nil)
        #expect(plan.coverURL?.absoluteString == "https://caa.test/front")

        let applied = plan.apply(to: existing)
        #expect(applied.first { $0.key == "GENRE" }?.value == "Folk", "fremde Felder bleiben")
        #expect(applied.first { $0.key == "ALBUM" }?.value == "Blaue Stunde")
        #expect(applied.filter { $0.key == "ALBUM" }.count == 1)
        #expect(applied.contains(TagProperty(key: "MUSICBRAINZ_TRACKID", value: "r1")))

        let fillOnly = LookupPlanner.plan(for: url, existing: existing, candidate: candidate, track: track,
                                          options: LookupPlanOptions(includeIdentifiers: false, overwriteExisting: false))
        #expect(!fillOnly.changes.contains { $0.key == "ALBUM" })
        #expect(fillOnly.changes.contains { $0.key == "ALBUMARTIST" })
        #expect(!fillOnly.changes.contains { $0.key.hasPrefix("MUSICBRAINZ") })
        #expect(fillOnly.coverURL == nil)

        // Ohne zugeordneten Titel: nur Album-Felder, kein Titel/keine Nummer.
        let albumOnly = LookupPlanner.plan(for: url, existing: [], candidate: candidate, track: nil)
        #expect(!albumOnly.changes.contains { $0.key == "TITLE" || $0.key == "TRACKNUMBER" || $0.key == "MUSICBRAINZ_TRACKID" })
        #expect(albumOnly.changes.contains { $0.key == "ARTIST" && $0.newValue == "Testkapelle" })
    }

    @Test("Suchbegriffe aus Dateien: gemeinsame Werte, Album-Interpret vor Interpret")
    func queryFromFiles() {
        var a = file("a.mp3", title: "Eins")
        a.artist = "Solist"; a.albumArtist = "Kapelle"; a.album = "Blau"; a.year = "2004"
        var b = file("b.mp3", title: "Zwei")
        b.artist = "Gast"; b.albumArtist = "Kapelle"; b.album = "Blau"; b.year = "2004"
        let query = LookupFileInfo.query(for: [a, b])
        #expect(query == LookupQuery(artist: "Kapelle", album: "Blau", title: "", year: "2004", trackCount: 2))
        let single = LookupFileInfo.query(for: [a])
        #expect(single.title == "Eins" && single.trackCount == nil)
        var c = b; c.album = "Rot"
        #expect(LookupFileInfo.query(for: [a, c]).album == "", "uneinheitliches Album → leer")
    }
}

@Suite("Online-Lookup: Service mit Stub")
struct OnlineLookupServiceTests {
    private func makeService(_ client: StubClient, credentials: LookupCredentials = LookupCredentials(),
                             fingerprinter: @escaping OnlineLookupService.Fingerprinter = { _ in
                                 AudioFingerprint(durationSeconds: 181, fingerprint: "AQAD")
                             }) -> OnlineLookupService {
        OnlineLookupService(client: client, appVersion: "0.34.0", credentials: credentials,
                            fingerprinter: fingerprinter, now: { 0 }, sleep: { _ in })
    }

    @Test("MusicBrainz: Suche, Details, Cover — Anfragen tragen User-Agent, Details behalten Score")
    func musicBrainzFlow() async throws {
        let client = StubClient { request in
            let path = request.url.path
            if path == "/ws/2/release" { return json(mbReleaseSearchJSON) }
            if path.hasPrefix("/ws/2/release/") { return json(mbReleaseDetailsJSON) }
            if path.hasSuffix("/front-500") {
                return LookupHTTPResponse(statusCode: 200, body: Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 12)))
            }
            return LookupHTTPResponse(statusCode: 404)
        }
        let service = makeService(client)
        let query = LookupQuery(artist: "Testkapelle", album: "Blaue Stunde", trackCount: 2)
        let candidates = try await service.search(query, source: .musicbrainz)
        #expect(candidates.count == 1)
        let search = try #require(client.requests.first)
        #expect(search.headers["User-Agent"] == "TagExplosion/0.34.0 (https://github.com/DanielMuellerIR/tag_explosion)")
        #expect(search.url.query()?.contains("fmt=json") == true)
        #expect(search.url.query()?.contains("tracks%3A2") == true)
        #expect(search.url.host() == "musicbrainz.org")

        let detailed = try await service.details(for: candidates[0])
        #expect(detailed.hasFullTracklist && detailed.tracks.count == 3)
        #expect(detailed.score == 97 && detailed.source == .musicbrainz)
        #expect(client.requests[1].url.path == "/ws/2/release/11111111-aaaa-bbbb-cccc-000000000001")
        #expect(client.requests[1].url.query()?.contains("inc=recordings%2Bartist-credits%2Blabels%2Brelease-groups") == true)

        let cover = try await service.coverData(for: detailed)
        #expect(cover?.count == 16)
        #expect(client.requests[2].headers["Accept"] == "image/*")
    }

    @Test("MusicBrainz ohne Album sucht Recordings; Cover 404 → nil")
    func recordingSearchAndMissingCover() async throws {
        let client = StubClient { request in
            if request.url.path == "/ws/2/recording" { return json(mbRecordingSearchJSON) }
            return LookupHTTPResponse(statusCode: 404)
        }
        let service = makeService(client)
        let candidates = try await service.search(LookupQuery(artist: "Testkapelle", title: "Morgenlied"), source: .musicbrainz)
        #expect(candidates.first?.tracks.first?.title == "Morgenlied")
        #expect(try await service.coverData(for: candidates[0]) == nil)
        await #expect(throws: LookupError.emptyQuery) {
            _ = try await service.search(LookupQuery(), source: .musicbrainz)
        }
    }

    @Test("Discogs: Token nur im Header, nie in der URL; Details über die Release-ID")
    func discogsFlow() async throws {
        let client = StubClient { request in
            if request.url.path == "/database/search" { return json(discogsSearchJSON) }
            if request.url.path == "/releases/123456" { return json(discogsReleaseJSON) }
            return LookupHTTPResponse(statusCode: 404)
        }
        let service = makeService(client, credentials: LookupCredentials(discogsToken: "geheim123"))
        let candidates = try await service.search(LookupQuery(artist: "Testkapelle", album: "Blaue Stunde", year: "2004"),
                                                  source: .discogs)
        #expect(candidates.count == 1)
        let search = try #require(client.requests.first)
        #expect(search.headers["Authorization"] == "Discogs token=geheim123")
        #expect(!search.url.absoluteString.contains("geheim123"))
        #expect(search.url.query()?.contains("release_title=Blaue%20Stunde") == true)
        #expect(search.url.query()?.contains("year=2004") == true)
        let detailed = try await service.details(for: candidates[0])
        #expect(detailed.tracks.count == 3 && detailed.source == .discogs)
        #expect(detailed.identifiers.discogsReleaseID == "123456")
    }

    @Test("AcoustID: ohne Key keine Anfrage; mit Key POST-Body statt URL; Details ergänzen die Trackliste")
    func acoustIDFlow() async throws {
        let client = StubClient { request in
            if request.url.path == "/v2/lookup" { return json(acoustIDLookupJSON) }
            if request.url.path.hasPrefix("/ws/2/release/") { return json(mbReleaseDetailsJSON) }
            return LookupHTTPResponse(statusCode: 404)
        }
        let withoutKey = makeService(client)
        await #expect(throws: LookupError.missingCredential(source: .acoustid, name: "client key")) {
            _ = try await withoutKey.identify(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        }
        #expect(client.requests.isEmpty)

        let service = makeService(client, credentials: LookupCredentials(acoustIDKey: "key42"))
        let candidates = try await service.identify(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        let lookup = try #require(client.requests.first)
        #expect(lookup.method == "POST")
        #expect(!lookup.url.absoluteString.contains("key42"))
        let body = String(decoding: lookup.body ?? Data(), as: UTF8.self)
        #expect(body.contains("client=key42") && body.contains("fingerprint=AQAD") && body.contains("duration=181"))
        #expect(body.contains("meta=recordings%2Breleasegroups"))
        #expect(candidates.first?.source == .acoustid)

        let detailed = try await service.details(for: candidates[0])
        #expect(detailed.source == .acoustid && detailed.score == 96)
        #expect(detailed.tracks.count == 3)
        #expect(detailed.tracks[0].acoustID == "ffffffff-1111-2222-3333-444444444444", "AcoustID bleibt am erkannten Titel")
        #expect(detailed.tracks[1].acoustID == nil)

        // Eine Positionsnummer darf eine abweichende Recording-ID nicht überstimmen.
        var shifted = candidates[0]
        shifted.tracks[0].recordingID = "rrrrrrrr-0000-0000-0000-000000000002"
        let matchedByID = try await service.details(for: shifted)
        #expect(matchedByID.tracks[0].acoustID == nil)
        #expect(matchedByID.tracks[1].acoustID == candidates[0].tracks[0].acoustID)
        shifted.tracks[0].recordingID = "unknown-recording"
        let missingID = try await service.details(for: shifted)
        #expect(missingID.tracks.allSatisfy { $0.acoustID == nil })
        shifted.tracks[0].recordingID = nil
        let matchedByPosition = try await service.details(for: shifted)
        #expect(matchedByPosition.tracks[0].acoustID == candidates[0].tracks[0].acoustID)
    }

    @Test("fpcalc fehlt → toolNotFound, ohne Netzzugriff")
    func missingFpcalc() async {
        let client = StubClient { _ in LookupHTTPResponse(statusCode: 500) }
        let service = makeService(client, credentials: LookupCredentials(acoustIDKey: "k")) { _ in
            throw TagError.toolNotFound(name: Fpcalc.toolName)
        }
        await #expect(throws: TagError.toolNotFound(name: "fpcalc")) {
            _ = try await service.identify(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"))
        }
        #expect(client.requests.isEmpty)
    }

    @Test("Zugangsdaten aus der Umgebung; leere Werte zählen als fehlend")
    func credentials() {
        let creds = LookupCredentials.fromEnvironment(["TAGX_DISCOGS_TOKEN": " t ", "TAGX_ACOUSTID_KEY": ""])
        #expect(creds == LookupCredentials(discogsToken: "t", acoustIDKey: nil))
    }
}

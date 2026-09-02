// Fassade über die drei Dienste: Suche, Details (Trackliste), Cover.
// Ein Ratenbegrenzer je Dienst; die Freigabe („Online-Dienste erlauben")
// prüft der Aufrufer über `OnlineLookupConsent.require(enabled:)` — die
// Fassade selbst greift erst bei einem Aufruf ins Netz, nie von sich aus.
import Foundation

/// Zugangsdaten. Nur aus Einstellungen (Keychain) oder Umgebung, nie aus
/// Kommandozeilenargumenten.
public struct LookupCredentials: Sendable, Equatable {
    public var discogsToken: String?
    public var acoustIDKey: String?

    public init(discogsToken: String? = nil, acoustIDKey: String? = nil) {
        self.discogsToken = discogsToken
        self.acoustIDKey = acoustIDKey
    }

    public static let discogsEnvironmentVariable = "TAGX_DISCOGS_TOKEN"
    public static let acoustIDEnvironmentVariable = "TAGX_ACOUSTID_KEY"

    /// CLI: `TAGX_DISCOGS_TOKEN` und `TAGX_ACOUSTID_KEY`.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LookupCredentials {
        func value(_ name: String) -> String? {
            let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        return LookupCredentials(discogsToken: value(discogsEnvironmentVariable),
                                 acoustIDKey: value(acoustIDEnvironmentVariable))
    }
}

/// Basis-URLs der Dienste; Tests können sie auf einen Stub zeigen lassen.
public struct LookupEndpoints: Sendable, Equatable {
    public var musicBrainz: URL
    public var coverArtArchive: URL
    public var discogs: URL
    public var acoustID: URL

    public init(musicBrainz: URL, coverArtArchive: URL, discogs: URL, acoustID: URL) {
        self.musicBrainz = musicBrainz
        self.coverArtArchive = coverArtArchive
        self.discogs = discogs
        self.acoustID = acoustID
    }

    public static let production = LookupEndpoints(
        musicBrainz: URL(string: "https://musicbrainz.org/ws/2")!,
        coverArtArchive: URL(string: "https://coverartarchive.org")!,
        discogs: URL(string: "https://api.discogs.com")!,
        acoustID: URL(string: "https://api.acoustid.org")!)
}

public final class OnlineLookupService: Sendable {
    public typealias Fingerprinter = @Sendable (URL) throws -> AudioFingerprint

    private let musicBrainz: MusicBrainzClient
    private let discogs: DiscogsClient
    private let acoustID: AcoustIDClient
    private let fingerprinter: Fingerprinter
    public let userAgent: String

    /// `appVersion` landet im User-Agent; `sleep` und `now` sind nur für
    /// Tests austauschbar (kein echtes Warten).
    public init(client: LookupHTTPClient = URLSessionLookupClient(),
                appVersion: String,
                credentials: LookupCredentials = LookupCredentials(),
                endpoints: LookupEndpoints = .production,
                fingerprinter: @escaping Fingerprinter = { try Fpcalc.fingerprint(of: $0) },
                now: @escaping RateLimiter.Clock = { Date().timeIntervalSinceReferenceDate },
                sleep: @escaping RateLimiter.Sleep = LookupSleep.real) {
        let userAgent = OnlineLookupConsent.userAgent(version: appVersion)
        self.userAgent = userAgent
        func transport() -> LookupTransport {
            LookupTransport(client: client,
                            limiter: RateLimiter(minimumInterval: 1.0, now: now, sleep: sleep),
                            userAgent: userAgent, sleep: sleep)
        }
        musicBrainz = MusicBrainzClient(transport: transport(), baseURL: endpoints.musicBrainz,
                                        coverArtBaseURL: endpoints.coverArtArchive)
        discogs = DiscogsClient(transport: transport(), baseURL: endpoints.discogs,
                                token: credentials.discogsToken)
        acoustID = AcoustIDClient(transport: transport(), baseURL: endpoints.acoustID,
                                  clientKey: credentials.acoustIDKey,
                                  coverArtBaseURL: endpoints.coverArtArchive)
        self.fingerprinter = fingerprinter
    }

    /// Suche nach Suchbegriffen. MusicBrainz: mit Album die Release-Suche,
    /// sonst (nur Titel) die Recording-Suche. AcoustID braucht eine Datei —
    /// siehe `identify(fileURL:)`.
    public func search(_ query: LookupQuery, source: LookupSource) async throws -> [LookupCandidate] {
        guard !query.isEmpty else { throw LookupError.emptyQuery }
        switch source {
        case .musicbrainz:
            if query.album.isEmpty, !query.title.isEmpty {
                return try await musicBrainz.searchRecordings(query)
            }
            return try await musicBrainz.searchReleases(query)
        case .discogs:
            return try await discogs.searchReleases(query)
        case .acoustid:
            throw LookupError.invalidResponse(source: .acoustid, reason: "AcoustID identifies files, not search terms")
        }
    }

    /// Datei per Fingerabdruck erkennen (fpcalc lokal, dann AcoustID).
    public func identify(fileURL: URL) async throws -> [LookupCandidate] {
        let fingerprint = try fingerprinter(fileURL)
        return try await acoustID.lookup(fingerprint)
    }

    /// Vollständige Trackliste des Kandidaten nachladen. Bei AcoustID- und
    /// MusicBrainz-Recording-Treffern über die Release-ID; die dabei
    /// bekannten AcoustID-Kennungen bleiben am passenden Titel erhalten.
    public func details(for candidate: LookupCandidate) async throws -> LookupCandidate {
        if candidate.hasFullTracklist { return candidate }
        var detailed: LookupCandidate
        switch candidate.source {
        case .discogs:
            guard let id = candidate.identifiers.discogsReleaseID else { throw LookupError.noDetailsAvailable }
            detailed = try await discogs.release(id: id)
        case .musicbrainz, .acoustid:
            guard let id = candidate.identifiers.musicBrainzReleaseID else { throw LookupError.noDetailsAvailable }
            detailed = try await musicBrainz.release(id: id)
        }
        detailed.source = candidate.source
        detailed.score = candidate.score
        if detailed.identifiers.musicBrainzReleaseGroupID == nil {
            detailed.identifiers.musicBrainzReleaseGroupID = candidate.identifiers.musicBrainzReleaseGroupID
        }
        if detailed.identifiers.musicBrainzArtistID == nil {
            detailed.identifiers.musicBrainzArtistID = candidate.identifiers.musicBrainzArtistID
        }
        // AcoustID-Kennung an den wiedergefundenen Titel heften.
        for known in candidate.tracks where known.acoustID != nil {
            if let index = detailed.tracks.firstIndex(where: {
                ($0.recordingID != nil && $0.recordingID == known.recordingID)
                    || ($0.number == known.number && $0.discNumber == known.discNumber && known.number > 0)
            }) {
                detailed.tracks[index].acoustID = known.acoustID
            }
        }
        return detailed
    }

    /// Cover laden; nil, wenn der Dienst keins hat (404) oder die Antwort
    /// kein Bild ist. Die Bytes gehen danach den normalen Cover-Weg.
    public func coverData(for candidate: LookupCandidate) async throws -> Data? {
        guard let url = candidate.coverURL else { return nil }
        let transport = candidate.source == .discogs ? discogs.transport : musicBrainz.transport
        do {
            let response = try await transport.send(
                LookupHTTPRequest(url: url, headers: ["Accept": "image/*"]), source: candidate.source)
            guard Artwork.sniffMimeType(from: response.body) != nil else { return nil }
            return response.body
        } catch LookupError.httpStatus(_, let status) where status == 404 {
            return nil
        }
    }
}

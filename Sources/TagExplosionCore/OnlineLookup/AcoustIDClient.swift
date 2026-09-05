// AcoustID: Audio-Fingerabdruck über das externe Programm `fpcalc`
// (Chromaprint, Homebrew-Formel `chromaprint`) und Abfrage von
// api.acoustid.org. Der Dienst liefert MusicBrainz-Kennungen zurück; die
// vollständige Trackliste holt danach der MusicBrainz-Client.
import Foundation

/// Ergebnis von `fpcalc -json`.
public struct AudioFingerprint: Sendable, Equatable {
    public var durationSeconds: Int
    public var fingerprint: String

    public init(durationSeconds: Int, fingerprint: String) {
        self.durationSeconds = durationSeconds
        self.fingerprint = fingerprint
    }
}

/// Wrapper um `fpcalc` — gleicher Prozessweg wie mediainfo/exiftool.
public enum Fpcalc {
    public static let toolName = "fpcalc"
    /// Homebrew-Formel, die `fpcalc` mitbringt (für das Installationsangebot).
    public static let homebrewFormula = "chromaprint"

    public static let executableCandidates: [String] = [
        "fpcalc",
        "/opt/homebrew/bin/fpcalc",
        "/usr/local/bin/fpcalc",
        "/usr/bin/fpcalc",
    ]

    public static func locateExecutable() throws -> String {
        try ExternalToolRunner.locateTool(candidates: executableCandidates, name: toolName)
    }

    /// Fingerabdruck einer Datei. Wirft `toolNotFound("fpcalc")`, wenn das
    /// Programm fehlt — App und CLI bieten dann die Installation an.
    public static func fingerprint(of url: URL) throws -> AudioFingerprint {
        let exe = try locateExecutable()
        let output = try ExternalToolRunner.run(exe, ["-json", ExternalToolRunner.toolArgument(for: url)])
        return try parse(output)
    }

    static func parse(_ data: Data) throws -> AudioFingerprint {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = LookupJSON.double(object["duration"]),
              let fingerprint = object["fingerprint"] as? String, !fingerprint.isEmpty else {
            throw TagError.toolFailed(name: toolName, exitCode: 0, stderr: "unreadable fpcalc output")
        }
        return AudioFingerprint(durationSeconds: Int(duration.rounded()), fingerprint: fingerprint)
    }
}

struct AcoustIDClient: Sendable {
    let transport: LookupTransport
    /// `https://api.acoustid.org`
    let baseURL: URL
    let clientKey: String?
    let coverArtBaseURL: URL

    /// Lookup per POST: Der Client-Key und der Fingerabdruck stehen im Body,
    /// nicht in der URL.
    func lookup(_ fingerprint: AudioFingerprint) async throws -> [LookupCandidate] {
        guard let clientKey, !clientKey.isEmpty else {
            throw LookupError.missingCredential(source: .acoustid, name: "client key")
        }
        guard let url = URL(string: baseURL.absoluteString + "/v2/lookup") else {
            throw LookupError.invalidResponse(source: .acoustid, reason: "cannot build URL")
        }
        let body = LookupJSON.encodeQuery([
            ("client", clientKey),
            ("format", "json"),
            ("meta", "recordings+releasegroups+releases+tracks+compress"),
            ("duration", "\(fingerprint.durationSeconds)"),
            ("fingerprint", fingerprint.fingerprint),
        ])
        let request = LookupHTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8))
        let response = try await transport.send(request, source: .acoustid)
        return try Self.parseLookup(response.body, coverArtBaseURL: coverArtBaseURL)
    }

    /// Je (Treffer × Recording × Release) ein Kandidat mit dem einen
    /// erkannten Titel; die Trackliste vervollständigt später MusicBrainz.
    static func parseLookup(_ data: Data, coverArtBaseURL: URL) throws -> [LookupCandidate] {
        let object = try LookupJSON.object(from: data, source: .acoustid)
        let status = LookupJSON.string(object["status"])
        guard status == "ok" else {
            let error = object["error"] as? [String: Any]
            throw LookupError.invalidResponse(
                source: .acoustid, reason: error.map { LookupJSON.string($0["message"]) } ?? "status \(status)")
        }
        var candidates: [LookupCandidate] = []
        var seen: Set<String> = []
        for result in LookupJSON.array(object["results"]) {
            let acoustID = LookupJSON.string(result["id"])
            let score = Int(((LookupJSON.double(result["score"]) ?? 0) * 100).rounded())
            for recording in LookupJSON.array(result["recordings"]) {
                let recordingID = LookupJSON.string(recording["id"])
                let recordingTitle = LookupJSON.string(recording["title"])
                let artists = LookupJSON.array(recording["artists"])
                let artistName = artists.map { LookupJSON.string($0["name"]) + LookupJSON.string($0["joinphrase"]) }
                    .joined().trimmingCharacters(in: .whitespaces)
                let artistID = artists.first.map { LookupJSON.string($0["id"]) }.flatMap { $0.isEmpty ? nil : $0 }
                let duration = LookupJSON.int(recording["duration"]).map { $0 * 1000 }

                // Releases stehen je nach `meta` flach unter dem Recording oder
                // in den Release-Gruppen — beides einsammeln.
                var releases: [(release: [String: Any], groupID: String?)] = []
                for release in LookupJSON.array(recording["releases"]) {
                    releases.append((release, nil))
                }
                for group in LookupJSON.array(recording["releasegroups"]) {
                    let groupID = LookupJSON.string(group["id"])
                    for release in LookupJSON.array(group["releases"]) {
                        releases.append((release, groupID.isEmpty ? nil : groupID))
                    }
                }
                for (release, groupID) in releases {
                    let releaseID = LookupJSON.string(release["id"])
                    guard !releaseID.isEmpty, seen.insert(releaseID + recordingID).inserted else { continue }
                    var number = 0
                    var disc = 1
                    for medium in LookupJSON.array(release["mediums"]) {
                        if let track = LookupJSON.array(medium["tracks"]).first {
                            number = LookupJSON.int(track["position"]) ?? 0
                            disc = LookupJSON.int(medium["position"]) ?? 1
                            break
                        }
                    }
                    let date = release["date"] as? [String: Any]
                    let year = date.flatMap { LookupJSON.int($0["year"]) }.map(String.init) ?? ""
                    candidates.append(LookupCandidate(
                        source: .acoustid,
                        score: score,
                        artist: artistName,
                        album: LookupJSON.string(release["title"]),
                        year: year,
                        country: LookupJSON.string(release["country"]),
                        trackCount: LookupJSON.int(release["track_count"]),
                        tracks: [LookupTrack(
                            number: number, discNumber: disc, title: recordingTitle,
                            durationMilliseconds: duration,
                            artist: artistName.isEmpty ? nil : artistName,
                            recordingID: recordingID.isEmpty ? nil : recordingID,
                            acoustID: acoustID.isEmpty ? nil : acoustID)],
                        hasFullTracklist: false,
                        coverURL: MusicBrainzClient.coverURL(releaseID: releaseID, base: coverArtBaseURL),
                        identifiers: LookupIdentifiers(
                            musicBrainzReleaseID: releaseID,
                            musicBrainzReleaseGroupID: groupID,
                            musicBrainzArtistID: artistID)))
                }
            }
        }
        return candidates.sorted { $0.score > $1.score }
    }
}

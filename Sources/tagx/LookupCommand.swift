// tagx lookup — Online-Lookup über MusicBrainz, Discogs oder AcoustID.
// Vorschau per Voreinstellung: Kandidaten, Zuordnung Datei → Titel und der
// Änderungsplan (Feld: alt -> neu). Geschrieben wird erst mit --apply, und
// dann über den normalen Weg (Papierkorb-Sicherung + atomarer Austausch).
//
// Kein Netzzugriff ohne Freigabe: Ohne TAGX_ONLINE=1 endet der Befehl mit
// einem Hinweis (Exit 1). Zugangsdaten kommen nur aus der Umgebung
// (TAGX_DISCOGS_TOKEN, TAGX_ACOUSTID_KEY), nie aus Argumenten.
import ArgumentParser
import Foundation
import TagExplosionCore

/// Exit 5: kein Kandidat gefunden.
let noResultsExitCode = ExitCode(5)

extension LookupSource: ExpressibleByArgument {}

struct Lookup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up a release online and preview tag changes (dry run unless --apply).",
        discussion: """
            Sources: musicbrainz (default; artist + album, or artist + title for a \
            single file), discogs (optional token in TAGX_DISCOGS_TOKEN), acoustid \
            (audio fingerprint via fpcalc; needs TAGX_ACOUSTID_KEY). Nothing is sent \
            unless TAGX_ONLINE=1 is set — read `tagx lookup --privacy` first. \
            Exit 5 when nothing matches.
            """
    )

    @Option(name: .long, help: "musicbrainz, discogs or acoustid") var source: LookupSource = .musicbrainz
    @Option(name: .long, help: "Search term (default: from the files' tags)") var artist: String?
    @Option(name: .long, help: "Search term (default: from the files' tags)") var album: String?
    @Option(name: .long, help: "Search term for a single title (MusicBrainz recording search)") var title: String?
    @Option(name: .long, help: "Year hint (Discogs only)") var year: String?
    @Option(name: .long, help: "Pick candidate n (1-based; default 1)") var choose: Int = 1
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .long, help: "Write the plan to the files (default: preview only)") var apply = false
    @Flag(name: .long, help: "Also fetch and embed the cover") var cover = false
    @Flag(name: .customLong("no-ids"), help: "Do not write MusicBrainz/Discogs/AcoustID identifiers") var noIDs = false
    @Flag(name: .customLong("fill-only"), help: "Only fill empty fields, keep existing values") var fillOnly = false
    @Flag(name: .long, help: "Print the privacy notice and exit") var privacy = false
    @OptionGroup var safeMode: SafeModeOptions
    @Argument(help: "Media file(s) — one album, or a single title") var files: [String] = []

    // MARK: JSON-Bericht

    struct Report: Codable {
        struct Assignment: Codable {
            var file: String
            var track: LookupTrack?
            var reason: LookupAssignment.Reason
            var changes: [LookupFieldChange]
            var cover: Bool
        }
        struct Outcome: Codable {
            var file: String
            var written: Bool
            var error: String?
        }
        var source: LookupSource
        var query: LookupQuery
        var candidates: [LookupCandidate]
        var chosen: Int
        var assignments: [Assignment]
        var applied: Bool
        var results: [Outcome]?
    }

    /// Gelesener Stand je Datei; der Stempel wandert bis in `TagFile.write`,
    /// damit eine zwischen Lesen und Schreiben fremd geänderte Datei nicht
    /// überschrieben wird — die Netzantwort kann Sekunden dauern.
    private struct LoadedFile {
        let url: URL
        let data: TagData
        let stamp: FileStamp
        let info: LookupFileInfo
    }

    func run() async throws {
        if privacy {
            print(OnlineLookupConsent.privacyNoticeEnglish)
            print("")
            print(OnlineLookupConsent.privacyNoticeGerman)
            return
        }
        guard !files.isEmpty else { throw ValidationError("Provide at least one media file.") }
        guard choose >= 1 else { throw ValidationError("--choose expects a number from 1.") }
        safeMode.apply()

        // Freigabe zuerst — vor jedem Lesen und lange vor jedem Netzzugriff.
        do {
            try OnlineLookupConsent.require(enabled: OnlineLookupConsent.isEnabled())
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n\(OnlineLookupConsent.cliHint)\n".utf8))
            throw ExitCode(1)
        }

        let loaded = try files.map { path -> LoadedFile in
            let url = try resolveFile(path)
            let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
            return LoadedFile(url: url, data: snapshot.value, stamp: snapshot.stamp,
                              info: LookupFileInfo(url: url, data: snapshot.value))
        }
        var query = LookupFileInfo.query(for: loaded.map(\.info))
        if let artist { query.artist = artist }
        if let album { query.album = album }
        if let title { query.title = title }
        if let year { query.year = year }

        let service = OnlineLookupService(appVersion: tagxVersion, credentials: .fromEnvironment())
        let candidates: [LookupCandidate]
        do {
            if source == .acoustid {
                // Der Fingerabdruck der ersten Datei; die Trackliste des
                // Treffers ordnet danach alle Dateien zu.
                candidates = try await service.identify(fileURL: loaded[0].url)
            } else {
                candidates = try await service.search(query, source: source)
            }
        } catch TagError.toolNotFound(let name) where name == Fpcalc.toolName {
            FileHandle.standardError.write(Data(
                "fpcalc not found — install Chromaprint (brew install \(Fpcalc.homebrewFormula)).\n".utf8))
            throw ExitCode(1)
        }
        guard !candidates.isEmpty else {
            if json {
                try printJSON(Report(source: source, query: query, candidates: [], chosen: 0,
                                     assignments: [], applied: false, results: nil))
            } else {
                FileHandle.standardError.write(Data("No results for \(describe(query)) on \(source.displayName)\n".utf8))
            }
            throw noResultsExitCode
        }
        guard choose <= candidates.count else {
            throw ValidationError("--choose \(choose) is out of range (\(candidates.count) candidate(s)).")
        }

        let detailed = try await service.details(for: candidates[choose - 1])
        let assignments = TrackMatcher.assign(files: loaded.map(\.info), tracks: detailed.tracks)
        let options = LookupPlanOptions(includeIdentifiers: !noIDs, overwriteExisting: !fillOnly,
                                        includeCover: cover)
        let plans = zip(loaded, assignments).map { file, assignment in
            LookupPlanner.plan(for: file.url, existing: file.data.properties, candidate: detailed,
                               track: assignment.track, options: options)
        }
        var report = Report(
            source: source, query: query, candidates: candidates, chosen: choose,
            assignments: zip(assignments, plans).map { assignment, plan in
                Report.Assignment(file: assignment.fileURL.path, track: assignment.track,
                                  reason: assignment.reason, changes: plan.changes,
                                  cover: plan.coverURL != nil)
            },
            applied: false, results: nil)

        guard apply else {
            if json {
                try printJSON(report)
            } else {
                printCandidates(candidates, chosen: choose)
                printPlans(detailed, assignments: assignments, plans: plans)
                print("Dry run: use --apply to write, --choose n to pick another candidate")
            }
            return
        }

        // Cover einmal laden; nur wenn der Plan es vorsieht und es ein Bild ist.
        var coverArtwork: Artwork?
        if cover, let data = try await service.coverData(for: detailed) {
            coverArtwork = Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                                   pictureType: "Front Cover")
        }

        var outcomes: [Report.Outcome] = []
        var failed = false
        for (file, (assignment, plan)) in zip(loaded, zip(assignments, plans)) {
            let wantsCover = plan.coverURL != nil && coverArtwork != nil
            guard assignment.track != nil || !plan.changes.isEmpty else {
                outcomes.append(.init(file: file.url.path, written: false, error: "no matching track"))
                continue
            }
            guard !plan.changes.isEmpty || wantsCover else {
                outcomes.append(.init(file: file.url.path, written: false, error: nil))
                continue
            }
            do {
                // Gleicher Schreibweg wie `tagx set`: Sicherung, dann atomar.
                try FileStamp.requireUnchanged(file.stamp, at: file.url)
                try TrashBackup.shared.backUp(file.url)
                try TagFile.write(properties: plan.apply(to: file.data.properties),
                                  artworks: wantsCover ? [coverArtwork!] : nil,
                                  to: file.url, expecting: file.stamp)
                outcomes.append(.init(file: file.url.path, written: true, error: nil))
            } catch {
                failed = true
                outcomes.append(.init(file: file.url.path, written: false, error: error.localizedDescription))
            }
        }
        report.applied = true
        report.results = outcomes
        if json {
            try printJSON(report)
        } else {
            for outcome in outcomes {
                let name = URL(fileURLWithPath: outcome.file).lastPathComponent
                if outcome.written {
                    print("OK \(name)")
                } else if let error = outcome.error {
                    print("SKIP \(name): \(error)")
                } else {
                    print("UNCHANGED \(name)")
                }
            }
            print("Written \(outcomes.filter(\.written).count) of \(outcomes.count) file(s)")
        }
        if failed { throw ExitCode(1) }
    }

    // MARK: Textausgabe

    private func describe(_ query: LookupQuery) -> String {
        [query.artist, query.album, query.title].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    private func printCandidates(_ candidates: [LookupCandidate], chosen: Int) {
        for (index, candidate) in candidates.enumerated() {
            let marker = index + 1 == chosen ? "*" : " "
            let id = candidate.identifiers.musicBrainzReleaseID ?? candidate.identifiers.discogsReleaseID ?? ""
            print("\(marker) \(index + 1). [\(candidate.score)] \(candidate.summary) — \(candidate.source.displayName) \(id)")
        }
    }

    private func printPlans(_ candidate: LookupCandidate, assignments: [LookupAssignment], plans: [LookupPlan]) {
        print("")
        for (assignment, plan) in zip(assignments, plans) {
            let name = assignment.fileURL.lastPathComponent
            if let track = assignment.track {
                print("\(name) -> \(track.discNumber > 1 ? "\(track.discNumber)-" : "")\(track.number). \(track.title) (\(assignment.reason.rawValue))")
            } else {
                print("\(name) -> NO MATCH")
            }
            for change in plan.changes {
                print("  \(change.key): \(change.oldValue.map { "\"\($0)\"" } ?? "(empty)") -> \"\(change.newValue)\"")
            }
            if plan.coverURL != nil { print("  COVER: \(candidate.coverURL?.absoluteString ?? "")") }
        }
    }
}

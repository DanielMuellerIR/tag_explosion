// „Online nachschlagen …": Sheet mit Suchfeldern (aus den Tags vorbelegt),
// Quelle, Kandidatenliste, Zuordnung Datei → Titel mit alt → neu je Feld
// und Cover-Vorschau. „Übernehmen" schreibt nichts auf die Platte, sondern
// setzt die Werte in den Bearbeitungspuffer der Dateien — gespeichert wird
// danach wie immer (⌘S), also über Papierkorb-Sicherung und atomaren
// Austausch.
//
// Kein Netzzugriff ohne Klick auf „Suchen"; vorher prüft das Sheet die
// Einstellung und zeigt beim ersten Mal den Datenschutzhinweis.
import SwiftUI
import TagExplosionCore

/// Knopf im Batch- und Einzel-Editor. Nur für Audio-Dateien.
struct OnlineLookupButton: View {
    let entries: [FileEntry]
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Label("Online nachschlagen …", systemImage: "globe")
        }
        .disabled(entries.isEmpty || !entries.allSatisfy { $0.kind == .audio && !$0.isReadOnly })
        .help("Tags bei MusicBrainz, Discogs oder AcoustID nachschlagen (nur auf Klick, siehe Einstellungen)")
        .sheet(isPresented: $showSheet) { OnlineLookupSheet(entries: entries) }
    }
}

/// Eine Zeile der Zuordnungstabelle.
private struct AssignmentRow: Identifiable {
    let id: URL
    let fileName: String
    let assignment: LookupAssignment
    let plan: LookupPlan

    var trackLabel: String {
        guard let track = assignment.track else { return String(localized: "— kein passender Titel —") }
        let disc = track.discNumber > 1 ? "\(track.discNumber)-" : ""
        return "\(disc)\(track.number). \(track.title)"
    }
}

struct OnlineLookupSheet: View {
    let entries: [FileEntry]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var artist = ""
    @State private var album = ""
    @State private var title = ""
    @State private var source: LookupSource = .musicbrainz
    @State private var candidates: [LookupCandidate] = []
    @State private var selectedCandidateID: String?
    @State private var detailed: LookupCandidate?
    @State private var rows: [AssignmentRow] = []
    @State private var coverData: Data?
    @State private var includeCover = true
    @State private var includeIdentifiers = true
    @State private var overwriteExisting = true
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showPrivacyNotice = false
    @State private var showBlockedNotice = false
    @State private var fpcalcOffer: BrewToolInstaller.Offer?
    @State private var installingFpcalc = false

    /// Dateiinfos für Matcher und Suchbegriffe, einmal aus den Puffern gelesen.
    private var fileInfos: [LookupFileInfo] {
        entries.map { entry in
            LookupFileInfo(url: entry.url, data: TagData(
                properties: entry.properties, artworks: [], audio: entry.audio))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Online nachschlagen")
                .font(.title3.weight(.semibold))
            searchBar
            Divider()
            HStack(alignment: .top, spacing: 12) {
                candidateList
                    .frame(minWidth: 300, idealWidth: 340)
                assignmentPane
            }
            .frame(minHeight: 320)
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620)
        .onAppear(perform: prefill)
        .alert("Daten an Online-Dienste senden?", isPresented: $showPrivacyNotice) {
            Button("Verstanden, suchen") {
                UserDefaults.standard.set(true, forKey: OnlineLookupAccess.privacyAcknowledgedDefaultsKey)
                startSearch()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(OnlineLookupAccess.privacyNotice)
        }
        .alert("Online-Dienste sind ausgeschaltet", isPresented: $showBlockedNotice) {
            Button("Einstellungen öffnen") { openSettings() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Erlauben Sie Online-Dienste in den Einstellungen, damit Tag Explosion bei MusicBrainz, Discogs oder AcoustID nachschlagen darf. Ohne diese Einstellung wird nichts gesendet.")
        }
        .confirmationDialog("fpcalc fehlt", isPresented: .init(
            get: { fpcalcOffer != nil }, set: { if !$0 { fpcalcOffer = nil } }
        ), titleVisibility: .visible) {
            if case .homebrewInstall(let brew, _) = fpcalcOffer {
                Button("Mit Homebrew installieren") { installFpcalc(brew: brew) }
            } else {
                Button("brew.sh öffnen") { NSWorkspace.shared.open(BrewToolInstaller.homebrewHelpURL) }
            }
            Button("Abbrechen", role: .cancel) { fpcalcOffer = nil }
        } message: {
            if case .homebrewInstall = fpcalcOffer {
                Text("AcoustID braucht fpcalc (Chromaprint) für den Audio-Fingerabdruck. Jetzt über Homebrew installieren (Formel „chromaprint“)?")
            } else {
                Text("AcoustID braucht fpcalc (Chromaprint), aber weder das Programm noch Homebrew wurden gefunden. Bitte zuerst Homebrew installieren.")
            }
        }
    }

    // MARK: Suche

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Quelle", selection: $source) {
                    ForEach(LookupSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(width: 200)
                if source == .acoustid {
                    Text("Fingerabdruck der ersten Datei (fpcalc), Trackliste dann von MusicBrainz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Interpret", text: $artist).textFieldStyle(.roundedBorder)
                    TextField("Album", text: $album).textFieldStyle(.roundedBorder)
                    if entries.count == 1 {
                        TextField("Titel", text: $title).textFieldStyle(.roundedBorder)
                    }
                }
                Button {
                    requestSearch()
                } label: {
                    Label("Suchen", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || (source != .acoustid && artist.isEmpty && album.isEmpty && title.isEmpty))
            }
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small) }
                if installingFpcalc {
                    Text("Installiere chromaprint …").font(.caption)
                }
                if let statusMessage {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
        }
    }

    private func prefill() {
        let query = LookupFileInfo.query(for: fileInfos)
        artist = query.artist
        album = query.album
        title = query.title
        includeCover = entries.contains { $0.artworks.isEmpty }
    }

    /// Erst Einstellung, dann Hinweis, dann Netz.
    private func requestSearch() {
        switch OnlineLookupAccess.decision(allowed: OnlineLookupAccess.isAllowed,
                                           acknowledged: OnlineLookupAccess.isPrivacyAcknowledged) {
        case .blocked: showBlockedNotice = true
        case .needsPrivacyConsent: showPrivacyNotice = true
        case .ready: startSearch()
        }
    }

    private func makeService() -> OnlineLookupService {
        OnlineLookupService(appVersion: OnlineLookupAccess.appVersion,
                            credentials: OnlineLookupAccess.credentials())
    }

    private func startSearch() {
        guard OnlineLookupAccess.isAllowed else { showBlockedNotice = true; return }
        errorMessage = nil
        statusMessage = nil
        candidates = []
        selectedCandidateID = nil
        detailed = nil
        rows = []
        coverData = nil
        isBusy = true
        let query = LookupQuery(artist: artist, album: album, title: title,
                                trackCount: entries.count > 1 ? entries.count : nil)
        let source = source
        let firstFile = entries.first?.url
        let service = makeService()
        Task {
            defer { isBusy = false }
            do {
                let found: [LookupCandidate]
                if source == .acoustid, let firstFile {
                    found = try await Task.detached { try await service.identify(fileURL: firstFile) }.value
                } else {
                    found = try await service.search(query, source: source)
                }
                candidates = found
                statusMessage = found.isEmpty
                    ? String(localized: "Keine Treffer.")
                    : String(localized: "\(found.count) Kandidaten — einen auswählen.")
                if let first = found.first {
                    selectedCandidateID = first.id
                    await loadDetails(for: first, service: service)
                }
            } catch TagError.toolNotFound(let name) where name == Fpcalc.toolName {
                fpcalcOffer = BrewToolInstaller.offer(
                    missingTools: [Fpcalc.homebrewFormula], installDeclined: false,
                    brewExecutable: BrewToolInstaller.resolveHomebrew())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func installFpcalc(brew: URL) {
        fpcalcOffer = nil
        installingFpcalc = true
        Task {
            defer { installingFpcalc = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BrewToolInstaller.install(brewExecutable: brew, formulae: [Fpcalc.homebrewFormula]) {
                        (try? Fpcalc.locateExecutable()) != nil
                    }
                }.value
                statusMessage = String(localized: "fpcalc ist jetzt verfügbar — bitte erneut suchen.")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Kandidaten

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kandidaten").font(.headline)
            List(candidates, selection: $selectedCandidateID) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.artist) – \(candidate.album)")
                        .lineLimit(1)
                    Text(candidateDetails(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(candidate.id)
            }
            .onChange(of: selectedCandidateID) { _, newValue in
                guard let newValue, let candidate = candidates.first(where: { $0.id == newValue }),
                      detailed?.id != newValue else { return }
                let service = makeService()
                Task { await loadDetails(for: candidate, service: service) }
            }
        }
    }

    private func candidateDetails(_ candidate: LookupCandidate) -> String {
        var parts = ["\(candidate.score) %", candidate.source.displayName]
        if !candidate.year.isEmpty { parts.append(candidate.year) }
        if !candidate.country.isEmpty { parts.append(candidate.country) }
        if !candidate.label.isEmpty { parts.append(candidate.label) }
        if !candidate.catalogNumber.isEmpty { parts.append(candidate.catalogNumber) }
        if let count = candidate.trackCount { parts.append(String(localized: "\(count) Titel")) }
        return parts.joined(separator: " · ")
    }

    /// Trackliste nachladen, zuordnen, Plan bauen, Cover-Vorschau holen.
    private func loadDetails(for candidate: LookupCandidate, service: OnlineLookupService) async {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            let full = try await service.details(for: candidate)
            detailed = full
            rebuildRows()
            coverData = nil
            if includeCover, full.coverURL != nil {
                coverData = try await service.coverData(for: full)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rebuildRows() {
        guard let detailed else { rows = []; return }
        let infos = fileInfos
        let assignments = TrackMatcher.assign(files: infos, tracks: detailed.tracks)
        let options = LookupPlanOptions(includeIdentifiers: includeIdentifiers,
                                        overwriteExisting: overwriteExisting, includeCover: includeCover)
        rows = zip(entries, assignments).map { entry, assignment in
            AssignmentRow(
                id: entry.url,
                fileName: entry.url.lastPathComponent,
                assignment: assignment,
                plan: LookupPlanner.plan(for: entry.url, existing: entry.properties,
                                         candidate: detailed, track: assignment.track, options: options))
        }
    }

    // MARK: Zuordnung

    private var assignmentPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                coverPreview
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zuordnung").font(.headline)
                    if let detailed {
                        Text("\(detailed.artist) – \(detailed.album)")
                            .font(.callout)
                        Text(candidateDetails(detailed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Vorhandene Werte ersetzen", isOn: $overwriteExisting)
                        .onChange(of: overwriteExisting) { rebuildRows() }
                    Toggle("Kennungen schreiben (MusicBrainz, Discogs, AcoustID)", isOn: $includeIdentifiers)
                        .onChange(of: includeIdentifiers) { rebuildRows() }
                    Toggle("Cover übernehmen", isOn: $includeCover)
                        .onChange(of: includeCover) { rebuildRows() }
                }
                .font(.caption)
                Spacer()
            }
            List(rows) { row in
                DisclosureGroup {
                    if row.plan.changes.isEmpty {
                        Text("Keine Änderungen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(row.plan.changes, id: \.key) { change in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(change.key)
                                .font(.caption.monospaced())
                                .frame(width: 200, alignment: .leading)
                            Text(change.oldValue ?? "—")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .strikethrough(change.oldValue != nil)
                                .lineLimit(1)
                            Image(systemName: "arrow.right").font(.caption2)
                            Text(change.newValue)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                } label: {
                    HStack {
                        Text(row.fileName).lineLimit(1)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(row.trackLabel)
                            .foregroundStyle(row.assignment.track == nil ? .orange : .primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(row.plan.changes.count) Felder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var coverPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
            if let coverData, let image = NSImage(data: coverData) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 110)
        .help(coverData == nil ? String(localized: "Kein Cover geladen") : String(localized: "Cover-Vorschau"))
    }

    // MARK: Fuß

    private var footer: some View {
        HStack {
            Text("„Übernehmen“ trägt die Werte in den Editor ein; gespeichert wird danach wie gewohnt (⌘S, mit Papierkorb-Sicherung).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Abbrechen") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Übernehmen") { applyPlans() }
                .disabled(detailed == nil || rows.allSatisfy { $0.plan.changes.isEmpty && !(includeCover && coverData != nil) })
        }
    }

    /// Plan in die Bearbeitungspuffer übertragen — keine Datei wird angefasst.
    private func applyPlans() {
        let artwork = coverData.map { Artwork(data: $0, mimeType: Artwork.sniffMimeType(from: $0) ?? "",
                                              pictureType: "Front Cover") }
        for row in rows {
            guard let entry = entries.first(where: { $0.url == row.id }) else { continue }
            // Dateien ohne passenden Titel bekommen nur dann Album-Felder,
            // wenn es genau eine Datei ist — bei einem Album bleiben sie unberührt.
            guard row.assignment.track != nil || entries.count == 1 else { continue }
            entry.properties = row.plan.apply(to: entry.properties)
            if includeCover, let artwork {
                if entry.artworks.isEmpty {
                    entry.artworks = [artwork]
                } else {
                    entry.artworks[0] = artwork
                }
            }
        }
        dismiss()
    }
}

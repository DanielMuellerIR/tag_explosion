// Konsistenzprüfung über viele Dateien: fehlende Cover, uneinheitliche
// Album-Interpreten, Lücken in der Tracknummerierung, leere Pflichtfelder,
// doppelte Titel … Reine Prüf-Engine ohne Schreibweg: Sie bekommt fertige
// `Item`-Werte (aus Dateien gelesen oder aus den Editor-Puffern der App)
// und liefert einen `Report`, den App und CLI gleich anzeigen.
//
// Gruppierung: Dateien mit ALBUM-Tag bilden je (Album, Album-Interpret) eine
// Gruppe — beides in Kleinschreibung und ohne Randleerzeichen verglichen,
// damit Schreibvarianten in dieselbe Gruppe fallen und dort auffallen. Dateien
// ohne ALBUM werden nach Ordner gruppiert. Bilder, E-Books und Dokumente
// bekommen nur die Einzelprüfungen (Titel leer, E-Book ohne Cover).
import Foundation

public enum LibraryCheck {

    // MARK: - Regeln

    /// Schweregrad einer Regel. `hint` ist ein Hinweis (kann Absicht sein),
    /// `warning` ein wahrscheinlicher Fehler. Vergleichbar, damit
    /// `--fail-on hint` alles ab Hinweis einschließt.
    public enum Severity: String, Sendable, Codable, Comparable, CaseIterable {
        case hint
        case warning

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs == .hint && rhs == .warning
        }
    }

    /// Kennungen der Regeln. Die Roh-Werte sind zugleich die CLI-Schreibweise
    /// (`--only track-gap,missing-cover`) und die JSON-Form.
    public enum RuleCode: String, Sendable, Codable, CaseIterable, Hashable {
        /// Datei konnte nicht gelesen werden (nur beim Laden von der Platte).
        case unreadable
        case missingCover = "missing-cover"
        case coverInconsistent = "cover-inconsistent"
        case albumArtistInconsistent = "albumartist-inconsistent"
        case albumArtistMissing = "albumartist-missing"
        case trackMissing = "track-missing"
        /// Tracknummer 0 oder negativ: zwar eine Zahl, aber keine Position.
        case trackInvalid = "track-invalid"
        case trackGap = "track-gap"
        case trackDuplicate = "track-duplicate"
        case trackTotalMissing = "track-total-missing"
        case trackExceedsTotal = "track-exceeds-total"
        case discGap = "disc-gap"
        /// Disc-Nummer 0 oder negativ.
        case discInvalid = "disc-invalid"
        case discTotalMissing = "disc-total-missing"
        case discExceedsTotal = "disc-exceeds-total"
        case dateInconsistent = "date-inconsistent"
        case genreInconsistent = "genre-inconsistent"
        case albumTitleInconsistent = "album-title-inconsistent"
        case emptyTitle = "empty-title"
        case emptyArtist = "empty-artist"
        case emptyAlbum = "empty-album"
        case duplicateTitle = "duplicate-title"
        case filenameMismatch = "filename-mismatch"

        /// Schweregrad je Regel. Hinweise sind die Regeln, bei denen der
        /// Befund Absicht sein kann (verschiedene Genres auf einer
        /// Compilation, Cover in unterschiedlicher Größe, fehlende
        /// Gesamtzahl); alles andere ist eine Warnung.
        public var severity: Severity {
            switch self {
            case .coverInconsistent, .trackTotalMissing, .discTotalMissing, .genreInconsistent:
                return .hint
            default:
                return .warning
            }
        }

        /// Kurze englische Beschreibung (CLI-Konvention; die App übersetzt).
        public var title: String {
            switch self {
            case .unreadable: return "File could not be read"
            case .missingCover: return "No cover art"
            case .coverInconsistent: return "Cover size or format differs within the album"
            case .albumArtistInconsistent: return "Album artist differs within the album"
            case .albumArtistMissing: return "Several artists but no album artist"
            case .trackMissing: return "Track number missing or not a number"
            case .trackInvalid: return "Track number is zero or negative"
            case .trackGap: return "Gaps in the track numbering"
            case .trackDuplicate: return "Track number used more than once"
            case .trackTotalMissing: return "Track total missing"
            case .trackExceedsTotal: return "Track number greater than the total"
            case .discGap: return "Gaps in the disc numbering"
            case .discInvalid: return "Disc number is zero or negative"
            case .discTotalMissing: return "Disc total missing"
            case .discExceedsTotal: return "Disc number greater than the total"
            case .dateInconsistent: return "Year/date differs within the album"
            case .genreInconsistent: return "Genre differs within the album"
            case .albumTitleInconsistent: return "Album title spelled differently"
            case .emptyTitle: return "Title is empty"
            case .emptyArtist: return "Artist is empty"
            case .emptyAlbum: return "Album is empty"
            case .duplicateTitle: return "Same title, artist and duration"
            case .filenameMismatch: return "File name does not match the pattern"
            }
        }
    }

    // MARK: - Eingabe

    /// Kurzfassung eines eingebetteten Bildes — genug für den Vergleich
    /// innerhalb eines Albums, ohne die Bilddaten mitzuschleppen.
    public struct CoverSummary: Sendable, Codable, Equatable, Hashable {
        public var mimeType: String
        public var bytes: Int
        public var width: Int?
        public var height: Int?

        public init(mimeType: String, bytes: Int, width: Int? = nil, height: Int? = nil) {
            self.mimeType = mimeType
            self.bytes = bytes
            self.width = width
            self.height = height
        }

        public init(_ artwork: Artwork) {
            let size = ImagePixelSize.read(from: artwork.data)
            self.init(mimeType: artwork.resolvedMimeType, bytes: artwork.data.count,
                      width: size?.width, height: size?.height)
        }

        /// Anzeige wie "image/jpeg 500×500" (oder nur der Typ ohne Größe).
        public var label: String {
            if let width, let height { return "\(mimeType) \(width)×\(height)" }
            return mimeType.isEmpty ? "unknown format" : mimeType
        }
    }

    /// Eine zu prüfende Datei. Audio/Video liefern `properties`, `covers` und
    /// `duration`; Bilder, E-Books und Dokumente nur `title` und (E-Books)
    /// `hasCover`. `readError` ersetzt alles andere, wenn das Lesen scheiterte.
    public struct Item: Sendable, Equatable {
        public var url: URL
        public var kind: MediaFormats.Kind
        public var properties: [TagProperty]
        /// nil = das Format kann kein Cover tragen (Tracker, Matroska) — dann
        /// gibt es auch keine „fehlendes Cover"-Meldung.
        public var covers: [CoverSummary]?
        public var durationMilliseconds: Int?
        /// Titel der Nicht-Audio-Arten (Bild, E-Book, Dokument).
        public var title: String
        /// Dateiname-Felder für die Musterprüfung (siehe `PatternFields`).
        public var patternFields: [String: String]
        public var readError: String?

        public init(url: URL, kind: MediaFormats.Kind, properties: [TagProperty] = [],
                    covers: [CoverSummary]? = nil, durationMilliseconds: Int? = nil,
                    title: String = "", patternFields: [String: String] = [:],
                    readError: String? = nil) {
            self.url = url
            self.kind = kind
            self.properties = properties
            self.covers = covers
            self.durationMilliseconds = durationMilliseconds
            self.title = title
            self.patternFields = patternFields
            self.readError = readError
        }

        /// Audio-/Video-Item aus gelesenen Tag-Daten.
        public init(url: URL, tags: TagData) {
            let embeds = MediaFormats.supportsEmbeddedArtwork(url)
            self.init(url: url, kind: .audio, properties: tags.properties,
                      covers: embeds ? tags.artworks.map(CoverSummary.init) : nil,
                      durationMilliseconds: tags.audio.map(\.lengthMilliseconds),
                      title: tags.firstValue(for: "TITLE") ?? "",
                      patternFields: PatternFields.fields(from: tags.properties))
        }

        /// Bild-Item (nur Titelprüfung und Dateiname).
        public init(url: URL, image: ImageCoreFields) {
            self.init(url: url, kind: .image, title: image.title,
                      patternFields: PatternFields.fields(from: image))
        }

        /// E-Book-Item. `hasCover` nil = Format kennt kein Cover (PDF).
        public init(url: URL, ebook: EbookCoreFields, hasCover: Bool?) {
            self.init(url: url, kind: .ebook,
                      covers: hasCover.map { $0 ? [CoverSummary(mimeType: "", bytes: 0)] : [] },
                      title: ebook.title, patternFields: PatternFields.fields(from: ebook))
        }

        /// Dokument-Item (nur Titelprüfung und Dateiname).
        public init(url: URL, document: DocumentCoreFields) {
            self.init(url: url, kind: .document, title: document.title,
                      patternFields: PatternFields.fields(from: document))
        }

        /// Liest eine Datei passend zu ihrer Medienart. Lesefehler landen im
        /// Item (`readError`), damit ein Ordnerlauf nicht an einer kaputten
        /// Datei abbricht. nil = Medienart wird nicht geprüft (Playlists,
        /// E-Rechnungen, XMP-Sidecars, NFO/Untertitel) oder Container ohne
        /// Tag-Leser (AVI).
        public static func load(url: URL) -> Item? {
            guard let kind = MediaFormats.kind(of: url) else { return nil }
            do {
                switch kind {
                case .audio:
                    do {
                        return Item(url: url, tags: try TagFile.read(at: url))
                    } catch where MediaFormats.toleratesMissingTagReader(url) {
                        return nil
                    }
                case .image:
                    // Die Sidecar selbst ist kein Bild; das Bild daneben wird
                    // ohnehin (mit Sidecar-Werten) geprüft.
                    if MediaFormats.isXMPSidecar(url) { return nil }
                    return Item(url: url, image: try ExifTool.readCoreFields(url: url))
                case .ebook:
                    let supportsCover = EbookTool.supportsCover(url: url)
                    let contents = try EbookTool.readSnapshot(url: url, includeCover: supportsCover).value
                    return Item(url: url, ebook: contents.fields,
                                hasCover: supportsCover ? contents.cover != nil : nil)
                case .document:
                    return Item(url: url, document: try DocumentTool.readSnapshot(
                        url: url, includeCover: false).value.fields)
                case .invoice, .playlist, .sidecar:
                    // Reine Anzeige- bzw. Begleitformate ohne eigene Prüfregeln.
                    return nil
                }
            } catch {
                return Item(url: url, kind: kind, readError: error.localizedDescription)
            }
        }

        /// Erster Wert eines Schlüssels, ohne Randleerzeichen; "" wenn leer.
        func value(_ key: String) -> String {
            (properties.first { $0.key == key }?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Alle Werte eines Schlüssels (mehrwertige Felder wie GENRE).
        func values(_ key: String) -> [String] {
            properties.filter { $0.key == key }.map {
                $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: - Ergebnis

    /// Ein Befund: Regel, betroffene Dateien und ein Detailtext (englisch,
    /// meist nur Werte wie "missing: 3, 7").
    public struct Finding: Sendable, Codable, Equatable {
        public var code: RuleCode
        public var severity: Severity
        /// Gruppenbezeichnung (Album/Ordner); leer bei Befunden über alle
        /// Dateien hinweg (doppelte Titel).
        public var group: String
        public var message: String
        public var files: [String]

        public init(code: RuleCode, group: String, message: String, files: [URL]) {
            self.code = code
            self.severity = code.severity
            self.group = group
            self.message = message
            self.files = files.map(\.path)
        }
    }

    /// Zusammenfassung je Regel.
    public struct RuleSummary: Sendable, Codable, Equatable {
        public var code: RuleCode
        public var severity: Severity
        public var findings: Int
        public var files: Int
    }

    /// Eine Datei mit den Regeln, die sie betreffen.
    public struct FileResult: Sendable, Codable, Equatable {
        public var file: String
        public var group: String
        public var codes: [RuleCode]
    }

    /// Eine Gruppe (Album oder Ordner) mit ihren Dateien.
    public struct Group: Sendable, Codable, Equatable {
        public var label: String
        public var files: [String]
    }

    /// Vollständiger Bericht: Gruppen, Befunde, Zusammenfassung je Regel
    /// und Liste je Datei. Codable, damit `tagx check --json` und die App
    /// dieselbe Quelle nutzen.
    public struct Report: Sendable, Codable, Equatable {
        public var checkedFiles: Int
        public var groups: [Group]
        public var findings: [Finding]
        public var summary: [RuleSummary]
        public var files: [FileResult]

        public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
        public var hintCount: Int { findings.filter { $0.severity == .hint }.count }

        /// Gibt es Befunde ab diesem Schweregrad?
        public func hasFindings(atLeast severity: Severity) -> Bool {
            findings.contains { $0.severity >= severity }
        }

        /// Befunde der Gruppe in Berichtsreihenfolge.
        public func findings(in group: String) -> [Finding] {
            findings.filter { $0.group == group }
        }

        /// Bericht auf bestimmte Regeln eingeschränkt (`--only`).
        public func filtered(to codes: Set<RuleCode>) -> Report {
            Report(checkedFiles: checkedFiles, groups: groups,
                   findings: findings.filter { codes.contains($0.code) })
        }

        init(checkedFiles: Int, groups: [Group], findings: [Finding]) {
            self.checkedFiles = checkedFiles
            self.groups = groups
            self.findings = findings
            // Zusammenfassung je Regel in Regel-Reihenfolge.
            var perRule: [RuleCode: (findings: Int, files: Set<String>)] = [:]
            for finding in findings {
                var entry = perRule[finding.code] ?? (0, [])
                entry.findings += 1
                entry.files.formUnion(finding.files)
                perRule[finding.code] = entry
            }
            self.summary = RuleCode.allCases.compactMap { code in
                guard let entry = perRule[code] else { return nil }
                return RuleSummary(code: code, severity: code.severity,
                                   findings: entry.findings, files: entry.files.count)
            }
            // Liste je Datei in Gruppenreihenfolge.
            var codesByFile: [String: [RuleCode]] = [:]
            for finding in findings {
                for file in finding.files where !(codesByFile[file] ?? []).contains(finding.code) {
                    codesByFile[file, default: []].append(finding.code)
                }
            }
            self.files = groups.flatMap { group in
                group.files.map { FileResult(file: $0, group: group.label, codes: codesByFile[$0] ?? []) }
            }
        }

        /// Klartext für Terminal und Zwischenablage: Befunde je Gruppe, dann
        /// die Zusammenfassung. `ruleTitle` erlaubt der App übersetzte
        /// Regelnamen; Voreinstellung sind die englischen.
        public func plainText(ruleTitle: (RuleCode) -> String = { $0.title }) -> String {
            var lines: [String] = []
            let crossGroup = findings.filter { $0.group.isEmpty }
            for group in groups {
                let groupFindings = findings(in: group.label)
                guard !groupFindings.isEmpty else { continue }
                lines.append("== \(group.label) (\(group.files.count) file(s))")
                for finding in groupFindings {
                    lines.append(contentsOf: Self.lines(for: finding, ruleTitle: ruleTitle))
                }
            }
            if !crossGroup.isEmpty {
                lines.append("== Across all files")
                for finding in crossGroup {
                    lines.append(contentsOf: Self.lines(for: finding, ruleTitle: ruleTitle))
                }
            }
            if findings.isEmpty {
                lines.append("No findings in \(checkedFiles) file(s)")
            } else {
                lines.append("\(warningCount) warning(s), \(hintCount) hint(s) in \(checkedFiles) file(s)")
            }
            return lines.joined(separator: "\n")
        }

        private static func lines(for finding: Finding, ruleTitle: (RuleCode) -> String) -> [String] {
            let tag = finding.severity == .warning ? "WARNING" : "HINT"
            var head = "\(tag) \(finding.code.rawValue): \(ruleTitle(finding.code))"
            if !finding.message.isEmpty { head += " — \(finding.message)" }
            return [head] + finding.files.map { "    " + URL(fileURLWithPath: $0).lastPathComponent }
        }
    }

    // MARK: - Prüfung

    /// Toleranz beim Dauer-Vergleich doppelter Titel (±2 s).
    public static let duplicateDurationTolerance = 2000

    /// Führt alle Regeln aus. `pattern` (optional) prüft zusätzlich, ob der
    /// Dateiname dem Muster entspricht — ohne Muster keine Dateinamenprüfung.
    public static func run(_ items: [Item], pattern: FilenamePattern? = nil) -> Report {
        var findings: [Finding] = []
        var groups: [Group] = []

        // Unlesbare Dateien: je eine Warnung, sonst keine Prüfung.
        let readable = items.filter { $0.readError == nil }
        for item in items where item.readError != nil {
            findings.append(Finding(code: .unreadable, group: "", message: item.readError ?? "",
                                    files: [item.url]))
        }

        // Audio/Video in Album- bzw. Ordnergruppen; alle anderen je Ordner.
        let grouped = makeGroups(readable)
        for group in grouped {
            groups.append(Group(label: group.label, files: group.items.map(\.url.path)))
            // Album-Regeln nur über die Audio-/Video-Dateien der Gruppe; ein
            // Ordner kann daneben Bilder oder E-Books enthalten.
            let audioItems = group.items.filter { $0.kind == .audio }
            if !audioItems.isEmpty {
                findings.append(contentsOf: checkAlbum(ItemGroup(label: group.label, items: audioItems)))
            }
            for item in group.items {
                findings.append(contentsOf: checkSingle(item, group: group.label))
            }
            if let pattern {
                findings.append(contentsOf: checkFilenames(group.items, pattern: pattern, group: group.label))
            }
        }
        findings.append(contentsOf: checkDuplicateTitles(readable.filter { $0.kind == .audio }))

        return Report(checkedFiles: items.count, groups: groups, findings: findings)
    }

    // MARK: Gruppierung

    struct ItemGroup {
        var label: String
        var items: [Item]
    }

    /// Vergleichsform: ohne Randleerzeichen, Kleinschreibung, mehrfache
    /// Leerzeichen zusammengezogen.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Häufigster Wert einer Liste (bei Gleichstand der zuerst gesehene).
    static func mostCommon(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for value in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ""
    }

    static func makeGroups(_ items: [Item]) -> [ItemGroup] {
        var keys: [String] = []
        var members: [String: [Item]] = [:]
        for item in items {
            let key: String
            if item.kind == .audio, !item.value("ALBUM").isEmpty {
                key = "album|" + normalized(item.value("ALBUM")) + "|" + normalized(item.value("ALBUMARTIST"))
            } else {
                key = "folder|" + item.url.deletingLastPathComponent().path
            }
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(item)
        }
        return keys.map { key in
            let group = members[key] ?? []
            let label: String
            if key.hasPrefix("album|") {
                let album = mostCommon(group.map { $0.value("ALBUM") })
                let artists = group.map { $0.value("ALBUMARTIST") }.filter { !$0.isEmpty }
                label = artists.isEmpty ? album : "\(album) — \(mostCommon(artists))"
            } else {
                label = group.first?.url.deletingLastPathComponent().path ?? ""
            }
            return ItemGroup(label: label, items: group)
        }
    }

    // MARK: Einzeldatei

    static func checkSingle(_ item: Item, group: String) -> [Finding] {
        var findings: [Finding] = []
        switch item.kind {
        case .audio:
            if item.value("TITLE").isEmpty {
                findings.append(Finding(code: .emptyTitle, group: group, message: "", files: [item.url]))
            }
            if item.value("ARTIST").isEmpty {
                findings.append(Finding(code: .emptyArtist, group: group, message: "", files: [item.url]))
            }
            if item.value("ALBUM").isEmpty {
                findings.append(Finding(code: .emptyAlbum, group: group, message: "", files: [item.url]))
            }
            if let covers = item.covers, covers.isEmpty {
                findings.append(Finding(code: .missingCover, group: group, message: "", files: [item.url]))
            }
        case .image, .document:
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(Finding(code: .emptyTitle, group: group, message: "", files: [item.url]))
            }
        case .ebook:
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(Finding(code: .emptyTitle, group: group, message: "", files: [item.url]))
            }
            if let covers = item.covers, covers.isEmpty {
                findings.append(Finding(code: .missingCover, group: group, message: "", files: [item.url]))
            }
        case .invoice, .playlist, .sidecar:
            break
        }
        return findings
    }

    // MARK: Album

    /// Nummer und Gesamtzahl aus "3/12", "3" oder getrennten Feldern
    /// (Vorbis: TRACKNUMBER=3 + TRACKTOTAL=12). nil = keine lesbare Zahl.
    static func parseNumber(_ raw: String, totalFields: [String]) -> (number: Int?, total: Int?) {
        var numberText = raw
        var totalText: String? = nil
        if let slash = raw.firstIndex(of: "/") {
            numberText = String(raw[..<slash])
            totalText = String(raw[raw.index(after: slash)...])
        }
        let number = Int(numberText.trimmingCharacters(in: .whitespaces))
        var total = totalText.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if total == nil {
            total = totalFields.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first
        }
        return (number, total)
    }

    static func checkAlbum(_ group: ItemGroup) -> [Finding] {
        var findings: [Finding] = []
        let label = group.label
        let items = group.items
        let urls = items.map(\.url)
        guard items.count > 1 else {
            // Eine einzelne Datei: nur Track > Gesamt und fehlende Nummer.
            return checkTracks(items, group: label) + checkDiscs(items, group: label)
        }

        // Album-Interpret: verschiedene Schreibweisen, oder gar keiner bei
        // mehreren Interpreten (Compilation ohne ALBUMARTIST).
        let albumArtists = items.map { $0.value("ALBUMARTIST") }
        let distinctAlbumArtists = Array(Set(albumArtists)).sorted()
        if distinctAlbumArtists.count > 1 {
            findings.append(Finding(code: .albumArtistInconsistent, group: label,
                                    message: valueList(albumArtists), files: urls))
        } else if albumArtists.allSatisfy(\.isEmpty) {
            let artists = Set(items.map { normalized($0.value("ARTIST")) }.filter { !$0.isEmpty })
            if artists.count > 1 {
                findings.append(Finding(code: .albumArtistMissing, group: label,
                                        message: "\(artists.count) different artists", files: urls))
            }
        }

        // Album-Titel: gleiche Gruppe, aber verschiedene Schreibweisen.
        let albums = items.map { $0.value("ALBUM") }
        if Set(albums).count > 1 {
            findings.append(Finding(code: .albumTitleInconsistent, group: label,
                                    message: valueList(albums), files: urls))
        }

        // Jahr/Datum und Genre.
        let dates = items.map { $0.value("DATE") }
        if Set(dates).count > 1 {
            findings.append(Finding(code: .dateInconsistent, group: label,
                                    message: valueList(dates), files: urls))
        }
        let genres = items.map { $0.values("GENRE").joined(separator: ", ") }
        if Set(genres).count > 1 {
            findings.append(Finding(code: .genreInconsistent, group: label,
                                    message: valueList(genres), files: urls))
        }

        // Cover: Größe/Format uneinheitlich (nur Dateien mit Cover).
        let withCover = items.filter { !($0.covers ?? []).isEmpty }
        let coverLabels = withCover.compactMap { $0.covers?.first?.label }
        if Set(coverLabels).count > 1 {
            findings.append(Finding(code: .coverInconsistent, group: label,
                                    message: valueList(coverLabels), files: withCover.map(\.url)))
        }

        findings.append(contentsOf: checkTracks(items, group: label))
        findings.append(contentsOf: checkDiscs(items, group: label))
        return findings
    }

    /// "2× 1959, 1× 1960" — Werte mit Häufigkeit, leere als (empty).
    static func valueList(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value)× \($0.key.isEmpty ? "(empty)" : $0.key)" }
            .joined(separator: ", ")
    }

    static func checkTracks(_ items: [Item], group: String) -> [Finding] {
        var findings: [Finding] = []
        struct Parsed { var item: Item; var disc: Int; var number: Int; var total: Int? }
        var parsed: [Parsed] = []
        var missing: [URL] = []
        var invalid: [URL] = []
        var missingTotal: [URL] = []
        var exceeding: [URL] = []
        for item in items {
            let track = parseNumber(item.value("TRACKNUMBER"),
                                    totalFields: item.values("TRACKTOTAL") + item.values("TOTALTRACKS"))
            guard let number = track.number else {
                missing.append(item.url)
                continue
            }
            // 0 oder negativ ist parsebar, aber keine Position: Die
            // Lückenprüfung ab 1 sähe ein solches Album sonst als vollständig.
            guard number >= 1 else {
                invalid.append(item.url)
                continue
            }
            // Eine ungültige Disc-Nummer meldet `checkDiscs`; für die
            // Gruppierung zählt sie wie „keine Angabe“ (Disc 1).
            let disc = parseNumber(item.value("DISCNUMBER"),
                                   totalFields: item.values("DISCTOTAL") + item.values("TOTALDISCS")).number
                .flatMap { $0 >= 1 ? $0 : nil } ?? 1
            parsed.append(Parsed(item: item, disc: disc, number: number, total: track.total))
            if track.total == nil { missingTotal.append(item.url) }
            if let total = track.total, number > total { exceeding.append(item.url) }
        }
        if !missing.isEmpty {
            findings.append(Finding(code: .trackMissing, group: group, message: "", files: missing))
        }
        if !invalid.isEmpty {
            findings.append(Finding(code: .trackInvalid, group: group, message: "", files: invalid))
        }
        if !exceeding.isEmpty {
            findings.append(Finding(code: .trackExceedsTotal, group: group, message: "", files: exceeding))
        }
        if !missingTotal.isEmpty, items.count > 1 {
            findings.append(Finding(code: .trackTotalMissing, group: group, message: "", files: missingTotal))
        }
        guard items.count > 1 else { return findings }

        // Lücken und Dubletten je Disc: erwartet wird 1…Gesamtzahl (falls
        // bekannt), sonst 1…höchste Nummer.
        let discs = Set(parsed.map(\.disc)).sorted()
        for disc in discs {
            let onDisc = parsed.filter { $0.disc == disc }
            var seen: [Int: [URL]] = [:]
            for entry in onDisc { seen[entry.number, default: []].append(entry.item.url) }
            let duplicates = seen.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            let prefix = discs.count > 1 || disc != 1 ? "disc \(disc): " : ""
            if !duplicates.isEmpty {
                findings.append(Finding(
                    code: .trackDuplicate, group: group,
                    message: prefix + duplicates.map { "track \($0.key) ×\($0.value.count)" }.joined(separator: ", "),
                    files: duplicates.flatMap(\.value)))
            }
            let highest = max(onDisc.map(\.number).max() ?? 0, onDisc.compactMap(\.total).max() ?? 0)
            guard highest > 0 else { continue }
            let gaps = (1...highest).filter { seen[$0] == nil }
            if !gaps.isEmpty {
                findings.append(Finding(
                    code: .trackGap, group: group,
                    message: prefix + "missing " + gaps.map(String.init).joined(separator: ", "),
                    files: onDisc.map(\.item.url)))
            }
        }
        return findings
    }

    static func checkDiscs(_ items: [Item], group: String) -> [Finding] {
        var findings: [Finding] = []
        struct Parsed { var url: URL; var number: Int; var total: Int? }
        var parsed: [Parsed] = []
        var invalid: [URL] = []
        for item in items {
            let raw = item.value("DISCNUMBER")
            guard !raw.isEmpty else { continue }
            let disc = parseNumber(raw, totalFields: item.values("DISCTOTAL") + item.values("TOTALDISCS"))
            guard let number = disc.number else { continue }
            // 0 oder negativ: keine Disc-Position (siehe `checkTracks`).
            guard number >= 1 else {
                invalid.append(item.url)
                continue
            }
            parsed.append(Parsed(url: item.url, number: number, total: disc.total))
        }
        if !invalid.isEmpty {
            findings.append(Finding(code: .discInvalid, group: group, message: "", files: invalid))
        }
        // Ohne Disc-Nummern (einfaches Album) gibt es nichts zu prüfen.
        guard !parsed.isEmpty else { return findings }
        let exceeding = parsed.filter { entry in entry.total.map { entry.number > $0 } ?? false }
        if !exceeding.isEmpty {
            findings.append(Finding(code: .discExceedsTotal, group: group, message: "", files: exceeding.map(\.url)))
        }
        guard items.count > 1 else { return findings }
        let missingTotal = parsed.filter { $0.total == nil }
        if !missingTotal.isEmpty {
            findings.append(Finding(code: .discTotalMissing, group: group, message: "", files: missingTotal.map(\.url)))
        }
        let present = Set(parsed.map(\.number))
        let highest = max(present.max() ?? 0, parsed.compactMap(\.total).max() ?? 0)
        if highest > 0 {
            let gaps = (1...highest).filter { !present.contains($0) }
            if !gaps.isEmpty {
                findings.append(Finding(
                    code: .discGap, group: group,
                    message: "missing " + gaps.map(String.init).joined(separator: ", "),
                    files: parsed.map(\.url)))
            }
        }
        return findings
    }

    // MARK: Dateinamen

    static func checkFilenames(_ items: [Item], pattern: FilenamePattern, group: String) -> [Finding] {
        items.compactMap { item in
            let expected = pattern.renderFileName(fields: item.patternFields,
                                                  extension: item.url.pathExtension)
            guard !expected.isEmpty, expected != item.url.lastPathComponent else { return nil }
            return Finding(code: .filenameMismatch, group: group,
                           message: "expected \(expected)", files: [item.url])
        }
    }

    // MARK: Doppelte Titel

    /// Gleicher Titel + Interpret (Schreibweise egal) und Dauer innerhalb
    /// ±2 s über die gesamte Auswahl. Dateien ohne bekannte Dauer werden
    /// nicht verglichen — zwei „Intro" desselben Interpreten auf zwei Alben
    /// sind sonst nicht von echten Dubletten zu unterscheiden.
    static func checkDuplicateTitles(_ items: [Item]) -> [Finding] {
        var buckets: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let title = normalized(item.value("TITLE"))
            let artist = normalized(item.value("ARTIST"))
            guard !title.isEmpty, item.durationMilliseconds != nil else { continue }
            let key = title + "\u{1F}" + artist
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        var findings: [Finding] = []
        for key in order {
            let candidates = (buckets[key] ?? []).sorted {
                ($0.durationMilliseconds ?? 0) < ($1.durationMilliseconds ?? 0)
            }
            guard candidates.count > 1 else { continue }
            // Nach Dauer sortiert: Nachbarn innerhalb der Toleranz bilden
            // eine Kette (Cluster).
            var cluster: [Item] = [candidates[0]]
            func flush() {
                guard cluster.count > 1 else { return }
                let seconds = Double(cluster[0].durationMilliseconds ?? 0) / 1000
                findings.append(Finding(
                    code: .duplicateTitle, group: "",
                    message: "\"\(cluster[0].value("TITLE"))\" — \(cluster[0].value("ARTIST")) "
                        + String(format: "(%.0f s)", seconds),
                    files: cluster.map(\.url)))
            }
            for item in candidates.dropFirst() {
                let previous = cluster.last?.durationMilliseconds ?? 0
                if abs((item.durationMilliseconds ?? 0) - previous) <= duplicateDurationTolerance {
                    cluster.append(item)
                } else {
                    flush()
                    cluster = [item]
                }
            }
            flush()
        }
        return findings
    }
}

// tagx check — Konsistenzprüfung über Dateien und Ordner (nur lesen).
//
// Exit-Codes: 0 = ok (auch mit Befunden), 1 = Fehler, 4 = Befunde ab dem
// mit --fail-on gewählten Schweregrad. Ohne --fail-on schlägt der Befehl nie
// wegen Befunden fehl — ein Bericht ist noch kein Fehler.
import ArgumentParser
import Foundation
import TagExplosionCore

/// Exit-Code für „es gibt Befunde" — unterscheidbar von echten Fehlern (1),
/// vom Umbenennen-Konflikt (2) und der Rechnungsvalidierung (3).
let findingsExitCode = ExitCode(4)

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check folders or files for tag consistency (covers, album artist, track numbers …).",
        discussion: """
            Audio and video files are grouped by album (ALBUM + ALBUMARTIST, spelling \
            ignored) or, without an album tag, by folder. Rules: missing cover, cover \
            size/format differs, album artist differs or is missing on a compilation, \
            track numbers (missing, gaps, duplicates, no total, above total), disc \
            numbers, year/date, genre and album spelling within an album, empty title/\
            artist/album, same title + artist + duration (±2 s) across all files, and \
            optionally file names against a pattern (--pattern). Images, e-books and \
            documents are only checked for an empty title (e-books also for a missing \
            cover). Nothing is changed. Rule codes: \
            \(LibraryCheck.RuleCode.allCases.map(\.rawValue).joined(separator: ", ")).
            """
    )

    /// Schweregrad, ab dem der Exit-Code 4 wird.
    enum FailOn: String, ExpressibleByArgument, CaseIterable {
        case warning
        case hint

        var severity: LibraryCheck.Severity {
            switch self {
            case .warning: return .warning
            case .hint: return .hint
            }
        }
    }

    @Argument(help: "Media files or folders (folders are searched recursively)")
    var paths: [String]
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Option(name: .shortAndLong,
            help: "Also check file names against this pattern, e.g. '%{track:2} - %{title}' (default: no name check)")
    var pattern: String?
    // Bewusst ein Wert je Nennung (kommagetrennt): Mit `.upToNextOption`
    // würde ein nachfolgender Pfad als Regelcode gelesen.
    @Option(name: .long, help: "Only report these rule codes (comma-separated; option may be repeated)")
    var only: [String] = []
    @Option(name: .long, help: "Exit with code 4 if there are findings of this severity or above (warning|hint)")
    var failOn: FailOn?

    func run() throws {
        let compiled = try pattern.map(parsePattern)
        guard !paths.isEmpty else { throw ValidationError("Provide at least one file or folder.") }
        let urls = try paths.map(resolveFile)
        let files = MediaFormats.expandMediaFiles(urls)
        guard !files.isEmpty else { throw ValidationError("No media files found.") }

        // Unbekannte Regelcodes sind ein Eingabefehler, kein leerer Bericht.
        // Swift.Set: "Set" ist in diesem Modul der Name des CLI-Befehls.
        var onlyCodes: Swift.Set<LibraryCheck.RuleCode> = []
        for raw in only.flatMap({ $0.split(separator: ",") }) {
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard let code = LibraryCheck.RuleCode(rawValue: text) else {
                throw ValidationError("Unknown rule code: \(text). Known: "
                    + LibraryCheck.RuleCode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            onlyCodes.insert(code)
        }

        let items = files.compactMap(LibraryCheck.Item.load)
        var report = LibraryCheck.run(items, pattern: compiled)
        if !onlyCodes.isEmpty { report = report.filtered(to: onlyCodes) }

        if json {
            try printJSON(report)
        } else {
            print(report.plainText())
        }
        if let failOn, report.hasFindings(atLeast: failOn.severity) {
            throw findingsExitCode
        }
    }
}

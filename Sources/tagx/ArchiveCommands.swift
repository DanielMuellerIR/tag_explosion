// tagx export / tagx import — Tags aller Medienarten als selbständige
// JSON-Datei sichern und wiederherstellen (Cover Base64-eingebettet).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export tags of the given files/folders as JSON (covers embedded).")

    @Argument(help: "Media files or folders (recursive)") var paths: [String]
    @Option(name: [.short, .customLong("output")], help: "Target JSON file") var output: String
    @Flag(name: .customLong("without-covers"),
          help: "Omit covers (much smaller file)") var withoutCovers = false

    func run() throws {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw ValidationError("File not found: \(url.path)")
        }
        let files = MediaFormats.expandMediaFiles(urls)
        guard !files.isEmpty else {
            throw ValidationError("No supported media files found.")
        }
        let jsonURL = URL(fileURLWithPath: output)
        do {
            // Die Core-Grenze prüft das Ziel genau einmal und weiterhin vor dem
            // ersten Medien-Lesezugriff.
            try TagArchiveIO.export(files: files, to: jsonURL, includeCovers: !withoutCovers)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        print("OK \(files.count) file(s) → \(jsonURL.path)")
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Write tags back from an export/backup JSON file (matched via relative paths).")

    @Argument(help: "Export/backup JSON") var file: String
    @Flag(name: .long, help: "Only show what would change") var dryRun = false
    @Flag(name: .customLong("allow-external-targets"), help: "Allow resolved targets outside the archive directory after printing the complete target list")
    var allowExternalTargets = false
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let jsonURL = try resolveFile(file)
        let archive = try TagArchiveIO.load(jsonURL)
        let base = jsonURL.deletingLastPathComponent()
        // Die Zielliste wird immer vorab aufgelöst und anschließend an `apply`
        // weitergereicht: Nur so fällt auf, wenn zwischen Prüfung und
        // Schreibweg ein Symlink auf eine andere Datei umgebogen wird.
        let targets = try TagArchiveIO.validatedTargets(
            archive, relativeTo: base, allowExternalTargets: allowExternalTargets)
        if allowExternalTargets {
            FileHandle.standardError.write(Data("Resolved import targets:\n".utf8))
            for target in targets {
                FileHandle.standardError.write(Data("  \(target.path)\n".utf8))
            }
        }
        let report = try TagArchiveIO.apply(
            archive, relativeTo: base, dryRun: dryRun,
            approvedTargets: targets, allowExternalTargets: allowExternalTargets)

        let verb = dryRun ? "WOULD CHANGE" : "CHANGED"
        for path in report.applied { print("\(verb) \(path)") }
        for path in report.unchanged { print("UNCHANGED \(path)") }
        for path in report.missing { print("MISSING \(path)") }
        for path in report.extra { print("NOT IN ARCHIVE \(path)") }
        for (path, error) in report.failed {
            FileHandle.standardError.write(Data("ERROR \(path): \(error)\n".utf8))
        }
        print("\(report.applied.count) changed\(dryRun ? " (dry-run)" : ""), "
            + "\(report.unchanged.count) unchanged, \(report.missing.count) missing, "
            + "\(report.extra.count) not in archive, \(report.failed.count) failed")

        // Skript-tauglich: unvollständige Wiederherstellung => Exit-Code 1.
        if !report.missing.isEmpty || !report.failed.isEmpty {
            throw ExitCode(1)
        }
    }
}

// tagx export / tagx import — Tags aller Medienarten als selbständige
// JSON-Datei sichern und wiederherstellen (Cover Base64-eingebettet).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Tags der angegebenen Dateien/Ordner als JSON exportieren (Cover eingebettet).")

    @Argument(help: "Mediendateien oder Ordner (rekursiv)") var paths: [String]
    @Option(name: [.short, .customLong("output")], help: "Ziel-JSON-Datei") var output: String
    @Flag(name: .customLong("without-covers"),
          help: "Cover weglassen (deutlich kleinere Datei)") var withoutCovers = false

    func run() throws {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            throw ValidationError("Datei nicht gefunden: \(url.path)")
        }
        let files = MediaFormats.expandMediaFiles(urls)
        guard !files.isEmpty else {
            throw ValidationError("Keine unterstützten Mediendateien gefunden.")
        }
        let jsonURL = URL(fileURLWithPath: output)
        try TagArchiveIO.export(files: files, to: jsonURL, includeCovers: !withoutCovers)
        print("OK \(files.count) Datei(en) → \(jsonURL.path)")
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Tags aus einer Export-/Backup-JSON-Datei zurückschreiben (Match über relative Pfade).")

    @Argument(help: "Export-/Backup-JSON") var file: String
    @Flag(name: .long, help: "Nur anzeigen, was sich ändern würde") var dryRun = false

    func run() throws {
        let jsonURL = try resolveFile(file)
        let archive = try TagArchiveIO.load(jsonURL)
        let report = TagArchiveIO.apply(
            archive, relativeTo: jsonURL.deletingLastPathComponent(), dryRun: dryRun)

        let verb = dryRun ? "WÜRDE ÄNDERN" : "GEÄNDERT"
        for path in report.applied { print("\(verb) \(path)") }
        for path in report.unchanged { print("UNVERÄNDERT \(path)") }
        for path in report.missing { print("FEHLT \(path)") }
        for path in report.extra { print("NICHT IM ARCHIV \(path)") }
        for (path, error) in report.failed {
            FileHandle.standardError.write(Data("FEHLER \(path): \(error)\n".utf8))
        }
        print("\(report.applied.count) geändert\(dryRun ? " (dry-run)" : ""), "
            + "\(report.unchanged.count) unverändert, \(report.missing.count) fehlend, "
            + "\(report.extra.count) nicht im Archiv, \(report.failed.count) fehlgeschlagen")

        // Skript-tauglich: unvollständige Wiederherstellung => Exit-Code 1.
        if !report.missing.isEmpty || !report.failed.isEmpty {
            throw ExitCode(1)
        }
    }
}

// `tagx history` — Undo-Historie aus den Papierkorb-Sicherungen:
// Versionen einer Datei auflisten, gegen heute vergleichen, zurückspielen,
// Journal aufräumen. Versionsnummern zählen von der jüngsten Sicherung (1).
import ArgumentParser
import Foundation
import TagExplosionCore

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, compare, and restore trash backups of a file (undo history).",
        subcommands: [List.self, Diff.self, Restore.self, Prune.self]
    )

    /// JSON-Form einer Version (Datum ISO 8601).
    struct VersionReport: Codable {
        var version: Int
        var date: String
        var reason: String
        var size: Int64
        var sha256: String?
        var backupPath: String
        var originalPath: String

        init(_ version: BackupVersion) {
            self.version = version.number
            self.date = History.isoString(version.entry.date)
            self.reason = version.entry.reason
            self.size = version.entry.size
            self.sha256 = version.entry.sha256
            self.backupPath = version.entry.backupPath
            self.originalPath = version.entry.originalPath
        }
    }

    /// ISO-8601-Zeit in UTC ("2026-09-02T10:11:12Z").
    static func isoString(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Datei-Argument ohne Existenzprüfung: Auch für eine inzwischen
    /// gelöschte Datei sollen sich Versionen auflisten und zurückholen lassen.
    static func historyURL(_ path: String) -> URL {
        MediaFormats.canonicalFileURL(URL(fileURLWithPath: path))
    }

    /// Version nach Nummer holen; verständlicher Fehler, wenn es sie nicht gibt.
    static func requireVersion(_ number: Int, of url: URL) throws -> BackupVersion {
        let versions = BackupHistory.versions(of: url)
        guard let version = versions.first(where: { $0.number == number }) else {
            if versions.isEmpty {
                throw ValidationError("No backups recorded for \(url.lastPathComponent)")
            }
            throw ValidationError(
                "Version \(number) not found (available: 1…\(versions.count))")
        }
        return version
    }

    /// Feld-Unterschiede als Text: eine Zeile je Feld mit beiden Werten.
    static func printDiff(_ changes: [BackupFieldChange]) {
        guard !changes.isEmpty else {
            print("No metadata differences")
            return
        }
        for change in changes {
            print("\(change.key):")
            print("  version: \(change.version ?? "(none)")")
            print("  current: \(change.current ?? "(none)")")
        }
    }

    // MARK: - list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List the trash backups of a file, newest first.")

        @Argument(help: "Media file") var file: String
        @Flag(name: .long, help: "Output as JSON") var json = false

        func run() throws {
            let url = History.historyURL(file)
            let versions = BackupHistory.versions(of: url)
            if json {
                try printJSON(versions.map(VersionReport.init))
                return
            }
            guard !versions.isEmpty else {
                print("No backups recorded for \(url.lastPathComponent)")
                return
            }
            for version in versions {
                let date = History.isoString(version.entry.date)
                print("#\(version.number)  \(date)  \(version.entry.reason)  "
                      + "\(version.entry.size) bytes  \(version.entry.backupPath)")
            }
        }
    }

    // MARK: - diff

    struct Diff: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "diff",
            abstract: "Show which metadata fields differ between the file and a backup version.")

        @Argument(help: "Media file") var file: String
        @Option(name: .long, help: "Version number from `history list` (1 = newest)")
        var version: Int = 1
        @Flag(name: .long, help: "Output as JSON") var json = false

        func run() throws {
            let url = History.historyURL(file)
            let chosen = try History.requireVersion(version, of: url)
            let changes = try BackupHistory.diff(current: url, against: chosen)
            if json {
                try printJSON(changes)
            } else {
                History.printDiff(changes)
            }
        }
    }

    // MARK: - restore

    struct Restore: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Restore a backup version. Without --apply only the differences are shown.")

        @Argument(help: "Media file") var file: String
        @Option(name: .long, help: "Version number from `history list` (1 = newest)")
        var version: Int = 1
        @Flag(name: .long, help: "Really write the version back (default: dry run)")
        var apply = false
        @OptionGroup var safeMode: SafeModeOptions

        func run() throws {
            safeMode.apply()
            let url = History.historyURL(file)
            let chosen = try History.requireVersion(version, of: url)
            // Stempel VOR dem Vergleich: Ändert ein anderes Programm die Datei
            // zwischen Anzeige und Austausch, bricht das Zurückspielen ab.
            let stamp = FileStamp.current(of: url)
            let changes = try BackupHistory.diff(current: url, against: chosen)
            History.printDiff(changes)
            guard apply else {
                print("Dry run: add --apply to restore version \(chosen.number) "
                      + "(\(History.isoString(chosen.entry.date)))")
                return
            }
            try BackupHistory.restore(chosen, expecting: stamp)
            print("OK \(url.lastPathComponent): version \(chosen.number) restored"
                  + (TrashBackup.shared.isEnabled
                     ? " (previous state backed up to the trash)" : ""))
        }
    }

    // MARK: - prune

    struct Prune: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Drop journal entries whose backup is gone (and older ones). Never touches the trash.")

        @Option(name: .long, help: "Also drop entries older than this many days")
        var olderThan: Int?

        func run() throws {
            if let olderThan, olderThan < 0 {
                throw ValidationError("--older-than must not be negative")
            }
            let removed = try BackupHistory.prune(olderThanDays: olderThan)
            print("OK: \(removed) journal entr\(removed == 1 ? "y" : "ies") removed")
        }
    }
}

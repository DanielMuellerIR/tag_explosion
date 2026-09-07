// Echte CLI-Regressionen für `tagx history`: leere Historie, Liste nach einem
// gesicherten `set`, Diff, Dry-run und echtes Zurückspielen, prune. Das
// Journal liegt per `TAGX_BACKUP_JOURNAL` in einem Temp-Ordner; die dabei
// entstehenden Papierkorb-Ordner räumt der Test selbst wieder weg.
import Foundation
import TagExplosionTestSupport
import Testing
import TagExplosionCore

@Suite("tagx history", .serialized)
struct HistoryCommandTests {

    @Test("Leere Historie: list meldet keine Sicherungen, diff/restore scheitern verständlich",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func emptyHistory() throws {
        let directory = try makeWorkDirectory("tagx-history-empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("journal.json")
        let file = directory.appendingPathComponent("lied.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)

        let list = try runTagx(["history", "list", file.path], journal: journal)
        #expect(list.status == 0)
        #expect(list.stdout.contains("No backups recorded"))

        let json = try runTagx(["history", "list", file.path, "--json"], journal: journal)
        #expect(json.status == 0)
        #expect(try JSONDecoder().decode([VersionReport].self, from: Data(json.stdout.utf8)).isEmpty)

        let diff = try runTagx(["history", "diff", file.path], journal: journal)
        #expect(diff.status != 0)
        #expect(diff.stderr.contains("No backups recorded"))

        let prune = try runTagx(["history", "prune"], journal: journal)
        #expect(prune.status == 0)
        #expect(prune.stdout.contains("0 journal entries removed"))
    }

    #if os(macOS)
    @Test("set mit Sicherung → list/diff → restore (Dry-run, dann --apply) → Tags wie vorher",
          .enabled(if: TagxFixtures.isAvailable, "Audio-Fixture fehlt (ffmpeg?)"))
    func listDiffRestoreRoundtrip() throws {
        let directory = try makeWorkDirectory("tagx-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("journal.json")
        let file = directory.appendingPathComponent("lied.mp3")
        try FileManager.default.copyItem(at: try TagxFixtures.url("sample.mp3"), to: file)
        let before = try Data(contentsOf: file)
        // Papierkorb-Ordner dieses Tests am Ende entfernen (aus dem Journal
        // ablesbar: Kopie → Unterordner → Sitzungsordner).
        defer {
            for entry in BackupJournal(url: journal).rawEntries() {
                let session = URL(fileURLWithPath: entry.backupPath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                try? FileManager.default.removeItem(at: session)
            }
        }

        // Sicherung ist an (kein --no-backup): Kopie in den Papierkorb + Journal.
        let set = try runTagx(["set", file.path, "-t", "ARTIST=Neu"], journal: journal)
        #expect(set.status == 0, Comment(rawValue: set.stderr))

        let list = try runTagx(["history", "list", file.path], journal: journal)
        #expect(list.status == 0, Comment(rawValue: list.stderr))
        #expect(list.stdout.hasPrefix("#1  "))
        #expect(list.stdout.contains("  tags  "))

        let json = try runTagx(["history", "list", file.path, "--json"], journal: journal)
        let versions = try JSONDecoder().decode([VersionReport].self, from: Data(json.stdout.utf8))
        #expect(versions.count == 1)
        #expect(versions.first?.version == 1)
        #expect(versions.first?.reason == "tags")
        #expect(versions.first?.size == Int64(before.count))

        let diff = try runTagx(["history", "diff", file.path, "--json"], journal: journal)
        #expect(diff.status == 0, Comment(rawValue: diff.stderr))
        let changes = try JSONDecoder().decode([BackupFieldChange].self, from: Data(diff.stdout.utf8))
        #expect(changes.contains { $0.key == "ARTIST" && $0.current == "Neu" })

        // Dry-run ändert nichts.
        let dry = try runTagx(["history", "restore", file.path], journal: journal)
        #expect(dry.status == 0, Comment(rawValue: dry.stderr))
        #expect(dry.stdout.contains("Dry run"))
        #expect(try Data(contentsOf: file) != before)

        // Echtes Zurückspielen: byte-gleich wie vor dem set; der Stand mit
        // ARTIST=Neu liegt nun seinerseits als Version 1 (restore) vor.
        let restore = try runTagx(["history", "restore", file.path, "--apply"], journal: journal)
        #expect(restore.status == 0, Comment(rawValue: restore.stderr))
        #expect(restore.stdout.contains("version 1 restored"))
        #expect(try Data(contentsOf: file) == before)

        let after = try runTagx(["history", "list", file.path, "--json"], journal: journal)
        let afterVersions = try JSONDecoder().decode([VersionReport].self, from: Data(after.stdout.utf8))
        #expect(afterVersions.map(\.reason) == ["restore", "tags"])

        // Unbekannte Versionsnummer: Fehler mit Bereich.
        let missing = try runTagx(["history", "diff", file.path, "--version", "9"], journal: journal)
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("available: 1…2"))
    }
    #endif

    /// Spiegel der JSON-Ausgabe von `history list --json`.
    private struct VersionReport: Decodable {
        var version: Int
        var reason: String
        var size: Int64
        var backupPath: String
    }

    private func makeWorkDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Eigener Journal-Pfad hält die Benutzerhistorie aus diesem Test heraus.
    private func runTagx(_ arguments: [String], journal: URL) throws -> CapturedProcessResult {
        try TagExplosionTestSupport.runTagx(arguments: arguments,
            environment: ["TAGX_BACKUP_JOURNAL": journal.path])
    }
}

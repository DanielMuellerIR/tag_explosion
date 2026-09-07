// Undo-Historie: Journal-Roundtrip, Verfall bei fehlender Kopie, Restore auf
// einer Fixture-Kopie, Feld-Diff und prune. Unter Linux liegt der Papierkorb
// im Testverzeichnis; unter macOS werden eigene Sitzungsordner entfernt.
// Jeder Test hat sein eigenes Journal in einem Temp-Ordner — das Journal des
// Benutzers bleibt unangetastet.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Undo-Historie (Sicherungs-Journal)", .serialized)
struct BackupHistoryTests {

    /// Temp-Ordner mit eigenem Journal; wird am Ende entfernt.
    private func withJournal(maxEntries: Int = BackupJournal.defaultMaxEntries,
                             _ body: (BackupJournal, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = BackupJournal(url: directory.appendingPathComponent("backup-journal.json"),
                                    maxEntries: maxEntries)
        try body(journal, directory)
    }

    /// Papierkorb-Sicherung mit eigenem Journal; Sitzungsordner werden
    /// hinterher gelöscht.
    private func withBackup(journal: BackupJournal?, _ body: (TrashBackup) throws -> Void) throws {
        #if os(macOS)
        let backup = TrashBackup(journal: journal)
        #else
        let trashRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: trashRoot) }
        let backup = TrashBackup(journal: journal, xdgTrash: XDGTrash(dataHome: trashRoot))
        #endif
        backup.isEnabled = true
        backup.folderLabel = "Tag Explosion Testsicherung"
        defer {
            for folder in backup.currentFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        try body(backup)
    }

    @Test("Historie eines Audios zeigt auch die Sicherungen seiner LRC-Sidecar; relocate zieht Pfade nach")
    func audioHistoryIncludesLyricsSidecar() throws {
        try withJournal { journal, directory in
            let copy = directory.appendingPathComponent("kopie.lrc")
            let data = Data("[00:01.00]Zeile\n".utf8)
            try data.write(to: copy)
            let flac = directory.appendingPathComponent("song.flac")
            let lrc = LRC.sidecarURL(for: flac)
            try journal.record(original: lrc, backup: copy, size: Int64(data.count), reason: BackupReason.sidecar)
            let versions = BackupHistory.versions(of: flac, journal: journal)
            #expect(versions.count == 1)
            #expect(versions[0].entry.originalPath == MediaFormats.canonicalFileURL(lrc).path)
            // Der Feldvergleich einer LRC-Sicherung zeigt die Zeilen.
            let fields = try BackupHistory.fieldMap(of: copy, kind: nil)
            #expect(fields["SYNCEDLYRICS"] == "[00:01.00]Zeile\n")

            let renamed = directory.appendingPathComponent("lied.lrc")
            #expect(try journal.relocate(from: lrc, to: renamed) == 1)
            #expect(try journal.relocate(from: lrc, to: renamed) == 0)
            #expect(BackupHistory.versions(of: flac, journal: journal).isEmpty)
            #expect(BackupHistory.versions(of: directory.appendingPathComponent("lied.flac"), journal: journal).count == 1)
        }
    }

    @Test("Journal-Roundtrip: Einträge kommen mit Zeit, Größe, Prüfsumme und Auslöser zurück")
    func journalRoundtrip() throws {
        try withJournal { journal, directory in
            let copy = directory.appendingPathComponent("kopie.bin")
            try Data("hallo".utf8).write(to: copy)
            let original = directory.appendingPathComponent("original.bin")
            let date = Date(timeIntervalSince1970: 1_700_000_000)

            let recorded = try journal.record(original: original, backup: copy, size: 5,
                                              reason: BackupReason.tags, date: date)
            let entries = journal.rawEntries()
            #expect(entries == [recorded])
            #expect(entries[0].originalPath == MediaFormats.canonicalFileURL(original).path)
            #expect(entries[0].backupPath == copy.path)
            #expect(entries[0].size == 5)
            #expect(entries[0].reason == "tags")
            // ISO-8601 mit Sekundenbruchteilen: millisekundengenau gleich.
            #expect(abs(entries[0].date.timeIntervalSince(date)) < 0.001)
            // SHA-256("hallo")
            #expect(entries[0].sha256
                    == "d3751d33f9cd5049c4af2b462735457e4d3baf130bcbb87f389e349fbaeb20b9")
            // Die Datei ist gültiges JSON mit Versionsfeld.
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: journal.url)) as? [String: Any]
            #expect(raw?["version"] as? Int == 1)
        }
    }

    @Test("Verfall: Einträge ohne Kopie verschwinden aus der Versionsliste, prune räumt sie weg")
    func expiredEntriesAreFilteredAndPruned() throws {
        try withJournal { journal, directory in
            let original = directory.appendingPathComponent("song.mp3")
            let existing = directory.appendingPathComponent("song-backup.mp3")
            try Data("x".utf8).write(to: existing)
            let vanished = directory.appendingPathComponent("weg.mp3")
            try journal.record(original: original, backup: existing, size: 1, reason: "tags",
                               date: Date(timeIntervalSinceNow: -60))
            // Kopie "verschwunden" (Papierkorb geleert): Eintrag ohne Datei.
            try journal.append(BackupJournalEntry(
                originalPath: original.path, backupPath: vanished.path,
                date: Date(), size: 1, sha256: nil, reason: "cover"))

            #expect(journal.rawEntries().count == 2)
            let versions = BackupHistory.versions(of: original, journal: journal)
            #expect(versions.map(\.entry.backupPath) == [existing.path])
            #expect(versions.first?.number == 1)

            // prune entfernt nur den verfallenen Eintrag — die vorhandene Kopie
            // bleibt (weder Journal-Eintrag noch Datei werden angefasst).
            #expect(try BackupHistory.prune(journal: journal) == 1)
            #expect(journal.rawEntries().count == 1)
            #expect(FileManager.default.fileExists(atPath: existing.path))

            // --older-than: der verbliebene Eintrag ist 60 s alt, also älter
            // als 0 Tage.
            #expect(try BackupHistory.prune(olderThanDays: 0, journal: journal) == 1)
            #expect(journal.rawEntries().isEmpty)
        }
    }

    @Test("Obergrenze: die ältesten Einträge fliegen zuerst")
    func journalIsCapped() throws {
        try withJournal(maxEntries: 3) { journal, directory in
            let copy = directory.appendingPathComponent("k.bin")
            try Data("k".utf8).write(to: copy)
            for index in 1...5 {
                try journal.record(original: directory.appendingPathComponent("o\(index)"),
                                   backup: copy, size: 1, reason: "tags")
            }
            let names = journal.rawEntries().map { URL(fileURLWithPath: $0.originalPath).lastPathComponent }
            #expect(names == ["o3", "o4", "o5"])
        }
    }

    @Test("Kaputtes Journal wird beiseitegelegt statt still überschrieben")
    func corruptJournalIsSetAside() throws {
        try withJournal { journal, _ in
            try Data("{ kein json".utf8).write(to: journal.url)
            #expect(journal.rawEntries().isEmpty)
            #expect(FileManager.default.fileExists(atPath: journal.url.path + ".corrupt"))
            let first = try Data(contentsOf: journal.url.appendingPathExtension("corrupt"))
            try Data("zweiter Defekt".utf8).write(to: journal.url)
            #expect(journal.rawEntries().isEmpty)
            #expect(try Data(contentsOf: journal.url.appendingPathExtension("corrupt")) == first)
            let saved = try FileManager.default.contentsOfDirectory(at: journal.url.deletingLastPathComponent(),
                includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt") }
            #expect(saved.count == 2)
        }
    }

    @Test("Unbekannte Journal-Version bleibt bei Lesen und Mutationen unverändert",
          arguments: ["[]", "{\"new-layout\":true}"])
    func futureJournalIsPreserved(entries: String) throws {
        try withJournal { journal, directory in
            let bytes = Data("{\"version\":2,\"entries\":\(entries),\"future\":true}".utf8)
            try bytes.write(to: journal.url)
            #expect(journal.rawEntries().isEmpty)
            #expect(try Data(contentsOf: journal.url) == bytes)
            let entry = BackupJournalEntry(originalPath: "old", backupPath: "copy",
                date: Date(), size: 0, sha256: nil, reason: "test")
            #expect(throws: TagError.self) { try journal.append(entry) }
            #expect(throws: TagError.self) { try journal.prune() }
            #expect(throws: TagError.self) {
                try journal.relocate(from: directory.appendingPathComponent("old"),
                                     to: directory.appendingPathComponent("new"))
            }
            #expect(try Data(contentsOf: journal.url) == bytes)
            #expect(!FileManager.default.fileExists(atPath: journal.url.path + ".corrupt"))
        }
    }

    @Test("Restore respektiert bekannte Existenz und Abwesenheit des Ziels")
    func restoreChecksDestinationState() throws {
        try withJournal { journal, root in
            let destination = root.appendingPathComponent("original.bin")
            let copy = root.appendingPathComponent("backup.bin")
            let bytes = Data("Version".utf8)
            try bytes.write(to: copy)
            let record = try journal.record(original: destination, backup: copy,
                size: Int64(bytes.count), reason: BackupReason.save)
            let version = BackupVersion(number: 1, entry: record)
            let absent = FileState.current(of: destination)
            try Data("Fremd".utf8).write(to: destination)
            #expect(throws: TagError.fileChangedOnDisk(path: destination.path)) {
                try BackupHistory.restore(version, expecting: absent, backup: TrashBackup())
            }
            #expect(try Data(contentsOf: destination) == Data("Fremd".utf8))
            let present = FileState.current(of: destination)
            try FileManager.default.removeItem(at: destination)
            #expect(throws: TagError.fileChangedOnDisk(path: destination.path)) {
                try BackupHistory.restore(version, expecting: present, backup: TrashBackup())
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            // Das Ziel fehlt tatsächlich noch: Wiederherstellen bleibt erlaubt.
            try BackupHistory.restore(version, expecting: absent, backup: TrashBackup())
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }

    @Test("Feld-Diff: nur geänderte Felder, sortiert, mit beiden Seiten")
    func fieldDiff() {
        let changes = BackupHistory.diff(
            version: ["ARTIST": "Alt", "TITLE": "Gleich", "COMMENT": "Nur früher"],
            current: ["ARTIST": "Neu", "TITLE": "Gleich", "GENRE": "Nur jetzt"])
        #expect(changes == [
            BackupFieldChange(key: "ARTIST", version: "Alt", current: "Neu"),
            BackupFieldChange(key: "COMMENT", version: "Nur früher", current: nil),
            BackupFieldChange(key: "GENRE", version: nil, current: "Nur jetzt"),
        ])
    }

    @Test("Abflachen: Listen mit ' / ', leere Werte weggelassen, Objekt-Listen indiziert")
    func flattenCoreFields() throws {
        var ebook = EbookCoreFields()
        ebook.title = "Buch"
        ebook.authors = ["A", "B"]
        let flat = try BackupHistory.flatten(ebook)
        #expect(flat["title"] == "Buch")
        #expect(flat["authors"] == "A / B")
        #expect(flat["isbn"] == nil)

        var document = DocumentCoreFields()
        document.custom = [DocumentCustomField(key: "Projekt", value: "X")]
        let flatDocument = try BackupHistory.flatten(document)
        #expect(flatDocument["custom[1].key"] == "Projekt")
        #expect(flatDocument["custom[1].value"] == "X")
    }

    @Test("Restore: Tags ändern → sichern → zurückholen → Datei byte-gleich wie vorher")
    func restoreRoundtrip() throws {
        try withJournal { journal, _ in
            try withBackup(journal: journal) { backup in
                let url = try Fixtures.workingCopy("sample.mp3")
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                let before = try Data(contentsOf: url)
                let artistBefore = try TagFile.read(at: url).properties
                    .first { $0.key == "ARTIST" }?.value

                try backup.backUp(url, reason: BackupReason.tags)
                try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Neu")], to: url)
                #expect(try Data(contentsOf: url) != before)

                let versions = BackupHistory.versions(of: url, journal: journal)
                #expect(versions.count == 1)
                let version = try #require(versions.first)
                #expect(version.entry.reason == "tags")
                #expect(version.entry.size == Int64(before.count))
                #expect(version.entry.sha256 != nil)
                #expect(try BackupJournal.sha256(of: URL(fileURLWithPath: version.entry.backupPath))
                        == version.entry.sha256)

                // Diff zeigt, was zurückkäme: ARTIST alt/neu.
                let changes = try BackupHistory.diff(current: url, against: version)
                let artist = try #require(changes.first { $0.key == "ARTIST" })
                #expect(artist.version == artistBefore)
                #expect(artist.current == "Neu")

                // Zurückspielen: byte-gleich, Prüfsumme gleich — und der
                // Stand von vorher (ARTIST=Neu) liegt seinerseits gesichert
                // im Papierkorb, damit das Undo selbst umkehrbar bleibt.
                try BackupHistory.restore(version, expecting: FileStamp.current(of: url), backup: backup)
                #expect(try Data(contentsOf: url) == before)
                #expect(try BackupJournal.sha256(of: url) == version.entry.sha256)
                let afterRestore = BackupHistory.versions(of: url, journal: journal)
                #expect(afterRestore.count == 2)
                #expect(afterRestore.first?.entry.reason == "restore")
                let undoUndo = try #require(afterRestore.first)
                let undoDiff = try BackupHistory.diff(current: url, against: undoUndo)
                #expect(undoDiff.first { $0.key == "ARTIST" }?.version == "Neu")
            }
        }
    }

    @Test("Restore verweigert eine Kopie, die nicht mehr zum Journal passt")
    func restoreRefusesTamperedBackup() throws {
        try withJournal { journal, _ in
            try withBackup(journal: journal) { backup in
                let url = try Fixtures.workingCopy("sample.mp3")
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                try backup.backUp(url, reason: BackupReason.tags)
                try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Neu")], to: url)
                let changed = try Data(contentsOf: url)
                let version = try #require(BackupHistory.versions(of: url, journal: journal).first)

                // Kopie manipulieren (gleiche Größe, anderer Inhalt).
                let copy = URL(fileURLWithPath: version.entry.backupPath)
                var bytes = try Data(contentsOf: copy)
                bytes[bytes.count / 2] ^= 0xFF
                try bytes.write(to: copy)

                #expect(throws: TagError.self) {
                    try BackupHistory.restore(version, backup: backup)
                }
                // Das Original bleibt unangetastet, keine neue Sicherung.
                #expect(try Data(contentsOf: url) == changed)
                #expect(BackupHistory.versions(of: url, journal: journal).count == 1)
            }
        }
    }

}

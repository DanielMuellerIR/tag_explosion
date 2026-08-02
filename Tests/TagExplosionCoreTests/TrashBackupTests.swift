// Der abgesicherte Modus: Vor jeder Änderung eine unveränderte Kopie im
// Papierkorb. Die Tests benutzen eine eigene Instanz mit eigenem
// Sicherungsordner und räumen ihre eigenen Ordner am Ende wieder weg — der
// Papierkorb des Rechners soll durch Testläufe nicht volllaufen.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Papierkorb-Sicherung", .serialized)
struct TrashBackupTests {

    /// Legt eine Sicherung an und entfernt den erzeugten Ordner danach wieder.
    private func withBackup(_ body: (TrashBackup) throws -> Void) throws {
        let backup = TrashBackup()
        backup.isEnabled = true
        backup.folderLabel = "Tag Explosion Testsicherung"
        defer {
            for folder in backup.currentFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        try body(backup)
    }

    @Test("Die Kopie im Papierkorb ist der Stand vor der Änderung")
    func backupHoldsStateBeforeChange() throws {
        try withBackup { backup in
            let url = try Fixtures.workingCopy("sample.mp3")
            let before = try Data(contentsOf: url)

            try backup.backUp(url)
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Neu")], to: url)

            let folder = try #require(backup.currentFolders.first)
            let copy = folder.appendingPathComponent(
                url.deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent("sample.mp3")
            #expect(try Data(contentsOf: copy) == before)
            #expect(try Data(contentsOf: url) != before)
            #expect(backup.backedUpBytes == Int64(before.count))
        }
    }

    @Test("Alle Sicherungen einer Sitzung landen in genau einem Ordner")
    func oneFolderPerSession() throws {
        try withBackup { backup in
            let first = try Fixtures.workingCopy("sample.mp3")
            let second = try Fixtures.workingCopy("sample.flac")
            try backup.backUp([first, second])
            #expect(backup.currentFolders.count == 1)

            let folder = try #require(backup.currentFolders.first)
            let contents = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)
            // Zwei Quellordner (je eigene Temp-Kopie) → zwei Unterordner.
            #expect(contents.count == 2)
        }
    }

    @Test("Ein unveränderter Stand wird nicht doppelt gesichert")
    func unchangedFileIsNotCopiedTwice() throws {
        try withBackup { backup in
            let url = try Fixtures.workingCopy("sample.mp3")
            try backup.backUp(url)
            let afterFirst = backup.backedUpBytes
            try backup.backUp(url)
            #expect(backup.backedUpBytes == afterFirst)

            // Nach einer echten Änderung sichert der nächste Aufruf wieder.
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Neu")], to: url)
            try backup.backUp(url)
            #expect(backup.backedUpBytes > afterFirst)
        }
    }

    @Test("Mehrere Sicherungen derselben Datei überschreiben sich nicht")
    func repeatedBackupsKeepBothVersions() throws {
        try withBackup { backup in
            let url = try Fixtures.workingCopy("sample.mp3")
            let first = try Data(contentsOf: url)
            try backup.backUp(url)
            try TagFile.write(properties: [TagProperty(key: "ARTIST", value: "Zweiter Stand")], to: url)
            let second = try Data(contentsOf: url)
            try backup.backUp(url)

            let folder = try #require(backup.currentFolders.first)
            let subfolder = folder.appendingPathComponent(
                url.deletingLastPathComponent().lastPathComponent)
            let copies = try FileManager.default.contentsOfDirectory(
                at: subfolder, includingPropertiesForKeys: nil)
            #expect(copies.count == 2)
            let contents = try copies.map { try Data(contentsOf: $0) }
            #expect(contents.contains(first))
            #expect(contents.contains(second))
        }
    }

    @Test("Nach verschwundener Sicherungskopie wird derselbe Stand neu gesichert")
    func vanishedBackupCopyIsRecreated() throws {
        // Der Merker "Stand ist schon gesichert" gilt nur, solange die Kopie
        // wirklich noch existiert. Wurde der Papierkorb geleert, muss ein
        // erneuter Schreibversuch wieder eine Sicherung bekommen.
        try withBackup { backup in
            let url = try Fixtures.workingCopy("sample.mp3")
            try backup.backUp(url)
            let folder = try #require(backup.currentFolders.first)
            let copy = folder.appendingPathComponent(
                url.deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent("sample.mp3")
            #expect(FileManager.default.fileExists(atPath: copy.path))

            // "Papierkorb geleert": Die Kopie verschwindet, der Stand der
            // Quelle bleibt unverändert.
            try FileManager.default.removeItem(at: copy)

            try backup.backUp(url)
            #expect(FileManager.default.fileExists(atPath: copy.path))
        }
    }

    @Test("Parallele Sicherungen teilen sich einen Ordner und scheitern nicht")
    func concurrentBackupsShareOneSessionFolder() async throws {
        // Ordner-Suche/-Anlage und Zielnamen-Wahl liefen früher als getrennte,
        // nicht atomare Schritte — zwei parallele erste Sicherungen konnten
        // doppelte Sitzungsordner anlegen oder denselben freien Namen wählen.
        let backup = TrashBackup()
        backup.isEnabled = true
        backup.folderLabel = "Tag Explosion Testsicherung"
        defer {
            for folder in backup.currentFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        // Alle Quelldateien liegen im SELBEN Ordner, damit sich die parallelen
        // Aufrufe wirklich um denselben Unterordner und freie Namen bewerben.
        let first = try Fixtures.workingCopy("sample.mp3")
        let directory = first.deletingLastPathComponent()
        var urls = [first]
        for index in 2...6 {
            let copy = directory.appendingPathComponent("sample-\(index).mp3")
            try FileManager.default.copyItem(at: first, to: copy)
            urls.append(copy)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { try backup.backUp(url) }
            }
            try await group.waitForAll()
        }

        #expect(backup.currentFolders.count == 1)
        let folder = try #require(backup.currentFolders.first)
        let subfolder = folder.appendingPathComponent(directory.lastPathComponent)
        let copies = try FileManager.default.contentsOfDirectory(
            at: subfolder, includingPropertiesForKeys: nil)
        #expect(copies.count == urls.count)
    }

    @Test("Ein zu großer Stapel scheitert vor der ersten Kopie",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func batchLargerThanFreeSpaceFailsBeforeCopying() throws {
        // Jede Datei einzeln würde die Platzprüfung bestehen; erst die Summe
        // überschreitet den freien Platz. Die Prüfung muss den GESAMTEN
        // Stapel bilanzieren und vor der ersten Kopie abbrechen.
        let volume = try TestVolume(megabytes: 24)
        defer { volume.detach() }
        // Auf dem HFS+-Testvolume muss die Platzmessung real funktionieren:
        // "important usage" liefert dort 0 (APFS-Konzept) — der Rueckfall auf
        // die einfache Kapazitaet ist Teil des geprueften Verhaltens.
        let free = try #require(VolumeSpace.availableBytes(
            at: volume.mountPoint.appendingPathComponent("x")))
        let budget = free - VolumeSpace.margin
        // Je Datei ~30 % des Budgets: Die Dateien selbst belegen beim Anlegen
        // schon 60 %, danach besteht EINE Kopie die Prüfung noch (30 % + Marge
        // passen in die restlichen 40 % + Marge), die Summe beider aber nicht.
        let fileSize = Int(budget * 3 / 10)
        try #require(fileSize > 0, "Testvolume unerwartet klein")

        let one = volume.mountPoint.appendingPathComponent("erste.mp3")
        let two = volume.mountPoint.appendingPathComponent("zweite.mp3")
        try Data(count: fileSize).write(to: one)
        try Data(count: fileSize).write(to: two)

        // Einzeln passt jede Datei: Das beweist zugleich, dass ein Nicht-APFS-
        // Volume mit freiem Platz nicht faelschlich als "voll" gilt.
        let single = TrashBackup()
        single.isEnabled = true
        single.folderLabel = "Tag Explosion Testsicherung"
        defer {
            for folder in single.currentFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        try single.backUp(one)
        #expect(single.backedUpBytes == Int64(fileSize))

        // Der Stapel beider Dateien überschreitet die Summe — Abbruch vor der
        // ersten Kopie (frische Instanz, damit wirklich beide anstehen).
        let batch = TrashBackup()
        batch.isEnabled = true
        batch.folderLabel = "Tag Explosion Testsicherung"
        defer {
            for folder in batch.currentFolders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        do {
            try batch.backUp([one, two])
            Issue.record("Der Stapel hätte an der Platzprüfung scheitern müssen")
        } catch TagError.notEnoughSpace {
            // erwartet: Abbruch VOR der ersten Kopie — kein Sitzungsordner
            #expect(batch.currentFolders.isEmpty)
            #expect(batch.backedUpBytes == 0)
        }
    }

    @Test("Abgeschaltet entsteht keine Kopie")
    func disabledCreatesNothing() throws {
        let backup = TrashBackup()
        backup.isEnabled = false
        let url = try Fixtures.workingCopy("sample.mp3")
        try backup.backUp(url)
        #expect(backup.currentFolders.isEmpty)
        #expect(backup.backedUpBytes == 0)
    }

    @Test("Der Core sichert nur, wenn App oder CLI es ausdrücklich einschalten")
    func libraryDefaultIsOff() {
        // Verhindert, dass ein Testlauf oder ein fremdes Programm, das den Core
        // einbindet, ungefragt in den Papierkorb schreibt.
        #expect(TrashBackup.shared.isEnabled == false)
    }
}

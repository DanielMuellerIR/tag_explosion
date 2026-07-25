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

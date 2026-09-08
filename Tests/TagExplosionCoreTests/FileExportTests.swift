import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Dateiexport")
struct FileExportTests {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tagx-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test("Neue Datei exakt anlegen, vorhandenen Stand sichern und atomar ersetzen")
    func createAndReplace() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("cover.bin")
            let alias = root.appendingPathComponent("original.bin")
            let backup = TrashBackup(xdgTrash: XDGTrash(dataHome: root.appendingPathComponent("trash")))
            backup.isEnabled = true
            let old = Data([1, 2, 3]), new = Data([4, 5])
            try FileExport.write(old, to: target, backup: backup)
            #expect(try Data(contentsOf: target) == old)
            #expect(backup.currentFolders.isEmpty)
            try FileManager.default.linkItem(at: target, to: alias)
            try FileExport.write(new, to: target, backup: backup)
            #expect(try Data(contentsOf: target) == new)
            #expect(try Data(contentsOf: alias) == old)
            let folder = try #require(backup.currentFolders.first)
            let saved = folder.appendingPathComponent(root.lastPathComponent).appendingPathComponent(target.lastPathComponent)
            #expect(try Data(contentsOf: saved) == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tagx-") })
        }
    }

    @Test("Fehlgeschlagene Sicherung lässt das Exportziel unverändert")
    func backupFailure() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("chapters.txt")
            let old = Data("Kapitel".utf8)
            try old.write(to: target)
            let backup = TrashBackup(journal: nil, xdgTrash: XDGTrash(dataHome: root.appendingPathComponent("trash")),
                                     copyFile: { _, _ in throw TagError.saveFailed(path: target.path) })
            backup.isEnabled = true
            #expect(throws: (any Error).self) { try FileExport.write(Data("Neu".utf8), to: target, backup: backup) }
            #expect(try Data(contentsOf: target) == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tagx-") })
        }
    }
}

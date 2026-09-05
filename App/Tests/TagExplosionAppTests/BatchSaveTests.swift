import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Batch-Ergebnisse", .serialized)
@MainActor
struct BatchSaveTests {
    @Test("Gemischte Ergebnisse bleiben erhalten; Retry und Konfliktentscheidung aktualisieren gezielt")
    func mixedResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated/sample.flac")
        let entries = try (0..<3).map { index in
            let url = directory.appendingPathComponent("\(index).flac")
            try FileManager.default.copyItem(at: fixture, to: url)
            let entry = FileEntry(url: url, loaded: .audio(try TagFile.read(at: url)))
            entry.setSingleValue("TITLE", "Neu")
            return entry
        }
        let model = AppModel()
        model.entries = entries
        let ok = await model.saveEntries(entries) { entry in
            await model.save(entry: entry, staleCandidate: entry) { _ in
                if entry.url == entries[1].url { throw CocoaError(.fileWriteNoPermission) }
                if entry.url == entries[2].url { throw PartialSaveError(completed: [entry.url.lastPathComponent], underlying: TagError.fileChangedOnDisk(path: entry.url.path)) }
                return (.audio(TagData(properties: [TagProperty(key: "TITLE", value: "Neu")], artworks: [], audio: nil)), nil)
            }
        }
        #expect(!ok)
        #expect(model.batchResults.map(\.status) == [.success, .failed, .failed])
        #expect(model.batchResults.suffix(2).allSatisfy { !$0.reason.isEmpty })
        #expect(entries[1].isDirty && entries[2].isDirty)
        #expect(model.pendingStaleWrite != nil)
        await model.confirmStaleWrite { entry in
            await model.save(entry: entry) { _ in
                (.audio(TagData(properties: [TagProperty(key: "TITLE", value: "Neu")], artworks: [], audio: nil)), nil)
            }
        }
        #expect(model.batchResults.map(\.status) == [.success, .failed, .success])
        var retried: [URL] = []
        await model.retryFailedSaves { entry in
            retried.append(entry.url)
            return await model.save(entry: entry) { _ in
                (.audio(TagData(properties: [TagProperty(key: "TITLE", value: "Neu")], artworks: [], audio: nil)), nil)
            }
        }
        #expect(retried == [entries[1].url])
        #expect(model.batchResults.map(\.status) == [.success, .success, .success])
        // Abbruch erst nach einem vollständigen Schreibaufruf.
        for entry in entries { entry.setSingleValue("TITLE", "Noch neuer") }
        var calls = 0
        _ = await model.saveEntries(entries) { _ in
            calls += 1
            model.cancelBatchSave()
            return true
        }
        #expect(calls == 1)
        #expect(model.batchResults.map(\.status) == [.success, .skipped, .skipped])
    }
}

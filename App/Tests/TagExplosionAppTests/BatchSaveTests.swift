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
        let fixture = AppTestFixtures.directory.appendingPathComponent("sample.flac")
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
            // Ein späteres Ziel gehört bereits zum Auftrag, auch wenn es
            // gerade noch keinen individuellen isSaving-Marker trägt.
            await model.remove(urls: [entries[1].url])
            #expect(model.pendingConflict == nil)
            #expect(model.entries.count == 3)
            model.cancelBatchSave()
            return true
        }
        #expect(calls == 1)
        #expect(model.batchResults.map(\.status) == [.success, .skipped, .skipped])
        let gate = BatchGate()
        let batch = Task {
            await model.saveEntries(entries) { entry in
                if entry === entries[0] {
                    return await model.save(entry: entry, staleCandidate: entry) { _ in
                        throw TagError.fileChangedOnDisk(path: entry.url.path)
                    }
                }
                if entry === entries[1] { await gate.wait() }
                return true
            }
        }
        for _ in 0..<2000 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await gate.started)
        #expect(model.pendingStaleWrite != nil)
        let confirm = Task {
            await model.confirmStaleWrite { _ in
                #expect(!model.isBatchSaving)
                return true
            }
        }
        for _ in 0..<2000 {
            if model.pendingStaleWrite == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await gate.release()
        _ = await batch.value
        await confirm.value

    }
}

private actor BatchGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

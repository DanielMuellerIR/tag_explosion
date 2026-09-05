import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Inkrementelles Laden", .serialized)
@MainActor
struct LoadingTests {
    @Test("Frühe Ergebnisse, stabile Reihenfolge, Reservierungen und Abbruch")
    func incrementalAndCancel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<20).map { index in
            let url = directory.appendingPathComponent(String(format: "%02d.flac", index))
            try Data().write(to: url)
            return MediaFormats.canonicalFileURL(url)
        }
        let model = AppModel()
        let reader = ControlledReader()
        let load = Task { await model.open(urls: urls, read: reader.read) }
        for _ in 0..<2000 {
            if await reader.count == 8 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await reader.count == 8)
        await reader.release(urls[3])
        for _ in 0..<2000 {
            if !model.entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.entries.map(\.url) == [urls[3]])
        #expect(model.isLoading)
        model.entries.first?.setSingleValue("TITLE", "Puffer")
        await model.open(urls: urls, read: reader.read)
        #expect(await reader.count <= 9)
        model.cancelLoading()
        await reader.releaseAll()
        await load.value
        #expect(!model.isLoading)
        #expect(model.entries.first?.firstValue("TITLE") == "Puffer")
        // Abgebrochene Reservierungen sind frei; der vorhandene Puffer bleibt.
        await model.open(urls: urls, read: reader.read)
        #expect(model.entries.count == 20)
        #expect(Set(model.entries.map(\.url)).count == 20)
        #expect(model.entries.first?.firstValue("TITLE") == "Puffer")
        #expect(await reader.peak <= 8)
    }

    @Test("Messung mit 1000 generierten FLAC-Dateien", .enabled(if: ProcessInfo.processInfo.environment["TAGX_LOAD_BENCHMARK"] == "1"))
    func benchmark() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated/sample.flac")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<1000 {
            try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("\(index).flac"))
        }
        let model = AppModel()
        let start = Date()
        var first: TimeInterval?
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if !model.entries.isEmpty { first = Date().timeIntervalSince(start); return }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await model.open(urls: [directory])
        let total = Date().timeIntervalSince(start)
        observer.cancel()
        print("LOAD_BENCHMARK first=\(first ?? total) total=\(total) count=\(model.entries.count)")
        #expect(model.entries.count == 1000)
    }
}

private actor ControlledReader {
    var count = 0
    var peak = 0
    private var active = 0
    private var free = false
    private var waits: [URL: CheckedContinuation<Void, Never>] = [:]
    func read(_ url: URL, _ kind: MediaKind) async throws -> (LoadedData, FileStamp?) {
        count += 1
        active += 1
        peak = max(peak, active)
        if !free { await withCheckedContinuation { waits[url] = $0 } }
        active -= 1
        return (.audio(TagData(properties: [], artworks: [], audio: nil)), nil)
    }
    func release(_ url: URL) { waits.removeValue(forKey: url)?.resume() }
    func releaseAll() {
        free = true
        let pending = waits.values
        waits.removeAll()
        for wait in pending { wait.resume() }
    }
}

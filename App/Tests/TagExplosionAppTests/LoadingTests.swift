import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Inkrementelles Laden")
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
        let reader = ControlledReader(initialCount: 8)
        let load = Task { await model.open(urls: urls, read: reader.read) }
        defer {
            load.cancel()
            Task { await reader.releaseAll() }
        }
        try await reader.initialReadsStarted.wait(for: "8 gestartete Leser")
        #expect(await reader.count == 8)
        await reader.release(urls[3])
        try await waitForObservation("erstes Ladeergebnis") { !model.entries.isEmpty }
        #expect(model.entries.map(\.url) == [urls[3]])
        #expect(model.isLoading)
        model.entries.first?.setSingleValue("TITLE", "Puffer")
        await reader.release(urls[1])
        try await waitForObservation("zweites Ladeergebnis") { model.entries.count == 2 }
        #expect(model.entries.map(\.url) == [urls[1], urls[3]])
        #expect(model.selection.isEmpty)
        let probe = ControlledReader()
        await probe.releaseAll()
        await model.open(urls: urls, read: probe.read)
        #expect(await probe.count == 0)
        model.cancelLoading()
        await reader.releaseAll()
        await load.value
        #expect(!model.isLoading)
        #expect(model.entries.last?.firstValue("TITLE") == "Puffer")
        // Abgebrochene Reservierungen sind frei; der vorhandene Puffer bleibt.
        await model.open(urls: urls, read: reader.read)
        #expect(model.entries.count == 20)
        #expect(Set(model.entries.map(\.url)).count == 20)
        #expect(model.entries.map(\.url) == [urls[1], urls[3]] + urls.filter { $0 != urls[1] && $0 != urls[3] })
        #expect(model.entries[1].firstValue("TITLE") == "Puffer")
        #expect(await reader.peak <= 8)
    }

    @Test("Neues Öffnen nach Abbruch besitzt eigene Reservierungen, Fortschritte und Fehler")
    func restartWhileCancelledReadersFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<3).map { index in
            let url = directory.appendingPathComponent("\(index).flac")
            try Data().write(to: url)
            return MediaFormats.canonicalFileURL(url)
        }
        let model = AppModel()
        let oldReader = ControlledReader(initialCount: 3, failures: [urls[0]])
        let freshReader = ControlledReader(initialCount: 3)
        let old = Task { await model.open(urls: urls, read: oldReader.read) }
        defer {
            old.cancel()
            Task { await oldReader.releaseAll() }
        }
        try await oldReader.initialReadsStarted.wait(for: "3 gestartete Leser")
        #expect(await oldReader.count == 3)
        await oldReader.release(urls[0])
        try await waitForObservation("verarbeiteter Lesefehler") { model.loadingCompleted == 1 }
        #expect(model.loadingCompleted == 1)
        model.cancelLoading()
        let fresh = Task { await model.open(urls: urls, read: freshReader.read) }
        defer {
            fresh.cancel()
            Task { await freshReader.releaseAll() }
        }
        try await freshReader.initialReadsStarted.wait(for: "3 gestartete Leser")
        #expect(await freshReader.count == 3)
        #expect(model.loadingCompleted == 0)
        #expect(model.loadingTotal == 3)
        model.alertMessage = "Aktueller Hinweis"
        await oldReader.releaseAll()
        await old.value
        #expect(model.alertMessage == "Aktueller Hinweis")

        // Der Abschluss des alten Auftrags darf die neuen Reservierungen
        // nicht freigeben und dadurch einen dritten Leseauftrag erlauben.
        let probe = ControlledReader()
        await probe.releaseAll()
        await model.open(urls: urls, read: probe.read)
        #expect(await probe.count == 0)
        #expect(model.entries.isEmpty)
        await freshReader.releaseAll()
        await fresh.value
        #expect(model.entries.map(\.url) == urls)
        #expect(model.selection == [urls[0]])
        #expect(model.loadingCompleted == 3)
        #expect(model.loadingTotal == 3)
        #expect(!model.isLoading)
    }

    @Test("Messung mit 1000 generierten FLAC-Dateien", .enabled(if: ProcessInfo.processInfo.environment["TAGX_LOAD_BENCHMARK"] == "1"))
    func benchmark() async throws {
        let fixture = AppTestFixtures.directory.appendingPathComponent("sample.flac")
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
    let initialReadsStarted = TestSignal()
    var count = 0
    var peak = 0
    private var active = 0
    private var free = false
    private var waits: [URL: CheckedContinuation<Void, Never>] = [:]
    private let initialCount: Int
    private let failures: Set<URL>

    init(initialCount: Int = 0, failures: Set<URL> = []) {
        self.initialCount = initialCount
        self.failures = failures
    }

    func read(_ url: URL, _ kind: MediaKind) async throws -> (LoadedData, FileStamp?) {
        count += 1
        if count == initialCount { initialReadsStarted.signal() }
        active += 1
        peak = max(peak, active)
        if !free { await withCheckedContinuation { waits[url] = $0 } }
        active -= 1
        if failures.contains(url) { throw CocoaError(.fileReadUnknown) }
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

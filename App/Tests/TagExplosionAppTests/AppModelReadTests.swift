import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Lesepfad")
@MainActor
struct AppModelReadTests {

    /// Sun-AU und Ogg-Video haben in TagLib keinen Leser — derselbe
    /// schreibgeschützte Anzeige-Weg wie bei AVI.
    @Test("Anzeige-Formate ohne TagLib-Leser öffnen schreibgeschützt",
          arguments: ["clip.avi", "ton.au", "clip.ogv"])
    func displayOnlyFormatsOpenReadOnly(name: String) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-display-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("nicht lesbar".utf8).write(to: url)

        let loaded = try AppModel.readLoaded(url: url, kind: .audio)
        guard case .audio(let data, _) = loaded else {
            Issue.record("Erwartet wurde ein Audio-Zustand")
            return
        }
        #expect(data.isReadOnly)
        #expect(data.properties.isEmpty)
    }

    @Test("Eine kaputte Audiodatei meldet weiterhin einen Fehler")
    func brokenAudioStillFails() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-broken-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("kaputt.flac")
        try Data("kein FLAC".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            _ = try AppModel.readLoaded(url: url, kind: .audio)
        }
    }
}

extension AppModelSaveTests {
    @Test("Überlappende Öffnen-Aufträge reservieren Dateien einmal und behalten Auswahl")
    func openReservesInFlightFilesAndKeepsStableSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Musik")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("A.mp3")
        let second = folder.appendingPathComponent("B.flac")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let model = AppModel()
        let gate = SaveGate()
        let secondOpenCalls = CallCounter()
        let firstOpen = Task { @MainActor in
            await model.open(urls: [first, folder]) { url, _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: url.lastPathComponent)],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        await gate.waitUntilStarted()
        #expect(model.isLoading)

        // Dieser Auftrag sieht beide URLs bereits in `openingURLs` und darf
        // deshalb weder einen zweiten Leser starten noch den Fortschritt beenden.
        let overlappingOpen = Task { @MainActor in
            await model.open(urls: [folder, folder]) { _, _ in
                await secondOpenCalls.increment()
                return (.audio(TagData(properties: [], artworks: [], audio: nil)), nil)
            }
        }
        await overlappingOpen.value
        #expect(await secondOpenCalls.value == 0)
        #expect(model.isLoading)

        await gate.release()
        await firstOpen.value
        #expect(!model.isLoading)
        #expect(model.entries.map(\.url) == [
            MediaFormats.canonicalFileURL(first),
            MediaFormats.canonicalFileURL(second),
        ])
        #expect(model.selection == [MediaFormats.canonicalFileURL(first)])
    }

    @Test("Eine verschwundene Videodatei wird nicht als read-only Platzhalter geöffnet")
    func readStampedRejectsAVanishedFile() {
        // `readLoaded` fängt für Video-Container einen Lesefehler bewusst als
        // read-only-Platzhalter ab. Ohne die Stempel-Pflicht landete eine gar
        // nicht mehr vorhandene .avi als scheinbar erfolgreich geöffneter
        // Eintrag in der Liste.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verschwunden-\(UUID().uuidString).avi")
        #expect(throws: TagError.cannotOpen(path: url.path)) {
            _ = try AppModel.readStamped(url: url, kind: .audio)
        }
    }

    @Test("Lesen liefert Inhalt und Stempel als konsistenten Schnappschuss")
    func readStampedRetriesUntilContentAndStampMatch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-read-stamped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wackelig.mp3")
        try Data("erster Stand".utf8).write(to: url)

        // Der erste Leseversuch wird von einer "fremden" Änderung überlappt:
        // Der Leser verändert die Datei nach dem Lesen selbst. Ein getrennt
        // erhobener Stempel gehörte dann zur neuen Datei, der Inhalt zur alten.
        var reads = 0
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio) { _, _ in
            reads += 1
            let title = try String(contentsOf: url, encoding: .utf8)
            let loaded = LoadedData.audio(TagData(
                properties: [TagProperty(key: "TITLE", value: title)], artworks: [], audio: nil))
            if reads == 1 {
                try Data("fremde Änderung mit anderer Länge".utf8).write(to: url)
            }
            return loaded
        }

        // Genau ein Wiederholungsversuch, und der Stempel passt zum Endstand.
        #expect(reads == 2)
        guard case .audio(let data, _) = loaded else {
            Issue.record("Audio-Schnappschuss fehlt")
            return
        }
        #expect(data.firstValue(for: "TITLE") == "fremde Änderung mit anderer Länge")
        #expect(stamp == FileStamp.current(of: url))

        // Kommt die Datei nie zur Ruhe, bricht das Lesen ab, statt einen
        // inkonsistenten Zustand zu liefern.
        var restlessReads = 0
        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            _ = try AppModel.readStamped(url: url, kind: .audio) { _, _ in
                restlessReads += 1
                try Data(repeating: 65, count: restlessReads).write(to: url)
                return LoadedData.audio(TagData(properties: [], artworks: [], audio: nil))
            }
        }
    }
}

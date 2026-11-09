import Foundation
import Testing
@testable import TagExplosionApplication
import TagExplosionCore

@Suite("DesktopService Review", .serialized)
@MainActor
struct DesktopServiceReviewTests {
    private func audio(_ name: String, cover: Bool = true) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/tmp/tagx-own-buffer/\(name).mp3"),
                  loaded: .audio(TagData(properties: [], artworks: cover ? [Artwork(data: Data([1]), pictureType: "Front Cover")] : [], audio: nil)))
    }
    private func setup(_ entries: [FileEntry], convert: @escaping @Sendable (Artwork, CoverTools.Conversion, ExternalToolRunner.Cancellation) throws -> Artwork = { art, _, _ in art }) -> (DesktopService, AppModel) {
        let model = AppModel()
        model.entries = entries
        model.selection = Set(entries.map(\.url))
        return (DesktopService(models: ["main": model, "other": AppModel()], convertArtwork: convert), model)
    }
    private func call(_ service: DesktopService, _ method: String, _ params: [String: DesktopValue] = [:]) async -> DesktopResponse {
        await service.handle(DesktopRequest(id: 1, method: method, params: .object(["revision": .number(0)].merging(params) { _, new in new })))
    }

    @Test("Erstes Kapitel und erste Lyricszeile entsprechen dem echten Codable-Vertrag")
    func emptyLists() async throws {
        let entry = audio("lists", cover: false)
        let (service, _) = setup([entry])
        let description = try #require(await call(service, "entry", ["path": .string(entry.url.path)]).result)
        var values = description.fields
        values["chapters"] = .array([.object(["title": .string(""), "start": .number(0), "end": .number(0)])])
        values["syncedLyrics"] = .array([.object(["time": .number(0), "text": .string("")])])
        let result = await call(service, "edit", ["path": .string(entry.url.path), "values": .object(values)])
        #expect(result.error == nil)
        #expect(entry.chapters == [Chapter(title: "", startMilliseconds: 0, endMilliseconds: 0)])
        #expect(entry.syncedLyrics == [SyncedLyricLine(milliseconds: 0, text: "")])
        // Ungültige alte Schlüssel dürfen keine Teiländerung am Puffer hinterlassen.
        values["chapters"] = .array([.object(["title": .string("bad"), "startMilliseconds": .number(0), "endMilliseconds": .number(0)])])
        let bad = await call(service, "edit", ["revision": .number(1), "path": .string(entry.url.path), "values": .object(values)])
        #expect(bad.error != nil)
        #expect(entry.chapters.first?.title == "")
    }

    @Test("NFO-Stapelbewertung behält String und lehnt Zahl ohne Teilübernahme ab")
    func nfoRating() async {
        let entries = ["a", "b"].map { name in
            FileEntry(url: URL(fileURLWithPath: "/tmp/tagx-own-buffer/\(name).nfo"), loaded: .sidecar(.nfo(NFOContents(rootName: "movie", fields: NFOFields(), info: [], urls: []))))
        }
        let (service, _) = setup(entries)
        let bad = await call(service, "batchEdit", ["changes": .object(["rating": .number(7.5)])])
        #expect(bad.error != nil)
        #expect(entries.allSatisfy { $0.nfoFields.rating == "" })
        let good = await call(service, "batchEdit", ["changes": .object(["rating": .string("7.50")])])
        #expect(good.error == nil)
        #expect(entries.allSatisfy { $0.nfoFields.rating == "7.50" })
        let clear = await call(service, "batchEdit", ["revision": .number(1), "changes": .object(["rating": .string("")])])
        #expect(clear.error == nil)
        #expect(entries.allSatisfy { $0.nfoFields.rating == "" })
    }

    @Test("Batch-Cover meldet Fehler und überspringt fehlende Cover ohne andere Ergebnisse zu verlieren")
    func coverErrors() async {
        let entries = [audio("bad"), audio("good"), audio("bare", cover: false)]
        entries[1].artworks[0].data = Data([3])
        let (service, _) = setup(entries) { art, _, _ in
            if art.data == Data([1]) { throw CoverToolError.unsupportedImage }
            var converted = art; converted.data = Data([2]); return converted
        }
        let response = await call(service, "batchCover", ["action": .string("convert")])
        #expect(response.error == nil)
        #expect(response.result?["alert"].text?.contains("bad.mp3") == true)
        #expect(entries[0].frontCover?.data == Data([1]))
        #expect(entries[1].frontCover?.data == Data([2]))
        #expect(entries[2].frontCover == nil)
    }

    @Test("Batch-Cover startet nicht mit ausstehender Entscheidung oder Save", arguments: ["decision", "saving"])
    func coverInitialLock(_ mode: String) async {
        let entry = audio("locked")
        let (service, model) = setup([entry])
        entry.setSingleValue("TITLE", "dirty")
        if mode == "decision" {
            await model.requestWindowClose {}
            #expect(model.pendingConflict != nil)
        } else {
            #expect(entry.beginSaving() != nil)
        }
        let response = await call(service, "batchCover", ["action": .string("convert")])
        #expect(response.error?.code == "busy")
        #expect(entry.frontCover?.data == Data([1]))
        if mode == "saving" { entry.finishSaving() }
    }

    @Test("Batch-Cover gibt MainActor frei; Abbruch, Revision und Sperren verhindern Übernahme", arguments: ["cancel", "revision", "saving", "decision", "cover", "removed", "success"])
    func coverReentrancy(_ mode: String) async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let entries = [audio("a"), audio("b"), audio("bare", cover: false)]
        let (service, model) = setup(entries) { art, _, cancellation in
            started.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            if mode == "cancel" {
                #expect(throws: CancellationError.self) { try cancellation.check() }
            } else {
                try cancellation.check()
            }
            var converted = art; converted.data = Data([2]); return converted
        }
        let task = Task { await call(service, "batchCover", ["action": .string("convert")]) }
        defer { release.signal(); release.signal() }
        let running = try await BlockingWork.run { started.wait(timeout: .now() + 2) == .success }
        #expect(running)
        let state = await call(service, "state")
        #expect(state.result?["busy"].flag == true)
        #expect(state.result?["coverTotal"].integer == 3)
        #expect(await call(service, "prepareUpdate").result == .bool(false))
        #expect(await service.handle(DesktopRequest(id: 2, session: "other", method: "state")).error == nil)
        #expect(await call(service, "batchCover", ["action": .string("convert")]).error?.code == "busy")
        #expect(entries[0].frontCover?.data == Data([1]))
        if mode == "cover" {
            #expect(await call(service, "removeCover", ["path": .string(entries[0].url.path)]).error == nil)
        } else if mode == "cancel" {
            #expect(await call(service, "cancel").error == nil)
        } else if mode == "revision" {
            #expect(await call(service, "batchEdit", ["changes": .object(["TITLE": .array([.string("later")])])]).error == nil)
        } else if mode == "decision" {
            entries[0].setSingleValue("TITLE", "pending close")
            await model.requestWindowClose {}
            #expect(model.pendingConflict != nil)
        } else if mode == "removed" {
            model.entries.removeLast()
        } else if mode == "saving" {
            entries[0].setSingleValue("TITLE", "save snapshot")
            #expect(entries[0].beginSaving() != nil)
        }
        release.signal(); release.signal()
        let response = await task.value
        if mode == "success" {
            #expect(response.error == nil)
            #expect(entries[0].frontCover?.data == Data([2]))
            #expect(entries[1].frontCover?.data == Data([2]))
        } else {
            #expect(response.error != nil)
            #expect(entries[0].frontCover?.data == (mode == "cover" ? nil : Data([1])))
            #expect(entries[1].frontCover?.data == Data([1]))
        }
        if mode == "revision" { #expect(entries[0].properties.first(where: { $0.key == "TITLE" })?.value == "later") }
        if mode == "saving" { entries[0].finishSaving() }
        #expect(await call(service, "state").result?["busy"].flag == false)
        #expect(model.entries.count == (mode == "removed" ? 2 : 3))
    }
}

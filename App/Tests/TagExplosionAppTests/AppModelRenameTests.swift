// Umbenennen aus Tags im Modell: Datei wird bewegt, Liste und Auswahl folgen
// dem neuen Pfad, Konflikte lassen alles unangetastet. Tags aus dem
// Dateinamen landen nur im Puffer (dirty), nie direkt auf der Platte.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("AppModel Umbenennen", .serialized)
@MainActor
struct AppModelRenameTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioEntry(at url: URL, _ fields: [String: String]) throws -> FileEntry {
        try Data("inhalt \(url.lastPathComponent)".utf8).write(to: url)
        let properties = fields.sorted { $0.key < $1.key }
            .map { TagProperty(key: $0.key, value: $0.value) }
        return FileEntry(url: url, loaded: .audio(TagData(properties: properties, artworks: [], audio: nil)))
    }

    @Test("Umbenennen bewegt die Datei; Eintrag, Auswahl und Stempel folgen")
    func renameMovesFileAndRelocatesEntry() async throws {
        let directory = try makeDirectory("rename")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try audioEntry(at: directory.appendingPathComponent("a.mp3"),
                                   ["TRACKNUMBER": "1", "TITLE": "Eins"])
        let second = try audioEntry(at: directory.appendingPathComponent("b.mp3"),
                                    ["TRACKNUMBER": "2", "TITLE": "Zwei"])
        let stampBefore = first.diskStamp
        let model = AppModel()
        model.entries = [first, second]
        model.selection = [first.url]

        let pattern = try FilenamePattern("%{track:2} %{title}")
        let plan = model.renamePlan(for: [first, second], pattern: pattern)
        #expect(plan.items.map(\.target) == ["01 Eins.mp3", "02 Zwei.mp3"])

        await model.renameFiles([first, second], pattern: pattern)

        #expect(model.alertMessage == nil)
        #expect(model.pendingConflict == nil)
        let renamedFirst = directory.appendingPathComponent("01 Eins.mp3")
        #expect(FileManager.default.fileExists(atPath: renamedFirst.path))
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        // Gleiche Position, neuer Pfad, Inhalt und Puffer erhalten.
        #expect(model.entries.map(\.url.lastPathComponent) == ["01 Eins.mp3", "02 Zwei.mp3"])
        #expect(model.entries[0].firstValue("TITLE") == "Eins")
        #expect(!model.entries[0].isDirty)
        #expect(model.entries[0].diskStamp == stampBefore)
        #expect(model.selection == [renamedFirst])
        #expect(try Data(contentsOf: renamedFirst) == Data("inhalt a.mp3".utf8))
    }

    @Test("Konflikt im Plan: nichts wird umbenannt, der Hinweis nennt den Grund")
    func renameRefusesConflictingPlan() async throws {
        let directory = try makeDirectory("conflict")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try audioEntry(at: directory.appendingPathComponent("a.mp3"), ["ARTIST": "Duo"])
        let second = try audioEntry(at: directory.appendingPathComponent("b.mp3"), ["ARTIST": "Duo"])
        let model = AppModel()
        model.entries = [first, second]

        await model.renameFiles([first, second], pattern: try FilenamePattern("%{artist}"))

        #expect(model.alertMessage?.contains("b.mp3") == true)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        #expect(model.entries.map(\.url) == [first.url, second.url])
    }

    @Test("Ungespeicherte Änderungen: Umbenennen wartet auf die Entscheidung")
    func renameAsksBeforeTouchingDirtyEntries() async throws {
        let directory = try makeDirectory("dirty")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try audioEntry(at: directory.appendingPathComponent("a.mp3"), ["TITLE": "Alt"])
        entry.setSingleValue("TITLE", "Neu")
        let model = AppModel()
        model.entries = [entry]

        await model.renameFiles([entry], pattern: try FilenamePattern("%{title}"))

        // Der Dialog steht; die Datei ist noch unbenannt.
        #expect(model.pendingConflict != nil)
        #expect(FileManager.default.fileExists(atPath: entry.url.path))

        // Verwerfen: Der Name entsteht aus dem Plattenstand ("Alt"), nicht
        // aus dem verworfenen Puffer.
        await model.resolvePendingConflict(.discard) { _ in true }
        #expect(model.pendingConflict == nil)
        #expect(model.entries.map(\.url.lastPathComponent) == ["Alt.mp3"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Alt.mp3").path))
    }

    @Test("Tags aus Dateiname füllen den Puffer und melden Nicht-Treffer")
    func parseFillsBufferAndReportsMismatch() throws {
        let directory = try makeDirectory("parse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let matching = try audioEntry(at: directory.appendingPathComponent("03 - Miles - So What.mp3"), [:])
        let other = try audioEntry(at: directory.appendingPathComponent("ohne nummer.mp3"), [:])
        let bytesBefore = try Data(contentsOf: matching.url)
        let model = AppModel()
        model.entries = [matching, other]

        let outcome = model.applyFileNamePattern(
            try FilenamePattern("%{track:2} - %{artist} - %{title}"), to: [matching, other])

        #expect(outcome.applied == 1)
        #expect(outcome.unmatched == ["ohne nummer.mp3"])
        #expect(matching.isDirty)
        #expect(matching.firstValue("TRACKNUMBER") == "3")
        #expect(matching.firstValue("ARTIST") == "Miles")
        #expect(matching.firstValue("TITLE") == "So What")
        #expect(!other.isDirty)
        // Nur der Puffer — die Datei selbst bleibt byte-gleich.
        #expect(try Data(contentsOf: matching.url) == bytesBefore)
        #expect(model.alertMessage?.contains("ohne nummer.mp3") == true)
    }

    @Test("Bild- und E-Book-Einträge liefern Musterfelder und nehmen geparste Werte an")
    func imageAndEbookEntriesSupportPatterns() throws {
        let image = FileEntry(url: URL(fileURLWithPath: "/tmp/2021 Anna Strand.jpg"),
                              loaded: .image(ImageCoreFields(title: "Strand", creator: "Anna")))
        #expect(image.patternFields["ARTIST"] == "Anna")
        try image.applyParsedFields(["TITLE": "Berg"])
        #expect(image.imageFields.title == "Berg")
        #expect(image.isDirty)
        #expect(throws: PatternFields.ApplyError.self) {
            try image.applyParsedFields(["ALBUM": "x"])
        }

        let ebook = FileEntry(url: URL(fileURLWithPath: "/tmp/buch.epub"),
                              loaded: .ebook(EbookCoreFields(title: "Dune", authors: ["Herbert"]), cover: nil))
        #expect(ebook.patternFields["AUTHOR"] == "Herbert")
        try ebook.applyParsedFields(["SERIES": "Dune", "SERIESINDEX": "2"])
        #expect(ebook.ebookFields.series == "Dune")
        #expect(ebook.ebookFields.seriesIndex == "2")
    }

    @Test("Muster-Verlauf: vorn einsortiert, ohne Dubletten, gedeckelt")
    func patternHistoryRemembersRecentPatterns() {
        let key = PatternHistory.Direction.rename.defaultsKey
        let saved = UserDefaults.standard.stringArray(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        for index in 0..<(PatternHistory.maxEntries + 2) {
            PatternHistory.remember("%{title} \(index)", .rename)
        }
        PatternHistory.remember("%{title} 3", .rename)
        let history = PatternHistory.load(.rename)
        #expect(history.count == PatternHistory.maxEntries)
        #expect(history.first == "%{title} 3")
        #expect(history.filter { $0 == "%{title} 3" }.count == 1)
        #expect(PatternHistory.initialPattern(.rename) == "%{title} 3")
    }
}

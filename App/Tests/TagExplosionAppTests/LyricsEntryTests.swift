// Feste Felder im Editor-Puffer (AP7): dirty-Erkennung für Lyrics-Sprache und
// synchronisierte Zeilen, Snapshot nur mit Änderungen, Speichern über den
// echten Weg — SYLT in MP3, Sidecar `<name>.lrc` bei FLAC ohne Neuschreiben
// der Mediendatei — und Ablehnung ungültiger Lautheitswerte vor der Sicherung.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("FileEntry Lyrics und feste Felder", .serialized)
@MainActor
struct LyricsEntryTests {

    private let lines = [
        SyncedLyricLine(milliseconds: 0, text: "Intro"),
        SyncedLyricLine(milliseconds: 1250, text: "Zeile"),
    ]

    @Test("Sprache und synchronisierte Zeilen machen den Eintrag dirty; Verwerfen stellt zurück")
    func lyricsAffectDirtyState() {
        let original = TagData(properties: [], artworks: [], audio: nil,
                               lyricsLanguage: "deu", syncedLyrics: lines, supportsSyncedLyrics: true)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/lyrics.mp3"), loaded: .audio(original), stamp: nil)
        #expect(entry.supportsSyncedLyrics)
        #expect(!entry.isDirty)
        entry.lyricsLanguage = "eng"
        #expect(entry.isDirty)
        entry.revert()
        #expect(!entry.isDirty)
        entry.syncedLyrics.removeLast()
        #expect(entry.isDirty)
        entry.revert()
        #expect(entry.syncedLyrics == lines)
    }

    @Test("Snapshot trägt nur geänderte Lyrics-Teile; reine Sidecar-Änderung fasst das Medium nicht an")
    func snapshotCarriesOnlyChanges() {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "T")], artworks: [], audio: nil,
                               supportsSyncedLyrics: false)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/lyrics.flac"), loaded: .audio(original), stamp: nil)
        entry.syncedLyrics = lines
        guard case .audio(let snapshot)? = entry.beginSaving() else {
            Issue.record("Snapshot fehlt")
            return
        }
        entry.finishSaving()
        #expect(snapshot.syncedLyrics == lines)
        #expect(snapshot.lyricsLanguage == nil)
        #expect(!snapshot.mediaChanged)

        entry.setSingleValue("TITLE", "Neu")
        guard case .audio(let second)? = entry.beginSaving() else {
            Issue.record("Snapshot fehlt")
            return
        }
        entry.finishSaving()
        #expect(second.mediaChanged)
    }

    @Test("MP3: LRC-Zeilen und Sprache landen als SYLT/USLT in der Datei",
          .enabled(if: LyricsFixture.isAvailable, "Audio-Fixture fehlt"))
    func mp3SavesSyncedLyrics() async throws {
        let url = try LyricsFixture.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        entry.properties = FixedFields.settingLyrics("Intro\nZeile", in: entry.properties)
        entry.lyricsLanguage = "deu"
        entry.syncedLyrics = lines

        let model = AppModel()
        #expect(await model.save(entry: entry), Comment(rawValue: entry.lastError ?? ""))
        #expect(!entry.isDirty)
        let data = try TagFile.read(at: url)
        #expect(data.syncedLyrics == lines)
        #expect(data.lyricsLanguage == "deu")
        #expect(FixedFields.lyricsText(in: data.properties) == "Intro\nZeile")
        #expect(!FileManager.default.fileExists(atPath: LRC.sidecarURL(for: url).path))
    }

    @Test("FLAC: synchronisierte Zeilen gehen in die Sidecar, die Mediendatei bleibt byteweise gleich",
          .enabled(if: LyricsFixture.isAvailable, "Audio-Fixture fehlt"))
    func flacSavesSidecarOnly() async throws {
        let url = try LyricsFixture.workingCopy("sample.flac")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        #expect(!entry.supportsSyncedLyrics)
        entry.syncedLyrics = lines

        let model = AppModel()
        #expect(await model.save(entry: entry), Comment(rawValue: entry.lastError ?? ""))
        #expect(!entry.isDirty)
        #expect(try Data(contentsOf: url) == bytes)
        let sidecar = LRC.sidecarURL(for: url)
        #expect(try LRC.loadSidecar(for: url) == lines)

        // Neu laden: die Sidecar-Zeilen erscheinen wieder im Puffer.
        let (reloaded, _) = try AppModel.readStamped(url: url, kind: .audio)
        guard case .audio(let data, _) = reloaded else {
            Issue.record("Erwartet wurde ein Audio-Zustand")
            return
        }
        #expect(data.syncedLyrics == lines)

        // Entfernen löscht die Sidecar.
        entry.syncedLyrics = []
        #expect(await model.save(entry: entry), Comment(rawValue: entry.lastError ?? ""))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("Ungültiger ReplayGain-Wert scheitert vor der Sicherung mit Feldname, Datei unverändert",
          .enabled(if: LyricsFixture.isAvailable, "Audio-Fixture fehlt"))
    func invalidLoudnessIsRejectedBeforeWriting() async throws {
        let url = try LyricsFixture.workingCopy("sample.mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        // Am geprüften Textfeld vorbei direkt in den Puffer (wie ein Archiv-Import).
        entry.setSingleValue("REPLAYGAIN_TRACK_GAIN", "-99 dB")

        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError?.contains("REPLAYGAIN_TRACK_GAIN") == true, Comment(rawValue: entry.lastError ?? ""))
        #expect(entry.isDirty)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("FLAC: eine fremd geänderte Sidecar wird beim Speichern erkannt, nicht überschrieben",
          .enabled(if: LyricsFixture.isAvailable, "Audio-Fixture fehlt"))
    func foreignSidecarChangeIsDetected() async throws {
        let url = try LyricsFixture.workingCopy("sample.flac")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sidecar = LRC.sidecarURL(for: url)
        try LRC.writeSidecar(lines, for: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        #expect(entry.syncedLyrics == lines)

        // Ein anderes Programm schreibt die Sidecar um (andere Größe → anderer Stempel).
        let foreign = [SyncedLyricLine(milliseconds: 0, text: "Fremde Fassung, deutlich länger")]
        try Data(LRC.render(foreign).utf8).write(to: sidecar)

        entry.syncedLyrics = lines + [SyncedLyricLine(milliseconds: 2000, text: "Neu")]
        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError?.contains("changed on disk") == true, Comment(rawValue: entry.lastError ?? ""))
        #expect(model.pendingStaleWrite != nil)
        // Die fremde Fassung liegt unverändert auf der Platte.
        #expect(try LRC.loadSidecar(for: url) == foreign)

        // Bewusstes Überschreiben nach der Rückfrage gilt auch für die Sidecar.
        #expect(await model.save(entry: entry, ignoringDiskChange: true), Comment(rawValue: entry.lastError ?? ""))
        #expect(try LRC.loadSidecar(for: url)?.count == 3)
        #expect(!entry.isDirty)
    }
}

/// Audio-Fixtures des Root-Pakets (Generator läuft bei Bedarf selbst).
private enum LyricsFixture {
    static let directory: URL? = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let generated = repoRoot.appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated")
        if !FileManager.default.fileExists(atPath: generated.appendingPathComponent("sample.flac").path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [repoRoot.appendingPathComponent(
                "Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh").path]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return FileManager.default.fileExists(atPath: generated.appendingPathComponent("sample.flac").path)
            ? generated : nil
    }()

    static var isAvailable: Bool { directory != nil }

    enum FixtureError: Error { case missing }

    static func workingCopy(_ name: String) throws -> URL {
        guard let directory else { throw FixtureError.missing }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-lyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: target)
        return target
    }

}

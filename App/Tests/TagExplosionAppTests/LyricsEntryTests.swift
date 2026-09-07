// Feste Felder im Editor-Puffer (AP7): dirty-Erkennung für Lyrics-Sprache und
// synchronisierte Zeilen, Snapshot nur mit Änderungen, Speichern über den
// echten Weg — SYLT in MP3, Sidecar `<name>.lrc` bei FLAC ohne Neuschreiben
// der Mediendatei — und Ablehnung ungültiger Lautheitswerte vor der Sicherung.
import Foundation
import TagExplosionTestSupport
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
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"))
    func mp3SavesSyncedLyrics() async throws {
        let url = try MediaTestFixtures.workingCopy("sample.mp3")
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
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"))
    func flacSavesSidecarOnly() async throws {
        let url = try MediaTestFixtures.workingCopy("sample.flac")
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
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"))
    func invalidLoudnessIsRejectedBeforeWriting() async throws {
        let url = try MediaTestFixtures.workingCopy("sample.mp3")
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

    @Test("Später NFO-Konflikt nennt die bereits geschriebene LRC")
    func sidecarFailureReportsCompletedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("video.mp4")
        let nfoURL = root.appendingPathComponent("video.nfo")
        try Data("<movie><title>Alt</title></movie>".utf8).write(to: nfoURL)
        let reading = try KodiNFOFile.readSnapshot(url: nfoURL)
        let audio = FileEntry.AudioSnapshot(properties: [], artworks: [], chapters: nil,
            syncedLyrics: lines, lyricsLanguage: nil,
            original: TagData(properties: [], artworks: [], audio: nil),
            nfo: FileEntry.NFOSnapshot(url: nfoURL, fields: NFOFields(title: "Neu"),
                original: reading.value.fields, stamp: reading.stamp))
        try AppFileIO.prepareAudioSidecars(audio, for: media)
        // Genau zwischen Vorprüfung und Austausch ändert ein fremder Schreiber
        // die zweite Datei. Die erste ist beim Entdecken des Konflikts fertig.
        let foreign = Data("<movie><title>Fremde neue Fassung</title></movie>".utf8)
        try foreign.write(to: nfoURL)
        do {
            try AppFileIO.writeAudioSidecars(audio, for: media)
            Issue.record("NFO-Konflikt fehlt")
        } catch let error as PartialSaveError {
            #expect(error.completed == ["video.lrc"])
            #expect(error.underlying as? TagError == .fileChangedOnDisk(path: nfoURL.path))
        }
        #expect(try LRC.loadSidecar(for: media) == lines)
        #expect(try Data(contentsOf: nfoURL) == foreign)
    }

    @Test("MP4: ungültige NFO verhindert auch das Schreiben geänderter Lyrics",
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"),
          arguments: [false, true])
    func sidecarValidationPrecedesAnyWrite(mediaChanged: Bool) async throws {
        let url = try MediaTestFixtures.workingCopy("sample.mp4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let nfoURL = url.deletingPathExtension().appendingPathExtension("nfo")
        let nfoBytes = Data("<movie><title>Original</title><year>2020</year></movie>".utf8)
        try nfoBytes.write(to: nfoURL)
        let mediaBytes = try Data(contentsOf: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        entry.syncedLyrics = lines
        entry.videoNFOFields.year = "ungültig"
        if mediaChanged { entry.setSingleValue("TITLE", "Neue Tags") }
        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError?.contains("year") == true)
        #expect(try LRC.loadSidecar(for: url) == nil)
        #expect(try Data(contentsOf: nfoURL) == nfoBytes)
        #expect(try Data(contentsOf: url) == mediaBytes)
        #expect(entry.isDirty)

        entry.videoNFOFields.year = "2021"
        #expect(await model.save(entry: entry))
        #expect(try LRC.loadSidecar(for: url) == lines)
        #expect(try KodiNFOFile.read(url: nfoURL).fields.year == "2021")
        #expect(!entry.isDirty)
    }

    @Test("FLAC: eine fremd geänderte Sidecar wird beim Speichern erkannt, nicht überschrieben",
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"),
          arguments: [false, true], [false, true])
    func foreignSidecarChangeIsDetected(existed: Bool, mediaChanged: Bool) async throws {
        let url = try MediaTestFixtures.workingCopy("sample.flac")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sidecar = LRC.sidecarURL(for: url)
        if existed { try LRC.writeSidecar(lines, for: url) }
        let mediaBytes = try Data(contentsOf: url)
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let entry = FileEntry(url: url, loaded: loaded, stamp: stamp)
        #expect(entry.syncedLyrics == (existed ? lines : []))

        // Ein anderes Programm schreibt die Sidecar um (andere Größe → anderer Stempel).
        let foreign = [SyncedLyricLine(milliseconds: 0, text: "Fremde Fassung, deutlich länger")]
        try Data(LRC.render(foreign).utf8).write(to: sidecar)

        entry.syncedLyrics = lines + [SyncedLyricLine(milliseconds: 2000, text: "Neu")]
        if mediaChanged { entry.setSingleValue("TITLE", "Neue Medien-Tags") }
        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError?.contains("changed on disk") == true, Comment(rawValue: entry.lastError ?? ""))
        #expect(model.pendingStaleWrite != nil)
        // Die fremde Fassung liegt unverändert auf der Platte.
        #expect(try LRC.loadSidecar(for: url) == foreign)
        #expect(try Data(contentsOf: url) == mediaBytes)

        // Bewusstes Überschreiben nach der Rückfrage gilt auch für die Sidecar.
        #expect(await model.save(entry: entry, ignoringDiskChange: true), Comment(rawValue: entry.lastError ?? ""))
        #expect(try LRC.loadSidecar(for: url)?.count == 3)
        #expect(!entry.isDirty)
    }
}

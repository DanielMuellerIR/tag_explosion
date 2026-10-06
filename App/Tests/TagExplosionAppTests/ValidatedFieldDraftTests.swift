import Foundation
import Testing
import TagExplosionCore
import TagExplosionTestSupport
@testable import TagExplosionApp

@Suite("Geprüfte Feldeingabe")
@MainActor
struct ValidatedFieldDraftTests {
    private func entry(_ value: String = "") -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/tmp/draft.mp3"), loaded: .audio(TagData(
            properties: value.isEmpty ? [] : [TagProperty(key: FixedFields.replayGainAlbumGain, value: value)],
            artworks: [], audio: nil, supportsSyncedLyrics: true)))
    }

    @Test("Fokus allein schreibt gemischte Batchwerte nicht")
    func unchangedFocus() throws {
        let entries = [entry("-6.00 dB"), entry("-3.00 dB")]
        for item in entries { try item.commitFixedFieldDraft(FixedFields.replayGainAlbumGain) }
        #expect(entries.map { $0.firstValue(FixedFields.replayGainAlbumGain) } == ["-6.00 dB", "-3.00 dB"])
        #expect(entries.allSatisfy { !$0.isDirty })
    }

    @Test("Speichern bestätigt noch fokussierte Entwürfe und erhält spätere Eingaben")
    func saveDrafts() throws {
        let item = entry()
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = " -6 dB "
        item.lyricsLanguageDraft = "DEU"
        #expect(item.isDirty)
        guard case .audio(let audio)? = item.beginSaving() else { Issue.record("Snapshot fehlt"); return }
        #expect(audio.properties.contains(TagProperty(key: FixedFields.replayGainAlbumGain, value: "-6.00 dB")))
        #expect(audio.lyricsLanguage == "deu")
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "-3 dB"
        item.lyricsLanguageDraft = "FRA"
        item.acceptSaved(.audio(audio), reloaded: .audio(TagData(properties: audio.properties,
            artworks: [], audio: nil, lyricsLanguage: "deu", supportsSyncedLyrics: true)), stamp: nil)
        item.finishSaving()
        #expect(item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] == "-3 dB")
        #expect(item.lyricsLanguageDraft == "FRA")
        #expect(item.isDirty)
        item.revert()
        #expect(!item.isDirty)
        #expect(item.fixedFieldDrafts.isEmpty)
    }

    @Test("Eine ausdrücklich leere Batch-Eingabe entfernt gemischte Werte")
    func clearingMixedValues() throws {
        let entries = [entry("-6.00 dB"), entry("-3.00 dB")]
        for item in entries { item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "" }
        for item in entries {
            guard case .audio(let snapshot)? = item.beginSaving() else { Issue.record("Snapshot fehlt"); return }
            #expect(!snapshot.properties.contains { $0.key == FixedFields.replayGainAlbumGain })
            item.finishSaving()
        }
    }

    @Test("Ein ungültiger Entwurf blockiert alle Felder vor dem Schreiben")
    func invalidBlocksSave() async {
        let item = entry()
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "-6 dB"
        item.lyricsLanguageDraft = "ungültig"
        let model = AppModel()
        let result = await model.save(entry: item) { _ in
            Issue.record("Ungültiger Entwurf erreicht den Schreibweg")
            return (.audio(TagData(properties: [], artworks: [], audio: nil)), nil)
        }
        #expect(!result)
        #expect(item.properties.isEmpty)
        #expect(item.isDirty)
        #expect(!item.isSaving)
        #expect(item.lastError != nil)
        item.revert()
        #expect(item.lyricsLanguageDraft == nil)
    }

    @Test("Ein reiner Entwurf wird über den echten Speicherweg geschrieben")
    func pendingOnlySave() async throws {
        let url = try MediaTestFixtures.workingCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (loaded, stamp) = try AppModel.readStamped(url: url, kind: .audio)
        let item = FileEntry(url: url, loaded: loaded, stamp: stamp)
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "-4 dB"
        #expect(await AppModel().save(entry: item))
        #expect(try TagFile.read(at: url).firstValue(for: FixedFields.replayGainAlbumGain) == "-4.00 dB")
        #expect(!item.isDirty)
    }

    @Test("Korrektur auf den Originalwert löscht den früheren Validierungsfehler")
    func correctedNoopClearsError() async {
        let item = entry("-6.00 dB")
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "falsch"
        #expect(item.beginSaving() == nil)
        #expect(item.lastError != nil)
        item.fixedFieldDrafts[FixedFields.replayGainAlbumGain] = "-6 dB"
        #expect(await AppModel().save(entry: item))
        #expect(item.lastError == nil)
        #expect(!item.isDirty)
    }
}

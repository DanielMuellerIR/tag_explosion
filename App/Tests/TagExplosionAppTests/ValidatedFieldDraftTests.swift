import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Geprüfte Feldeingabe")
struct ValidatedFieldDraftTests {
    @Test("Fokus allein schreibt nichts, auch bei gemischten leeren Anzeigewerten")
    func unchangedFocus() throws {
        var draft = ValidatedFieldDraft()
        draft.synchronize("")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == nil)
        draft.synchronize("-6.00 dB")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == nil)
    }

    @Test("Eingabe normalisiert einmal; bewusstes Leeren bleibt eine Änderung")
    func editingAndClearing() throws {
        var draft = ValidatedFieldDraft()
        draft.edit(" -6 dB ")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == "-6.00 dB")
        #expect(draft.text == "-6.00 dB")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == nil)
        draft.edit("")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == "")
    }

    @Test("Ungültiger Entwurf bleibt korrigierbar; Neuladen verwirft den Entwurf")
    func invalidThenReload() throws {
        var draft = ValidatedFieldDraft()
        draft.edit("falsch")
        #expect(throws: (any Error).self) { try draft.commit(key: FixedFields.replayGainAlbumGain) }
        #expect(draft.text == "falsch")
        draft.synchronize("-3.00 dB")
        #expect(try draft.commit(key: FixedFields.replayGainAlbumGain) == nil)
    }
}

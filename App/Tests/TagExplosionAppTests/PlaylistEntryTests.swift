// Playlist-Einträge im App-Modell: Dirty-Zustand über Kopf- und
// Eintragsfelder, Verwerfen, Save-Snapshot und Read-back — ohne Fenster.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("FileEntry Playlist", .serialized)
@MainActor
struct PlaylistEntryTests {

    private func makeContents(title: String = "Liste") -> PlaylistContents {
        let entries = [
            PlaylistEntry(number: 1, location: "a.mp3", title: "Eins"),
            PlaylistEntry(number: 2, location: "b.mp3", title: "Zwei"),
        ]
        return PlaylistContents(
            format: .m3u8,
            fields: PlaylistCoreFields(title: title, entries: entries.map(\.fields)),
            entries: entries)
    }

    @Test("Geänderte Kopf- und Eintragsfelder machen den Eintrag dirty; Verwerfen stellt zurück")
    func fieldsAffectDirtyState() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/liste.m3u8"),
                              loaded: .playlist(makeContents()), stamp: nil)
        #expect(entry.kind == .playlist)
        #expect(!entry.isDirty)
        #expect(entry.displayTitle == "Liste")
        #expect(!entry.supportsFilenamePatterns)

        entry.playlistFields.entries[1].title = "Zwei neu"
        #expect(entry.isDirty)
        entry.revert()
        #expect(!entry.isDirty)
        entry.playlistFields.title = "Anders"
        #expect(entry.isDirty)
        #expect(entry.displayTitle == "Anders")
    }

    @Test("Read-back nach dem Speichern wird zum neuen Original")
    func acceptSavedTakesReadBack() async {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/liste.m3u8"),
                              loaded: .playlist(makeContents()), stamp: nil)
        entry.playlistFields.title = "Gespeichert"
        guard case .playlist(let fields, let original)? = entry.beginSaving() else {
            Issue.record("Snapshot fehlt")
            return
        }
        #expect(fields.title == "Gespeichert")
        #expect(original.title == "Liste")
        entry.acceptSaved(.playlist(fields: fields, original: original),
                          reloaded: .playlist(makeContents(title: "Gespeichert")), stamp: nil)
        entry.finishSaving()
        #expect(!entry.isDirty)
        #expect(entry.playlistContents.fields.title == "Gespeichert")
    }
}

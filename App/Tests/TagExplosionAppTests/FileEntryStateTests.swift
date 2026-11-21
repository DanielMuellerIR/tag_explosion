import Foundation
import Observation
import Testing
import TagExplosionCore
@testable import TagExplosionApp

@Suite("Konsistenter FileEntry-Zustand")
@MainActor
struct FileEntryStateTests {
    @Test("Fremde Medienart ersetzt weder Puffer noch Plattenstempel")
    func mismatchedReloadKeepsState() {
        let stamp = FileStamp(size: 2, modified: 1)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/bild.jpg"),
                              loaded: .image(ImageCoreReading(fields: ImageCoreFields(title: "Alt"))),
                              stamp: stamp)
        entry.imageFields.title = "Bearbeitet"

        let audio = TagData(properties: [TagProperty(key: "TITLE", value: "Fremd")], artworks: [], audio: nil)
        entry.acceptNew(.audio(audio), stamp: FileStamp(size: 3, modified: 2))

        #expect(entry.diskStamp == stamp)
        #expect(entry.imageOriginal.title == "Alt")
        #expect(entry.imageFields.title == "Bearbeitet")
        #expect(entry.properties.isEmpty)
        #expect(entry.isDirty)
    }

    @Test("Eine SRT-Datei behält ihren Zustand und liefert eine Momentaufnahme für direkte Aktionen")
    func disabledEditorSnapshot() {
        let stamp = FileStamp(size: 2, modified: 1)
        let info = SubtitleInfo(format: .srt, cueCount: 0, firstStartMilliseconds: nil,
                                lastEndMilliseconds: nil, spanMilliseconds: 0, encoding: "UTF-8",
                                lineEndings: "LF", languageFromName: "de", flagsFromName: [], header: nil)
        let subtitle = SubtitleContents(info: info, fields: SubtitleEditableFields())
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/film.de.srt"),
                              loaded: .sidecar(.subtitle(subtitle)), stamp: stamp)
        let foreign = NFOContents(rootName: "movie", fields: NFOFields(title: "Fremd"), info: [], urls: [])
        let foreignStamp = FileStamp(size: 3, modified: 2)

        entry.nfoFields.title = "Fremd"
        entry.acceptNew(.sidecar(.nfo(foreign)), stamp: foreignStamp)
        #expect(entry.diskStamp == stamp)
        #expect(!entry.isDirty)
        #expect(entry.beginSaving() == nil)
        guard case .sidecar(.subtitle, .subtitle)? = entry.beginSaving(allowingUnchanged: true) else {
            Issue.record("Unveränderter Untertitel benötigt eine Momentaufnahme")
            return
        }
        defer { entry.finishSaving() }

        entry.acceptSaved(.sidecar(fields: .nfo(foreign.fields), original: .nfo(NFOFields())),
                          reloaded: .sidecar(.nfo(foreign)), stamp: foreignStamp)

        #expect(entry.diskStamp == stamp)
        #expect(entry.nfoFields.title.isEmpty)
        #expect(entry.displaySubtitle == "de · 0 cues")
        #expect(!entry.isDirty)
    }

    @Test("Eine Änderung über das verschachtelte Binding meldet sich bei Observation")
    func nestedBindingIsObservable() async {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/bild.jpg"),
                              loaded: .image(ImageCoreReading(fields: ImageCoreFields())), stamp: nil)
        await confirmation("Änderung des Bildtitels") { changed in
            let initial = withObservationTracking { entry.imageFields.title } onChange: { changed() }
            #expect(initial.isEmpty)
            let binding: ReferenceWritableKeyPath<FileEntry, ImageCoreFields> = \.imageFields
            entry[keyPath: binding].title = "Bearbeitet"
        }
        #expect(entry.displayTitle == "Bearbeitet")
        #expect(entry.isDirty)
    }
}

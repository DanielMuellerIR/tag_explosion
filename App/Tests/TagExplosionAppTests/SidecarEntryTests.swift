// Sidecar-Einträge ohne Fenster: Dirty-Zustand, Verwerfen, Save-Snapshot
// und Übernahme des Read-backs für NFO und VTT, dazu die Musterfelder für
// das Umbenennen eines Untertitels.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("Sidecar-Einträge", .serialized)
@MainActor
struct SidecarEntryTests {

    private func nfoContents(title: String) -> NFOContents {
        NFOContents(rootName: "movie", fields: NFOFields(title: title, year: "2019"),
                    info: [DocumentInfoItem(label: "type", value: "movie")], urls: [])
    }

    @Test("NFO: dirty, revert, Snapshot und acceptSaved")
    func nfoEntryLifecycle() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/film.nfo"),
                              loaded: .sidecar(.nfo(nfoContents(title: "Alt"))), stamp: nil)
        #expect(entry.kind == .sidecar)
        #expect(!entry.isDirty)
        #expect(entry.displayTitle == "Alt")
        #expect(entry.displaySubtitle == "movie · 2019")

        entry.nfoFields.title = "Neu"
        #expect(entry.isDirty)
        entry.revert()
        #expect(!entry.isDirty)
        #expect(entry.nfoFields.title == "Alt")

        entry.nfoFields.genres = ["Drama"]
        guard let snapshot = entry.beginSaving() else {
            Issue.record("Snapshot fehlt")
            return
        }
        guard case .sidecar(.nfo(let fields), .nfo(let original)) = snapshot else {
            Issue.record("Falscher Snapshot-Typ")
            return
        }
        #expect(fields.genres == ["Drama"])
        #expect(original.genres.isEmpty)
        // Während des Schreibens weitergetippt: bleibt gegenüber dem neuen
        // Original dirty.
        entry.nfoFields.title = "Weiter"
        var saved = nfoContents(title: "Alt")
        saved = NFOContents(rootName: "movie",
                            fields: NFOFields(title: "Alt", year: "2019", genres: ["Drama"]),
                            info: saved.info, urls: [])
        entry.acceptSaved(snapshot, reloaded: .sidecar(.nfo(saved)), stamp: nil)
        entry.finishSaving()
        #expect(entry.nfoFields.title == "Weiter")
        #expect(entry.nfoFields.genres == ["Drama"])
        #expect(entry.isDirty)
        #expect(entry.patternFields["TITLE"] == "Weiter")
        #expect(entry.patternFields["DATE"] == "2019")
    }

    @Test("VTT: Kopffelder dirty, SRT liefert Musterfelder für %{base}.%{lang}")
    func subtitleEntry() throws {
        let info = SubtitleInfo(format: .vtt, cueCount: 3, firstStartMilliseconds: 0,
                                lastEndMilliseconds: 5000, spanMilliseconds: 5000,
                                encoding: "UTF-8", lineEndings: "LF",
                                languageFromName: "en", flagsFromName: ["forced"],
                                header: SubtitleHeader(title: "T", lines: ["Language: en"], notes: []))
        let contents = SubtitleContents(info: info, fields: SubtitleEditableFields(title: "T", language: "en"))
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/film.en.forced.vtt"),
                              loaded: .sidecar(.subtitle(contents)), stamp: nil)
        #expect(entry.displayTitle == "T")
        #expect(entry.displaySubtitle == "en · 3 cues")
        #expect(!entry.isDirty)
        entry.subtitleFields.language = "de"
        entry.subtitleFields.title = "Bearbeitet"
        #expect(entry.isDirty)
        let fields = entry.patternFields
        #expect(fields["TITLE"] == "Bearbeitet")
        #expect(fields["BASE"] == "film")
        #expect(fields["LANG"] == "en")
        #expect(fields["FLAGS"] == "forced")
        #expect(try FilenamePattern("%{base}.de.%{flags}").renderStem(fields: fields) == "film.de.forced")
        // Untertitel nehmen keine Werte aus dem Dateinamen an.
        #expect(throws: PatternFields.ApplyError.self) {
            try entry.applyParsedFields(["TITLE": "x"])
        }
    }


    @Test("Video mit NFO daneben: NFO-Puffer liegt im Eintrag, zählt zu isDirty, Snapshot und acceptSaved")
    func videoNFOLivesInEntry() {
        let nfoURL = URL(fileURLWithPath: "/tmp/film.nfo")
        let reading = NFOSidecarReading(url: nfoURL, contents: nfoContents(title: "Alt"), stamp: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/film.mkv"),
                              loaded: .audio(TagData(properties: [], artworks: [], audio: nil),
                                             sidecars: AudioSidecars(nfo: reading)),
                              stamp: nil)
        #expect(entry.kind == .audio)
        #expect(entry.videoNFO?.isEditable == true)
        #expect(!entry.isDirty)

        // Der Schließ-/Beenden-Guard sieht die NFO-Änderung über isDirty.
        entry.videoNFOFields.title = "Neu"
        #expect(entry.isDirty)
        entry.revert()
        #expect(!entry.isDirty && entry.videoNFOFields.title == "Alt")

        entry.videoNFOFields.title = "Neu"
        guard case .audio(let snapshot)? = entry.beginSaving() else {
            Issue.record("Snapshot fehlt")
            return
        }
        #expect(!snapshot.mediaChanged)          // nur die NFO wird geschrieben
        #expect(snapshot.nfo?.fields.title == "Neu")
        #expect(snapshot.nfo?.original.title == "Alt")
        #expect(snapshot.nfo?.url == nfoURL)

        // Weitertippen während des Schreibens bleibt dirty gegenüber dem Read-back.
        entry.videoNFOFields.plot = "Getippt"
        let saved = NFOSidecarReading(url: nfoURL, contents: nfoContents(title: "Neu"), stamp: nil)
        entry.acceptSaved(.audio(snapshot),
                          reloaded: .audio(TagData(properties: [], artworks: [], audio: nil),
                                           sidecars: AudioSidecars(nfo: saved)),
                          stamp: nil)
        entry.finishSaving()
        #expect(entry.videoNFOFields.title == "Neu")
        #expect(entry.videoNFOFields.plot == "Getippt")
        #expect(entry.isDirty)
        entry.revert()
        #expect(!entry.isDirty)
    }
}

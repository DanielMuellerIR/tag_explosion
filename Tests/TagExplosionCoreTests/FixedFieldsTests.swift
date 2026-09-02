// Feste Felder (AP7): Lyrics mit Sprache und SYLT, ReplayGain/R128 mit
// Wertebereichsprüfung, Podcast-Felder — Roundtrip je Format, Ablehnung
// ungültiger Werte ohne Dateiänderung, LRC-Parser-Grenzfälle und Sidecar.
import Foundation
import Testing
@testable import TagExplosionCore

/// Formate, die Lyrics und ReplayGain über freie Schlüssel speichern.
let fixedFieldFormats = ["sample.mp3", "sample.m4a", "sample.flac", "sample.opus", "sample.ogg"]

/// Pfad eines Werkzeugs (Homebrew oder System) oder nil.
private func tool(_ candidates: [String]) -> String? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private let ffmpegPath = tool(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"])
private let kid3Path = tool(["/Applications/kid3.app/Contents/MacOS/kid3-cli",
                             "/opt/homebrew/bin/kid3-cli", "/usr/bin/kid3-cli"])

/// Startet ein Werkzeug und liefert stdout (nil bei Fehler).
private func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}

@Suite("Feste Felder", .serialized)
struct FixedFieldsTests {

    // MARK: - Lyrics

    @Test("Lyrics mehrzeilig schreiben und lesen", arguments: fixedFieldFormats)
    func lyricsRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let text = "Erste Zeile\nZweite Zeile — Ümläute\n\nVierte Zeile"
        let before = try TagFile.read(at: url)
        try TagFile.write(properties: FixedFields.settingLyrics(text, in: before.properties), to: url)
        let after = try TagFile.read(at: url)
        #expect(FixedFields.lyricsText(in: after.properties) == text, Comment(rawValue: format))
        // Entfernen
        try TagFile.write(properties: FixedFields.settingLyrics("", in: after.properties), to: url)
        #expect(FixedFields.lyricsText(in: try TagFile.read(at: url).properties).isEmpty, Comment(rawValue: format))
    }

    @Test("Vorhandenes UNSYNCEDLYRICS wird weiter benutzt, nicht verdoppelt")
    func lyricsAlternateKeyIsKept() throws {
        let url = try Fixtures.workingCopy("sample.flac")
        try TagFile.write(properties: [TagProperty(key: "UNSYNCEDLYRICS", value: "alt")], to: url)
        let props = try TagFile.read(at: url).properties
        #expect(FixedFields.lyricsKey(in: props) == "UNSYNCEDLYRICS")
        try TagFile.write(properties: FixedFields.settingLyrics("neu", in: props), to: url)
        let after = try TagFile.read(at: url)
        #expect(after.values(for: "UNSYNCEDLYRICS") == ["neu"])
        #expect(after.values(for: "LYRICS").isEmpty)
    }

    @Test("Lyrics-Sprache: nur ID3v2 speichert sie, sie überlebt Textänderungen")
    func lyricsLanguage() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let initial = try TagFile.read(at: url)
        #expect(initial.supportsSyncedLyrics)
        #expect(initial.lyricsLanguage.isEmpty)
        try TagFile.write(properties: [TagProperty(key: "LYRICS", value: "Text")], lyricsLanguage: "deu", to: url)
        #expect(try TagFile.read(at: url).lyricsLanguage == "deu")
        // Neuer Text ohne Sprachangabe: TagLib legt ein neues USLT an —
        // die bisherige Sprache muss bleiben.
        try TagFile.write(properties: [TagProperty(key: "LYRICS", value: "Anderer Text")], to: url)
        let after = try TagFile.read(at: url)
        #expect(after.lyricsLanguage == "deu")
        #expect(after.firstValue(for: "LYRICS") == "Anderer Text")
        // Ungültige Sprache: Ablehnung, Datei unverändert.
        let bytes = try Data(contentsOf: url)
        #expect(throws: TagError.self) {
            try TagFile.write(lyricsLanguage: "de", to: url)
        }
        #expect(try Data(contentsOf: url) == bytes)

        // Formate ohne ID3v2 kennen keine Sprache und kein SYLT.
        let flac = try Fixtures.workingCopy("sample.flac")
        let data = try TagFile.read(at: flac)
        #expect(!data.supportsSyncedLyrics)
        #expect(data.lyricsLanguage.isEmpty)
        #expect(throws: TagError.syncedLyricsUnsupported(path: flac.path)) {
            try TagFile.write(syncedLyrics: [SyncedLyricLine(milliseconds: 0, text: "x")], to: flac)
        }
    }

    static let syncedSample = [
        SyncedLyricLine(milliseconds: 0, text: "Intro"),
        SyncedLyricLine(milliseconds: 1250, text: "Zeile mit Ümläuten"),
        SyncedLyricLine(milliseconds: 1900, text: ""),
    ]

    @Test("SYLT schreiben, lesen, entfernen; überlebt Tag-Schreiben", arguments: ["sample.mp3", "sample.wav", "sample.aiff"])
    func syncedLyricsRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(syncedLyrics: Self.syncedSample, lyricsLanguage: "eng", to: url)
        let read = try TagFile.read(at: url)
        #expect(read.syncedLyrics == Self.syncedSample, Comment(rawValue: format))
        // Andere Felder schreiben lässt SYLT stehen.
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Neu")], to: url)
        #expect(try TagFile.read(at: url).syncedLyrics == Self.syncedSample, Comment(rawValue: format))
        try TagFile.write(syncedLyrics: [], to: url)
        #expect(try TagFile.read(at: url).syncedLyrics.isEmpty, Comment(rawValue: format))
    }

    @Test("kid3 sieht unseren SYLT-Frame", .enabled(if: kid3Path != nil, "kid3-cli fehlt"))
    func kid3SeesSyncedLyricsFrame() throws {
        // kid3-cli gibt die Zeilen eines SYLT-Frames nicht aus (nur die
        // Beschreibung); es zeigt aber, dass der Frame als „Synchronized
        // Lyrics" erkannt wird — mehr Fremdprüfung gibt es für SYLT nicht.
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(syncedLyrics: Self.syncedSample, lyricsLanguage: "deu", to: url)
        let output = try #require(run(kid3Path!, ["-c", "get", url.path]))
        #expect(output.contains("Synchronized Lyrics"), Comment(rawValue: output))
    }

    // MARK: - Lautheit

    @Test("ReplayGain schreiben und lesen", arguments: fixedFieldFormats)
    func replayGainRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let values = [
            TagProperty(key: "REPLAYGAIN_TRACK_GAIN", value: "-6.50 dB"),
            TagProperty(key: "REPLAYGAIN_TRACK_PEAK", value: "0.987654"),
            TagProperty(key: "REPLAYGAIN_ALBUM_GAIN", value: "+1.25 dB"),
            TagProperty(key: "REPLAYGAIN_ALBUM_PEAK", value: "1.000000"),
        ]
        try TagFile.write(properties: values, to: url)
        let after = try TagFile.read(at: url)
        for value in values {
            #expect(after.firstValue(for: value.key) == value.value, Comment(rawValue: "\(format) \(value.key)"))
        }
    }

    @Test("kid3 liest unser ReplayGain", .enabled(if: kid3Path != nil, "kid3-cli fehlt"),
          arguments: ["sample.mp3", "sample.m4a", "sample.flac"])
    func kid3ReadsReplayGain(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(properties: [TagProperty(key: "REPLAYGAIN_TRACK_GAIN", value: "-6.50 dB")], to: url)
        let output = try #require(run(kid3Path!, ["-c", "get", url.path]))
        #expect(output.lowercased().contains("replaygain_track_gain"), Comment(rawValue: output))
        #expect(output.contains("-6.50 dB"), Comment(rawValue: output))
    }

    @Test("R128 nur als Q7.8-Ganzzahl im Bereich; Opus-Roundtrip")
    func r128() throws {
        let url = try Fixtures.workingCopy("sample.opus")
        try TagFile.write(properties: [TagProperty(key: "R128_TRACK_GAIN", value: "-1664"),
                                       TagProperty(key: "R128_ALBUM_GAIN", value: "512")], to: url)
        let after = try TagFile.read(at: url)
        #expect(after.firstValue(for: "R128_TRACK_GAIN") == "-1664")
        #expect(Loudness.r128ToDecibel(-1664) == -6.5)
        #expect(Loudness.decibelToR128(2) == 512)
        let bytes = try Data(contentsOf: url)
        for bad in ["40000", "-6.5 dB", "abc"] {
            #expect(throws: TagError.self, Comment(rawValue: bad)) {
                try TagFile.write(properties: [TagProperty(key: "R128_TRACK_GAIN", value: bad)], to: url)
            }
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Ungültige Lautheitswerte werden mit Feldname abgelehnt, Datei bleibt byteweise gleich",
          arguments: fixedFieldFormats)
    func invalidLoudnessIsRejected(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let before = try Data(contentsOf: url)
        let stamp = FileStamp.current(of: url)
        let cases: [(String, String)] = [
            ("REPLAYGAIN_TRACK_GAIN", "-61 dB"), ("REPLAYGAIN_TRACK_GAIN", "laut"),
            ("REPLAYGAIN_ALBUM_GAIN", "+60.01 dB"), ("REPLAYGAIN_TRACK_PEAK", "11"),
            ("REPLAYGAIN_ALBUM_PEAK", "-0.1"), ("REPLAYGAIN_ALBUM_PEAK", "0,9 dB"),
        ]
        for (key, value) in cases {
            do {
                try TagFile.write(properties: [TagProperty(key: key, value: value)], to: url)
                Issue.record("\(format): \(key)=\(value) wurde angenommen")
            } catch TagError.invalidFieldValue(let field, _) {
                #expect(field == key)
            }
        }
        #expect(try Data(contentsOf: url) == before, Comment(rawValue: format))
        #expect(FileStamp.current(of: url) == stamp, Comment(rawValue: format))
    }

    @Test("Altwerte fremder Programme blockieren keine unabhängige Änderung",
          .enabled(if: ffmpegPath != nil, "ffmpeg fehlt"))
    func preexistingInvalidValueDoesNotBlockOtherEdits() throws {
        let source = try Fixtures.workingCopy("sample.mp3")
        let url = source.deletingLastPathComponent().appendingPathComponent("kaputt.mp3")
        // ffmpeg schreibt den Unsinn als TXXX, an unserer Prüfung vorbei.
        _ = try #require(run(ffmpegPath!, ["-nostdin", "-v", "error", "-y", "-i", source.path, "-c", "copy",
                                          "-metadata", "REPLAYGAIN_TRACK_GAIN=kaputt", url.path]))
        let before = try TagFile.read(at: url)
        #expect(before.firstValue(for: "REPLAYGAIN_TRACK_GAIN") == "kaputt")
        var properties = before.properties
        properties.append(TagProperty(key: "TITLE", value: "Trotzdem"))
        try TagFile.write(properties: properties, to: url)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == "Trotzdem")
        // Wird der kaputte Wert selbst angefasst, greift die Prüfung.
        #expect(throws: TagError.self) {
            try TagFile.write(properties: [TagProperty(key: "REPLAYGAIN_TRACK_GAIN", value: "noch kaputter")], to: url)
        }
    }

    @Test("Lautheits-Helfer: Parsen, Formatieren, Normalisieren")
    func loudnessHelpers() throws {
        #expect(Loudness.parseGain("-6.50 dB") == -6.5)
        #expect(Loudness.parseGain("+1,25dB") == 1.25)
        #expect(Loudness.parseGain("3") == 3)
        #expect(Loudness.parseGain("dB") == nil)
        #expect(Loudness.parseGain("1e3") == nil)
        #expect(Loudness.formatGain(-6.5) == "-6.50 dB")
        #expect(Loudness.formatPeak(0.5) == "0.500000")
        #expect(try FixedFields.normalized(key: "REPLAYGAIN_TRACK_GAIN", value: "-6,5") == "-6.50 dB")
        #expect(try FixedFields.normalized(key: "REPLAYGAIN_TRACK_PEAK", value: "1") == "1.000000")
        #expect(try FixedFields.normalized(key: "R128_TRACK_GAIN", value: "+512") == "512")
        #expect(try FixedFields.normalized(key: "TVSEASON", value: " 03 ") == "3")
        #expect(try FixedFields.normalized(key: "PODCAST", value: "yes") == "1")
        #expect(try FixedFields.normalized(key: "PODCAST", value: "0") == "")
        #expect(throws: TagError.self) { try FixedFields.normalized(key: "PODCAST", value: "vielleicht") }
        #expect(throws: TagError.self) { try FixedFields.normalized(key: "TVEPISODE", value: "-1") }
        #expect(throws: TagError.self) { try FixedFields.normalized(key: "PODCASTURL", value: "example.org/feed") }
        // Unveränderte Werte werden nicht geprüft.
        let old = [TagProperty(key: "REPLAYGAIN_TRACK_GAIN", value: "kaputt")]
        try FixedFields.validate(old, changedFrom: old)
        #expect(throws: TagError.self) { try FixedFields.validate(old, changedFrom: []) }
    }

    // MARK: - Podcast

    static let podcastSample = [
        TagProperty(key: "PODCAST", value: "1"),
        TagProperty(key: "PODCASTURL", value: "https://example.org/feed.xml"),
        TagProperty(key: "PODCASTID", value: "urn:uuid:1234"),
        TagProperty(key: "PODCASTCATEGORY", value: "Technik"),
        TagProperty(key: "KEYWORDS", value: "swift, taglib"),
        TagProperty(key: "TVSEASON", value: "2"),
        TagProperty(key: "TVEPISODE", value: "7"),
        TagProperty(key: "PODCASTDESC", value: "Kurz"),
        TagProperty(key: "LONGDESCRIPTION", value: "Lang — mit Ümläuten"),
    ]

    @Test("Podcast-Felder schreiben, lesen und entfernen", arguments: ["sample.mp3", "sample.m4a", "sample.m4b"])
    func podcastRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(properties: Self.podcastSample, to: url)
        let after = try TagFile.read(at: url)
        for value in Self.podcastSample {
            #expect(after.firstValue(for: value.key) == value.value, Comment(rawValue: "\(format) \(value.key)"))
        }
        // Keine Doppelungen (nativer Wert verdrängt den PropertyMap-Wert).
        #expect(after.values(for: "PODCAST").count == 1, Comment(rawValue: format))
        #expect(after.values(for: "KEYWORDS").count == 1, Comment(rawValue: format))

        // Unabhängige Änderung lässt die Felder stehen (TKWD/TVSN/PCST sind
        // für TagLibs PropertyMap unbekannt).
        var props = after.properties
        props.append(TagProperty(key: "TITLE", value: "Folge 7"))
        try TagFile.write(properties: props, to: url)
        let kept = try TagFile.read(at: url)
        for value in Self.podcastSample {
            #expect(kept.firstValue(for: value.key) == value.value, Comment(rawValue: "\(format) \(value.key) nach Titel"))
        }

        // Entfernen: alle Podcast-Schlüssel weg.
        try TagFile.write(properties: kept.properties.filter { !FixedFields.podcastKeys.contains($0.key) }, to: url)
        let cleared = try TagFile.read(at: url)
        for key in FixedFields.podcastKeys {
            #expect(cleared.firstValue(for: key) == nil, Comment(rawValue: "\(format) \(key)"))
        }
    }

    @Test("Ungültige Podcast-Werte werden abgelehnt, Datei bleibt gleich")
    func invalidPodcastValues() throws {
        let url = try Fixtures.workingCopy("sample.m4a")
        let before = try Data(contentsOf: url)
        for (key, value) in [("TVSEASON", "zwei"), ("TVEPISODE", "1.5"), ("PODCAST", "maybe"),
                             ("PODCASTURL", "kein schema")] {
            do {
                try TagFile.write(properties: [TagProperty(key: key, value: value)], to: url)
                Issue.record("\(key)=\(value) wurde angenommen")
            } catch TagError.invalidFieldValue(let field, _) {
                #expect(field == key)
            }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Format-Fähigkeiten")
    func capabilities() {
        #expect(FixedFields.supportsPodcast(URL(fileURLWithPath: "a.mp3")))
        #expect(FixedFields.supportsPodcast(URL(fileURLWithPath: "a.m4b")))
        #expect(!FixedFields.supportsPodcast(URL(fileURLWithPath: "a.flac")))
        #expect(FixedFields.supportsR128(URL(fileURLWithPath: "a.opus")))
        #expect(!FixedFields.supportsR128(URL(fileURLWithPath: "a.mp3")))
        #expect(FixedFields.supportsLyrics(URL(fileURLWithPath: "a.ogg")))
        #expect(!FixedFields.supportsLyrics(URL(fileURLWithPath: "a.mod")))
        #expect(!FixedFields.supportsLoudness(URL(fileURLWithPath: "a.au")))
    }

    // MARK: - LRC

    @Test("LRC: mehrere Zeitstempel je Zeile, Metadaten, Wortmarken, Sortierung")
    func lrcParsing() throws {
        let text = """
        [ar:Interpret]
        [ti:Titel]
        [offset:+500]
        # Kommentar ohne Klammer

        [00:12.00][01:02.50]Refrain
        [00:01.25]Erste <00:01.30>Zeile <00:01.90>mit Wortmarken
        [00:05]Ohne Hundertstel
        [00:07.123]Mit Millisekunden
        [1:00:00.00]Nach einer Stunde
        Zeile ohne Zeit wird übersprungen
        """
        let doc = try LRC.parse(text)
        #expect(doc.metadata.map(\.key) == ["ar", "ti", "offset"])
        #expect(doc.metadata.map(\.value) == ["Interpret", "Titel", "+500"])
        #expect(doc.lines == [
            SyncedLyricLine(milliseconds: 1250, text: "Erste Zeile mit Wortmarken"),
            SyncedLyricLine(milliseconds: 5000, text: "Ohne Hundertstel"),
            SyncedLyricLine(milliseconds: 7123, text: "Mit Millisekunden"),
            SyncedLyricLine(milliseconds: 12000, text: "Refrain"),
            SyncedLyricLine(milliseconds: 62500, text: "Refrain"),
            SyncedLyricLine(milliseconds: 3_600_000, text: "Nach einer Stunde"),
        ])
        #expect(throws: TagError.self) { try LRC.parse("nur Text\n[ar:x]\n") }
        #expect(LRC.plainText(doc.lines).hasPrefix("Erste Zeile mit Wortmarken\nOhne Hundertstel"))
    }

    @Test("LRC: Rendern und Wiedereinlesen ist verlustfrei (auf Hundertstel)")
    func lrcRender() throws {
        let lines = [SyncedLyricLine(milliseconds: 0, text: "A"),
                     SyncedLyricLine(milliseconds: 61_250, text: "B — Ümläute"),
                     SyncedLyricLine(milliseconds: 3_600_000, text: "")]
        let rendered = LRC.render(lines, metadata: [(key: "ti", value: "Titel")])
        #expect(rendered == "[ti:Titel]\n[00:00.00]A\n[01:01.25]B — Ümläute\n[60:00.00]\n")
        #expect(try LRC.parse(rendered).lines == lines)
        #expect(LRC.render([]) == "")
    }

    @Test("Sidecar <name>.lrc neben der Datei: anlegen, lesen, ersetzen, löschen")
    func sidecar() throws {
        let media = try Fixtures.workingCopy("sample.flac")
        let sidecar = LRC.sidecarURL(for: media)
        #expect(sidecar.lastPathComponent == "sample.lrc")
        #expect(try LRC.loadSidecar(for: media) == nil)
        let lines = [SyncedLyricLine(milliseconds: 1000, text: "Eins"), SyncedLyricLine(milliseconds: 2000, text: "Zwei")]
        try LRC.writeSidecar(lines, for: media)
        #expect(try LRC.loadSidecar(for: media) == lines)
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "[00:01.00]Eins\n[00:02.00]Zwei\n")
        try LRC.writeSidecar([SyncedLyricLine(milliseconds: 0, text: "Neu")], for: media)
        #expect(try LRC.loadSidecar(for: media)?.map(\.text) == ["Neu"])
        try LRC.writeSidecar([], for: media)
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
        #expect(throws: TagError.self) {
            try LRC.writeSidecar([SyncedLyricLine(milliseconds: -1, text: "x")], for: media)
        }
    }
}

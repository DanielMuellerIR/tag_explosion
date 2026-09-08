// Playlists und Cue-Sheets: Parser/Writer-Roundtrips mit Erhalt fremder
// Zeilen und Zeilenenden, Encoding-Fallback, Pfadauflösung (relativ,
// absolut, fehlend, Netz), Export-Roundtrip (exportieren → wieder lesen)
// und `cue apply` gegen die ffmpeg-Fixtures.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("PlaylistTool")
struct PlaylistTests {

    /// Frisches Temp-Verzeichnis mit einer Textdatei darin.
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-playlist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func text(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Ein Cue-Sheet mit CRLF, Kommentar-REMs, PREGAP und FLAGS — alles, was
    /// beim Schreiben unangetastet bleiben muss.
    private let cueText = """
    REM GENRE Rock\r
    REM DATE 1999\r
    REM COMMENT "ExactAudioCopy v1.0"\r
    CATALOG 0000000000000\r
    PERFORMER "Die Band"\r
    TITLE "Das Album"\r
    FILE "album.wav" WAVE\r
      TRACK 01 AUDIO\r
        TITLE "Erstes Lied"\r
        FLAGS DCP\r
        INDEX 01 00:00:00\r
      TRACK 02 AUDIO\r
        TITLE "Zweites Lied"\r
        PERFORMER "Gast"\r
        ISRC DEABC9900002\r
        PREGAP 00:02:00\r
        INDEX 00 01:29:70\r
        INDEX 01 01:30:00\r

    """

    // MARK: - Cue

    @Test("cue: Kopf, Tracks, INDEX-Zeiten und Info-Zeilen lesen")
    func cueRead() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("album.cue")
        try write(cueText, to: url)

        let contents = try PlaylistTool.read(url: url)
        #expect(contents.format == .cue)
        #expect(contents.fields.title == "Das Album")
        #expect(contents.fields.performer == "Die Band")
        #expect(contents.fields.date == "1999")
        #expect(contents.fields.genre == "Rock")
        #expect(contents.entries.count == 2)
        #expect(contents.entries[0].number == 1)
        #expect(contents.entries[0].title == "Erstes Lied")
        #expect(contents.entries[0].performer == "")
        #expect(contents.entries[0].startMilliseconds == 0)
        // Track 1 endet, wo Track 2 beginnt: 1:30 = 90 000 ms.
        #expect(contents.entries[0].durationMilliseconds == 90_000)
        #expect(contents.entries[1].performer == "Gast")
        #expect(contents.entries[1].isrc == "DEABC9900002")
        // Die Audiodatei fehlt: Pfad aufgelöst, exists false, letzte Dauer unbekannt.
        #expect(contents.entries[1].resolvedPath?.hasSuffix("/album.wav") == true)
        #expect(!contents.entries[1].exists)
        #expect(contents.entries[1].durationMilliseconds == nil)
        #expect(contents.missingCount == 2)
        #expect(contents.unknownDurationCount == 1)
        #expect(contents.info.contains(DocumentInfoItem(label: "REM COMMENT", value: "ExactAudioCopy v1.0")))
        #expect(contents.info.contains(DocumentInfoItem(label: "CATALOG", value: "0000000000000")))
        #expect(!contents.usedEncodingFallback)
        #expect(PlaylistTool.supportedFields(url: url) == Set(PlaylistField.allCases))
    }

    @Test("CUE-Dauern finden den nächsten Track auch zwischen anderen Dateien")
    func cueInterleavedDurations() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("interleaved.cue")
        try write("""
        FILE "a.flac" WAVE
        TRACK 01 AUDIO
        INDEX 01 00:00:00
        FILE "b.flac" WAVE
        TRACK 02 AUDIO
        INDEX 01 00:10:00
        FILE "a.flac" WAVE
        TRACK 03 AUDIO
        INDEX 01 00:01:00
        FILE "b.flac" WAVE
        TRACK 04 AUDIO
        INDEX 01 00:12:00
        """, to: url)
        #expect(try PlaylistTool.read(url: url).entries.map(\.durationMilliseconds) == [1000, 2000, nil, nil])
    }

    @Test("cue: Roundtrip ändert nur Metadatenzeilen; CRLF, Einrückung und fremde Zeilen bleiben")
    func cueRoundtripPreservesRest() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("album.cue")
        try write(cueText, to: url)

        let original = try PlaylistTool.read(url: url).fields
        var edited = original
        edited.title = "Neuer Titel"
        edited.performer = "Neue Band"
        edited.genre = "Prog Rock"     // bekommt Anführungszeichen (Leerzeichen)
        edited.date = ""               // Zeile entfernen
        edited.entries[0].performer = "Solo"  // neue Zeile hinter TITLE, eingerückt
        edited.entries[1].title = "Zweites Lied (Remaster)"
        edited.entries[1].performer = ""      // Zeile entfernen
        try PlaylistTool.write(url: url, fields: edited, original: original)

        let readBack = try PlaylistTool.read(url: url)
        #expect(readBack.fields == edited)
        let result = try text(of: url)
        let expected = """
        REM GENRE "Prog Rock"\r
        REM COMMENT "ExactAudioCopy v1.0"\r
        CATALOG 0000000000000\r
        PERFORMER "Neue Band"\r
        TITLE "Neuer Titel"\r
        FILE "album.wav" WAVE\r
          TRACK 01 AUDIO\r
            TITLE "Erstes Lied"\r
            PERFORMER "Solo"\r
            FLAGS DCP\r
            INDEX 01 00:00:00\r
          TRACK 02 AUDIO\r
            TITLE "Zweites Lied (Remaster)"\r
            ISRC DEABC9900002\r
            PREGAP 00:02:00\r
            INDEX 00 01:29:70\r
            INDEX 01 01:30:00\r

        """
        #expect(result == expected)
    }

    /// Die Einrückung neuer Trackzeilen folgt den vorhandenen Feldzeilen des
    /// Tracks (hier: keine), nicht einer festen Vorgabe.
    @Test("cue: fehlende Kopfzeilen entstehen an der richtigen Stelle, Datei ohne Zeilenende am Schluss")
    func cueInsertsMissingLines() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("min.cue")
        try write("FILE \"a.wav\" WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00", to: url)

        let original = try PlaylistTool.read(url: url).fields
        var edited = original
        edited.title = "T"
        edited.performer = "P"
        edited.date = "2001"
        edited.entries[0].title = "Lied"
        try PlaylistTool.write(url: url, fields: edited, original: original)
        #expect(try text(of: url) == """
        REM DATE 2001
        PERFORMER "P"
        TITLE "T"
        FILE "a.wav" WAVE
        TRACK 01 AUDIO
        TITLE "Lied"
        INDEX 01 00:00:00
        """)
        #expect(try PlaylistTool.read(url: url).fields == edited)
    }

    @Test("cue: Anführungszeichen und Eintragszahl werden vor jeder Mutation abgelehnt")
    func cueRejectsInvalidValues() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("album.cue")
        try write(cueText, to: url)
        let original = try PlaylistTool.read(url: url).fields
        let before = try Data(contentsOf: url)

        var quoted = original
        quoted.title = "Sag \"Hallo\""
        #expect(throws: TagError.invalidDocumentValue(field: "title", reason: "cue values cannot contain '\"'")) {
            try PlaylistTool.write(url: url, fields: quoted, original: original)
        }
        var fewer = original
        fewer.entries.removeLast()
        #expect(throws: TagError.self) {
            try PlaylistTool.write(url: url, fields: fewer, original: original)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("cue: Latin1-Datei wird per Fallback gelesen und als UTF-8 zurückgeschrieben")
    func cueEncodingFallback() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("latin.cue")
        // "Größe" in Latin1: ö = 0xF6, ß = 0xDF — kein gültiges UTF-8.
        var bytes = Data("PERFORMER \"Gr".utf8)
        bytes.append(contentsOf: [0xF6, 0xDF])
        bytes.append(Data("e\"\nTITLE \"Album\"\nFILE \"a.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n".utf8))
        try bytes.write(to: url)

        let contents = try PlaylistTool.read(url: url)
        #expect(contents.usedEncodingFallback)
        #expect(contents.fields.performer == "Größe")

        var edited = contents.fields
        edited.title = "Ändern"
        try PlaylistTool.write(url: url, fields: edited, original: contents.fields)
        let readBack = try PlaylistTool.read(url: url)
        #expect(!readBack.usedEncodingFallback)
        #expect(readBack.fields.performer == "Größe")
        #expect(readBack.fields.title == "Ändern")
    }

    // MARK: - M3U

    @Test("m3u8: relative, absolute, fehlende und entfernte Einträge auflösen")
    func m3uResolvesPaths() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let present = sub.appendingPathComponent("01 - Lied.mp3")
        try Data([0]).write(to: present)
        let absolute = dir.appendingPathComponent("abs.flac")
        try Data([0]).write(to: absolute)
        let url = dir.appendingPathComponent("list.m3u8")
        try write("""
        #EXTM3U
        #PLAYLIST:Meine Liste
        # ein Kommentar
        #EXTINF:181,Die Band - Lied
        Album/01 - Lied.mp3
        #EXTINF:-1,Absolut
        \(absolute.path)
        Album\\fehlt.mp3
        https://example.org/stream.mp3
        #EXTINF:5 tvg-id="x",Mit Attribut
        file://\(present.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)

        """, to: url)

        let contents = try PlaylistTool.read(url: url)
        #expect(contents.format == .m3u8)
        #expect(contents.fields.title == "Meine Liste")
        #expect(contents.entries.count == 5)
        #expect(contents.entries[0].title == "Die Band - Lied")
        #expect(contents.entries[0].durationMilliseconds == 181_000)
        #expect(contents.entries[0].exists)
        #expect(contents.entries[0].resolvedPath == present.standardizedFileURL.path)
        #expect(contents.entries[1].exists)
        #expect(contents.entries[1].durationMilliseconds == nil)
        // Rückschrägstrich als Trenner, Datei fehlt.
        #expect(contents.entries[2].resolvedPath?.hasSuffix("/Album/fehlt.mp3") == true)
        #expect(!contents.entries[2].exists)
        #expect(contents.entries[2].title == "")
        #expect(contents.entries[3].isRemote)
        #expect(contents.entries[3].resolvedPath == nil)
        #expect(contents.entries[4].exists)
        #expect(contents.entries[4].title == "Mit Attribut")
        #expect(contents.entries[4].durationMilliseconds == 5_000)
        #expect(contents.missingCount == 1)
        #expect(contents.totalDurationMilliseconds == 186_000)
        #expect(contents.unknownDurationCount == 3)
        #expect(PlaylistTool.supportedFields(url: url) == [.title, .entryTitle])
    }

    @Test("m3u: Titel und Eintragstexte ändern, EXTINF anlegen, Kommentare und Attribute erhalten")
    func m3uRoundtrip() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("list.m3u")
        try write("# nur Pfade\r\na.mp3\r\n#EXTINF:12 tvg-id=\"x\",Alt\r\nb.mp3\r\n", to: url)

        let original = try PlaylistTool.read(url: url).fields
        #expect(original.title == "")
        var edited = original
        edited.title = "Neu"
        edited.entries[0].title = "Erstes"
        edited.entries[1].title = "Zweites"
        try PlaylistTool.write(url: url, fields: edited, original: original)
        #expect(try text(of: url) == "#EXTM3U\r\n#PLAYLIST:Neu\r\n# nur Pfade\r\n#EXTINF:-1,Erstes\r\na.mp3\r\n#EXTINF:12 tvg-id=\"x\",Zweites\r\nb.mp3\r\n")
        #expect(try PlaylistTool.read(url: url).fields == edited)

        // Interpret hat in M3U keinen Speicherort → Ablehnung vor der Mutation.
        var performer = edited
        performer.entries[0].performer = "X"
        #expect(throws: TagError.unsupportedDocumentField(name: "entryPerformer")) {
            try PlaylistTool.write(url: url, fields: performer, original: edited)
        }

        // Titel leeren entfernt die PLAYLIST-Zeile wieder.
        var cleared = edited
        cleared.title = ""
        try PlaylistTool.write(url: url, fields: cleared, original: edited)
        #expect(try text(of: url).contains("#PLAYLIST") == false)
    }

    // MARK: - PLS

    @Test("pls: Einträge nach Nummer sortiert lesen, TitleN ersetzen oder anlegen")
    func plsRoundtrip() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("list.pls")
        try write("""
        [playlist]
        File2=zwei.mp3
        Length2=120
        File1=eins.mp3
        File3=drei.mp3
        Title1=Eins
        Length1=-1
        NumberOfEntries=3
        Version=2

        """, to: url)

        let contents = try PlaylistTool.read(url: url)
        #expect(contents.format == .pls)
        #expect(contents.entries.map(\.number) == [1, 2, 3])
        #expect(contents.entries[0].title == "Eins")
        #expect(contents.entries[0].durationMilliseconds == nil)
        #expect(contents.entries[1].title == "")
        #expect(contents.entries[1].durationMilliseconds == 120_000)
        #expect(contents.entries[1].location == "zwei.mp3")
        #expect(PlaylistTool.supportedFields(url: url) == [.entryTitle])

        var edited = contents.fields
        edited.entries[0].title = "Eins neu"
        edited.entries[1].title = "Zwei"
        // Title3 wird genau vor der vorhandenen Title1-Zeile eingefügt,
        // während Title1 im selben Schritt ersetzt wird.
        edited.entries[2].title = "Drei"
        try PlaylistTool.write(url: url, fields: edited, original: contents.fields)
        #expect(try text(of: url) == """
        [playlist]
        File2=zwei.mp3
        Title2=Zwei
        Length2=120
        File1=eins.mp3
        File3=drei.mp3
        Title3=Drei
        Title1=Eins neu
        Length1=-1
        NumberOfEntries=3
        Version=2

        """)
        #expect(try PlaylistTool.read(url: url).fields == edited)
        var titled = edited
        titled.title = "X"
        #expect(throws: TagError.unsupportedDocumentField(name: "title")) {
            try PlaylistTool.write(url: url, fields: titled, original: edited)
        }
    }

    // MARK: - XSPF

    @Test("xspf: lesen, beschriften, fremde Elemente erhalten")
    func xspfRoundtrip() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let track = dir.appendingPathComponent("Ein Lied.mp3")
        try Data([0]).write(to: track)
        let url = dir.appendingPathComponent("list.xspf")
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/">
          <title>Liste</title>
          <annotation>Notiz</annotation>
          <trackList>
            <track>
              <location>Ein%20Lied.mp3</location>
              <title>Lied</title>
              <creator>Band</creator>
              <album>Album</album>
              <duration>4000</duration>
              <extension application="http://example.org/"><x:y xmlns:x="urn:x">1</x:y></extension>
            </track>
            <track>
              <location>http://example.org/stream</location>
            </track>
          </trackList>
        </playlist>
        """, to: url)

        let contents = try PlaylistTool.read(url: url)
        #expect(contents.fields.title == "Liste")
        #expect(contents.fields.performer == "")
        #expect(contents.entries[0].exists)
        #expect(contents.entries[0].resolvedPath == track.standardizedFileURL.path)
        #expect(contents.entries[0].album == "Album")
        #expect(contents.entries[0].durationMilliseconds == 4000)
        #expect(contents.entries[1].isRemote)
        #expect(contents.info.contains(DocumentInfoItem(label: "annotation", value: "Notiz")))

        var edited = contents.fields
        edited.performer = "Kuratorin"
        edited.entries[0].title = "Lied neu"
        edited.entries[1].title = "Stream"
        edited.entries[1].performer = "Sender"
        try PlaylistTool.write(url: url, fields: edited, original: contents.fields)
        #expect(try PlaylistTool.read(url: url).fields == edited)
        let result = try text(of: url)
        #expect(result.contains("<annotation>Notiz</annotation>"))
        #expect(result.contains("<extension application=\"http://example.org/\">"))
        #expect(result.contains("<creator>Kuratorin</creator>"))
        #expect(result.contains("<album>Album</album>"))
    }

    // MARK: - Export

    @Test("Export: m3u8, pls und xspf schreiben und wieder lesen (relativ und absolut)",
          .enabled(if: FileManager.default.fileExists(atPath: Fixtures.directory.appendingPathComponent("sample.mp3").path)))
    func exportRoundtrip() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let mp3 = sub.appendingPathComponent("01.mp3")
        let flac = sub.appendingPathComponent("02.flac")
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.mp3"), to: mp3)
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.flac"), to: flac)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Eins"),
                                       TagProperty(key: "ARTIST", value: "Band"),
                                       TagProperty(key: "ALBUM", value: "Das Album")], to: mp3)
        let untagged = dir.appendingPathComponent("notiz.txt")
        try write("kein Audio", to: untagged)

        for format in [PlaylistFormat.m3u8, .pls, .xspf] {
            let out = dir.appendingPathComponent("liste.\(format.rawValue)")
            let summary = try PlaylistExporter.export(
                files: [mp3, flac, untagged], to: out, format: format, title: "Titel")
            #expect(summary.count == 3)
            #expect(summary.untagged == [untagged])
            let contents = try PlaylistTool.read(url: out)
            #expect(contents.format == format, Comment(rawValue: format.rawValue))
            #expect(contents.entries.count == 3)
            let allExist = contents.entries.allSatisfy { $0.exists }
            #expect(allExist, Comment(rawValue: format.rawValue))
            #expect(contents.entries[0].location == "Album/01.mp3")
            #expect(contents.entries[2].title == "notiz")
            #expect(contents.entries[2].durationMilliseconds == nil)
            #expect(contents.entries[0].durationMilliseconds.map { $0 >= 1900 && $0 <= 2100 } == true)
            if format == .xspf {
                #expect(contents.fields.title == "Titel")
                #expect(contents.entries[0].title == "Eins")
                #expect(contents.entries[0].performer == "Band")
                #expect(contents.entries[0].album == "Das Album")
            } else {
                #expect(contents.entries[0].title == "Band - Eins")
            }
            if format == .m3u8 { #expect(contents.fields.title == "Titel") }
            // Vorhandene Datei wird ohne overwrite nicht ersetzt.
            #expect(throws: PlaylistExporter.ExportError.outputExists(out.path)) {
                try PlaylistExporter.export(files: [mp3], to: out, format: format)
            }
            #expect(try PlaylistTool.read(url: out).entries.count == 3)
        }

        // Absolute Pfade: Playlist an anderem Ort findet die Dateien trotzdem.
        let elsewhere = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let out = elsewhere.appendingPathComponent("abs.xspf")
        try PlaylistExporter.export(files: [mp3], to: out, format: .xspf, absolutePaths: true)
        let contents = try PlaylistTool.read(url: out)
        #expect(contents.entries[0].location.hasPrefix("file://"))
        #expect(contents.entries[0].exists)
        #expect(throws: PlaylistExporter.ExportError.unsupportedFormat(.cue)) {
            try PlaylistExporter.export(files: [mp3], to: elsewhere.appendingPathComponent("x.cue"), format: .cue)
        }
    }

    @Test("Playlist-Export erhält Prozentzeichen, Raute und Doppelpunkt im Dateinamen")
    func unusualFileNamesRoundtrip() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["a%20b.mp3", "#song.mp3", "abc:song.mp3"].map { name in
            let url = dir.appendingPathComponent(name)
            try write("kein Audio", to: url)
            return url
        }
        for format in [PlaylistFormat.m3u, .pls, .xspf] {
            let out = dir.appendingPathComponent("list.\(format.rawValue)")
            try PlaylistExporter.export(files: files, to: out, format: format)
            let entries = try PlaylistTool.read(url: out).entries
            #expect(entries.map(\.resolvedPath) == files.map { $0.standardizedFileURL.path })
            let allExist = entries.allSatisfy { $0.exists }
            #expect(allExist)
        }
    }

    @Test("Nicht darstellbare Textpfade werden vor dem Überschreiben abgelehnt; XSPF erhält sie")
    func unrepresentableTextPaths() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["line\nbreak.mp3", "back\\slash.mp3", "trailing.mp3 "] {
            let input = dir.appendingPathComponent(name)
            try write("kein Audio", to: input)
            for format in [PlaylistFormat.m3u, .pls] {
                let out = dir.appendingPathComponent("list.\(format.rawValue)")
                try write("original", to: out)
                #expect(throws: PlaylistExporter.ExportError.self) {
                    try PlaylistExporter.export(files: [input], to: out, format: format, overwrite: true)
                }
                #expect(try text(of: out) == "original")
            }
            let out = dir.appendingPathComponent(UUID().uuidString + ".xspf")
            try PlaylistExporter.export(files: [input], to: out, format: .xspf)
            #expect(try PlaylistTool.read(url: out).entries.first?.resolvedPath == input.standardizedFileURL.path)
        }
    }

    // MARK: - cue apply

    @Test("cue apply: Plan, Schreiben, No-op danach; ein Image für mehrere Tracks wird abgelehnt",
          .enabled(if: FileManager.default.fileExists(atPath: Fixtures.directory.appendingPathComponent("sample.mp3").path)))
    func cueApply() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("01.mp3")
        let flac = dir.appendingPathComponent("02.flac")
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.mp3"), to: mp3)
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.flac"), to: flac)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Zweites Lied")], to: flac)
        let cue = dir.appendingPathComponent("album.cue")
        try write("""
        REM DATE 1999
        PERFORMER "Die Band"
        TITLE "Das Album"
        FILE "01.mp3" MP3
          TRACK 01 AUDIO
            TITLE "Erstes Lied"
            INDEX 01 00:00:00
        FILE "02.flac" WAVE
          TRACK 02 AUDIO
            TITLE "Zweites Lied"
            PERFORMER "Gast"
            INDEX 01 00:00:00

        """, to: cue)

        let plan = try CueApply.plan(cueURL: cue)
        #expect(plan.items.count == 2)
        #expect(plan.items[0].changedKeys == ["ALBUM", "ALBUMARTIST", "ARTIST", "DATE", "TITLE", "TRACKNUMBER"])
        #expect(plan.items[0].properties["ARTIST"] == "Die Band")
        // Der vorhandene Titel zählt nicht als Änderung.
        #expect(!plan.items[1].changedKeys.contains("TITLE"))
        #expect(plan.items[1].properties["ARTIST"] == "Gast")
        #expect(plan.items[1].properties["TRACKNUMBER"] == "2/2")

        #expect(try CueApply.apply(plan) == 2)
        let written = try TagFile.read(at: mp3)
        #expect(written.firstValue(for: "TITLE") == "Erstes Lied")
        #expect(written.firstValue(for: "ALBUM") == "Das Album")
        #expect(written.firstValue(for: "ARTIST") == "Die Band")
        #expect(written.firstValue(for: "TRACKNUMBER") == "1/2")
        #expect(written.firstValue(for: "DATE") == "1999")
        #expect(try TagFile.read(at: flac).firstValue(for: "ARTIST") == "Gast")
        #expect(try CueApply.plan(cueURL: cue).changingItems.isEmpty)

        // Ein Image für zwei Tracks: kein Schreiben möglich.
        let image = dir.appendingPathComponent("image.cue")
        try write("FILE \"01.mp3\" MP3\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:01:00\n", to: image)
        #expect(throws: CueApply.ApplyError.sharedFile(mp3.standardizedFileURL.path, tracks: [1, 2])) {
            try CueApply.plan(cueURL: image)
        }
        // Zwei Namen derselben Datei sind weiterhin ein gemeinsames Image.
        for kind in ["symlink", "hardlink"] {
            let alias = dir.appendingPathComponent(kind + ".mp3")
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mp3)
            } else {
                try FileManager.default.linkItem(at: mp3, to: alias)
            }
            try write("FILE \"01.mp3\" MP3\nTRACK 01 AUDIO\nINDEX 01 00:00:00\n"
                + "FILE \"\(alias.lastPathComponent)\" MP3\nTRACK 02 AUDIO\nINDEX 01 00:01:00\n", to: image)
            #expect(throws: CueApply.ApplyError.sharedFile(mp3.standardizedFileURL.path, tracks: [1, 2])) {
                try CueApply.plan(cueURL: image)
            }
        }
        // Fehlende Datei: Fehler mit Pfad.
        let missing = dir.appendingPathComponent("missing.cue")
        try write("FILE \"nix.mp3\" MP3\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n", to: missing)
        #expect(throws: CueApply.ApplyError.self) { try CueApply.plan(cueURL: missing) }
    }

    // MARK: - MediaFormats

    @Test("Playlist-Endungen sind die Medienart playlist und nicht archivierbar")
    func mediaFormatsKnowPlaylists() throws {
        for ext in ["cue", "m3u", "M3U8", "pls", "xspf"] {
            #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/x/liste.\(ext)")) == .playlist, Comment(rawValue: ext))
        }
        #expect(!MediaFormats.isArchivable(.playlist))
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("liste.m3u")
        try write("a.mp3\n", to: url)
        #expect(MediaFormats.expandMediaFiles([dir]).map(\.lastPathComponent) == ["liste.m3u"])
        #expect(try TagArchiveIO.build(files: [url], baseDirectory: dir, includeCovers: false).files.isEmpty)
    }


    @Test("Windows-Pfade in Playlists: Laufwerk und UNC gelten als absolut, nicht als relativ")
    func windowsPathsStayAbsolute() throws {
        let base = URL(fileURLWithPath: "/music/lists")
        let drive = PlaylistTool.resolve(location: "C:\\Musik\\lied.mp3", base: base)
        #expect(drive.path == "C:/Musik/lied.mp3")
        #expect(!drive.isRemote)
        let unc = PlaylistTool.resolve(location: "\\\\server\\share\\lied.mp3", base: base)
        #expect(unc.path == "//server/share/lied.mp3")
        #expect(!unc.isRemote)
        // Relative Windows-Pfade werden weiterhin an den Ordner gehängt.
        #expect(PlaylistTool.resolve(location: "sub\\lied.mp3", base: base).path == "/music/lists/sub/lied.mp3")
        #expect(PlaylistTool.resolve(location: "http://example.org/a.mp3", base: base).isRemote)
    }

    @Test("m3u/pls: unendliche oder riesige Dauern werden als unbekannt gelesen statt abzustürzen")
    func absurdDurationsAreUnknown() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = dir.appendingPathComponent("liste.m3u")
        try write("#EXTM3U\n#EXTINF:inf,A\na.mp3\n#EXTINF:1e16,B\nb.mp3\n#EXTINF:nan,C\nc.mp3\n#EXTINF:12.4,D\nd.mp3\n", to: m3u)
        let entries = try PlaylistTool.read(url: m3u).entries
        #expect(entries.map(\.durationMilliseconds) == [nil, nil, nil, 12_400])
        let pls = dir.appendingPathComponent("liste.pls")
        try write("[playlist]\nFile1=a.mp3\nLength1=inf\nFile2=b.mp3\nLength2=1e16\nFile3=c.mp3\nLength3=7\nNumberOfEntries=3\nVersion=2\n", to: pls)
        #expect(try PlaylistTool.read(url: pls).entries.map(\.durationMilliseconds) == [nil, nil, 7000])
    }

    @Test("Playlist-Dauern runden ohne Überlauf; CUE prüft Sekunden und Frames")
    func durationArithmetic() throws {
        #expect(PlaylistTool.formatDuration(Int.max) == "2562047788015:12:56")
        #expect(PlaylistTool.formatDuration(59_500) == "1:00")
        #expect(CueSheetFile.milliseconds(fromIndex: "01:59:74") == 119_987)
        for value in ["1::2:3", "0:60:0", "0:0:75", "\(Int.max):0:0"] {
            #expect(CueSheetFile.milliseconds(fromIndex: value) == nil)
        }
        let item = PlaylistExporter.Item(url: URL(fileURLWithPath: "/a.mp3"), title: "A", durationMilliseconds: Int.max)
        for format in [PlaylistFormat.m3u, .pls] {
            let data = try PlaylistExporter.render(items: [item], format: format,
                playlist: URL(fileURLWithPath: "/list.\(format.rawValue)"), absolutePaths: true, title: "")
            #expect(String(decoding: data, as: UTF8.self).contains("9223372036854776"))
        }
    }

    @Test("Export: Zeilenumbrüche in Titel/Interpret bleiben auf einer Zeile; overwrite ersetzt atomar ohne Reste",
          .enabled(if: FileManager.default.fileExists(atPath: Fixtures.directory.appendingPathComponent("sample.mp3").path)))
    func exportEscapesNewlinesAndOverwritesSafely() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("01.mp3")
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.mp3"), to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Zeile eins\nZeile zwei"),
                                       TagProperty(key: "ARTIST", value: "Band\r\nName")], to: mp3)
        for format in [PlaylistFormat.m3u, .pls] {
            let out = dir.appendingPathComponent("liste.\(format.rawValue)")
            try PlaylistExporter.export(files: [mp3], to: out, format: format, title: "Titel\nZwei")
            let contents = try PlaylistTool.read(url: out)
            #expect(contents.entries.count == 1, Comment(rawValue: format.rawValue))
            #expect(contents.entries[0].title == "Band Name - Zeile eins Zeile zwei")
            if format == .m3u { #expect(contents.fields.title == "Titel Zwei") }
            // Erneut mit overwrite: Datei wird ersetzt, keine Temp-Reste.
            try PlaylistExporter.export(files: [mp3], to: out, format: format, overwrite: true)
            #expect(try PlaylistTool.read(url: out).entries.count == 1)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }
}

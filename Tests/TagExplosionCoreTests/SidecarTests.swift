// Video-Sidecars: Kodi-NFO (Lesen, Roundtrip mit Erhalt fremder Elemente
// und Einrückung, Nur-URL, XML + URL-Zeile), Kopplung Video ↔ NFO,
// Untertitel (Zeichensatz, CRLF, Sprache aus dem Dateinamen, VTT-Kopf,
// Zeitverschiebung) und der Archiv-Roundtrip für NFO-Felder.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Sidecars (NFO, SRT, VTT)", .serialized)
struct SidecarTests {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeFile(_ name: String, _ text: String, in dir: URL,
                           encoding: String.Encoding = .utf8, bom: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var data = Data()
        if bom { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        // `encoded(as:)` statt `data(using:)`: Linux-Foundation kodiert CRLF
        // nicht nach Latin-1 (siehe TextEncoding.swift).
        data.append(try #require(text.encoded(as: encoding)))
        try data.write(to: url)
        return url
    }

    /// Eine typische Kodi-Film-NFO: Deklaration, vier Leerzeichen, fremde
    /// Elemente (`lastplayed`, `fileinfo`), Darsteller, ratings-Block.
    static let movieNFO = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
    <movie>
        <title>Der Film</title>
        <originaltitle>The Movie</originaltitle>
        <sorttitle>Film, Der</sorttitle>
        <ratings>
            <rating name="imdb" max="10" default="true">
                <value>7.400000</value>
                <votes>1234</votes>
            </rating>
        </ratings>
        <userrating>8</userrating>
        <outline>Kurz &amp; knapp.</outline>
        <plot>Eine lange Handlung mit &lt;Klammern&gt;.</plot>
        <tagline>Nichts ist, wie es scheint</tagline>
        <runtime>95</runtime>
        <thumb aspect="poster">https://example.invalid/poster.jpg</thumb>
        <fanart>
            <thumb>https://example.invalid/fanart.jpg</thumb>
        </fanart>
        <mpaa>FSK 12</mpaa>
        <uniqueid type="imdb" default="true">tt0000001</uniqueid>
        <uniqueid type="tmdb">4711</uniqueid>
        <genre>Drama</genre>
        <genre>Krimi</genre>
        <tag>Lieblingsfilm</tag>
        <year>2019</year>
        <premiered>2019-05-17</premiered>
        <studio>Beispielstudio</studio>
        <credits>Autorin Beispiel</credits>
        <director>Regisseur Beispiel</director>
        <actor>
            <name>Erika Beispiel</name>
            <role>Kommissarin</role>
            <order>0</order>
        </actor>
        <lastplayed>2024-01-01 20:00:00</lastplayed>
        <fileinfo>
            <streamdetails>
                <video>
                    <codec>h264</codec>
                </video>
            </streamdetails>
        </fileinfo>
    </movie>

    """

    // MARK: - NFO lesen

    @Test("NFO: Felder, ratings-Block, Darsteller und uniqueid lesen")
    func nfoRead() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("film.nfo", Self.movieNFO, in: dir)
        #expect(MediaFormats.kind(of: url) == .sidecar)
        let contents = try KodiNFOFile.read(url: url)
        #expect(contents.rootName == "movie")
        #expect(!contents.isURLOnly)
        let f = contents.fields
        #expect(f.title == "Der Film")
        #expect(f.originalTitle == "The Movie")
        #expect(f.sortTitle == "Film, Der")
        #expect(f.rating == "7.400000")
        #expect(f.userRating == "8")
        #expect(f.outline == "Kurz & knapp.")
        #expect(f.plot == "Eine lange Handlung mit <Klammern>.")
        #expect(f.tagline == "Nichts ist, wie es scheint")
        #expect(f.runtime == "95")
        #expect(f.mpaa == "FSK 12")
        #expect(f.genres == ["Drama", "Krimi"])
        #expect(f.tags == ["Lieblingsfilm"])
        #expect(f.year == "2019")
        #expect(f.premiered == "2019-05-17")
        #expect(f.studio == "Beispielstudio")
        #expect(f.credits == "Autorin Beispiel")
        #expect(f.directors == ["Regisseur Beispiel"])
        #expect(contents.info.contains(DocumentInfoItem(label: "type", value: "movie")))
        #expect(contents.info.contains(DocumentInfoItem(label: "actor", value: "Erika Beispiel (Kommissarin)")))
        #expect(contents.info.contains(DocumentInfoItem(label: "uniqueid", value: "imdb: tt0000001 (default)")))
        #expect(contents.info.contains(DocumentInfoItem(label: "uniqueid", value: "tmdb: 4711")))
        #expect(contents.info.contains(DocumentInfoItem(label: "thumb", value: "https://example.invalid/poster.jpg")))
        #expect(contents.info.contains(DocumentInfoItem(label: "fanart", value: "https://example.invalid/fanart.jpg")))
        #expect(contents.info.contains(DocumentInfoItem(label: "video", value: "(none)")))
    }

    @Test("NFO: Roundtrip erhält fremde Elemente, Reihenfolge, Einrückung und Deklaration")
    func nfoRoundtrip() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("film.nfo", Self.movieNFO, in: dir)
        let original = try KodiNFOFile.read(url: url).fields
        var edited = original
        edited.title = "Der Film & sein Titel"
        edited.year = "2020"
        edited.genres = ["Thriller", "Drama", "Komödie"]
        edited.rating = "8.1"
        edited.directors = ["Erste Regie", "Zweite Regie"]
        edited.plot = ""
        try KodiNFOFile.write(url: url, fields: edited, original: original)
        #expect(try KodiNFOFile.read(url: url).fields == edited)

        let text = try String(contentsOf: url, encoding: .utf8)
        // Erwartung: dieselbe Datei, nur die geänderten Zeilen anders.
        var expected = Self.movieNFO
        expected = expected.replacingOccurrences(of: "<title>Der Film</title>", with: "<title>Der Film &amp; sein Titel</title>")
        expected = expected.replacingOccurrences(of: "<year>2019</year>", with: "<year>2020</year>")
        expected = expected.replacingOccurrences(
            of: "    <genre>Drama</genre>\n    <genre>Krimi</genre>\n",
            with: "    <genre>Thriller</genre>\n    <genre>Drama</genre>\n    <genre>Komödie</genre>\n")
        expected = expected.replacingOccurrences(of: "<value>7.400000</value>", with: "<value>8.1</value>")
        expected = expected.replacingOccurrences(
            of: "    <director>Regisseur Beispiel</director>\n",
            with: "    <director>Erste Regie</director>\n    <director>Zweite Regie</director>\n")
        expected = expected.replacingOccurrences(of: "    <plot>Eine lange Handlung mit &lt;Klammern&gt;.</plot>\n", with: "")
        #expect(text == expected)

        // Zurück auf die Ausgangswerte: byteweise die Ausgangsdatei (bis auf
        // die gelöschte plot-Zeile, die am Ende neu entsteht).
        var restored = edited
        restored.title = original.title
        restored.year = original.year
        restored.genres = original.genres
        restored.rating = original.rating
        restored.directors = original.directors
        try KodiNFOFile.write(url: url, fields: restored, original: edited)
        let back = try String(contentsOf: url, encoding: .utf8)
        #expect(back == Self.movieNFO.replacingOccurrences(
            of: "    <plot>Eine lange Handlung mit &lt;Klammern&gt;.</plot>\n", with: ""))

        // Ohne Änderung wird nichts geschrieben.
        let stamp = FileStamp.current(of: url)
        try KodiNFOFile.write(url: url, fields: restored, original: restored)
        #expect(FileStamp.current(of: url) == stamp)
    }

    @Test("NFO: CRLF, zwei Leerzeichen, selbstschließende Elemente und Episoden-aired bleiben erhalten")
    func nfoStyleDetection() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<episodedetails>\r\n  <title>Folge 1</title>\r\n"
            + "  <showtitle>Serie</showtitle>\r\n  <season>1</season>\r\n  <episode>1</episode>\r\n"
            + "  <aired>2021-03-04</aired>\r\n  <thumb />\r\n  <plot></plot>\r\n</episodedetails>\r\n"
        let url = try writeFile("S01E01.nfo", episode, in: dir)
        let original = try KodiNFOFile.read(url: url).fields
        #expect(original.premiered == "2021-03-04")
        #expect(original.season == "1")
        var edited = original
        edited.premiered = "2021-03-05"
        edited.plot = "Neu"
        try KodiNFOFile.write(url: url, fields: edited, original: original)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == episode
            .replacingOccurrences(of: "<aired>2021-03-04</aired>", with: "<aired>2021-03-05</aired>")
            .replacingOccurrences(of: "<plot></plot>", with: "<plot>Neu</plot>"))
        #expect(!text.contains("<premiered>"))
    }

    @Test("NFO: Werteprüfung vor dem Schreiben")
    func nfoValidation() throws {
        let original = NFOFields()
        var bad = original
        bad.year = "20x9"
        #expect(throws: TagError.invalidDocumentValue(field: "year", reason: "expected a four-digit year")) {
            try KodiNFOFile.validate(bad, original: original)
        }
        bad = original
        bad.runtime = "neunzig"
        #expect(throws: TagError.self) { try KodiNFOFile.validate(bad, original: original) }
        bad = original
        bad.rating = "7,5"
        #expect(throws: TagError.self) { try KodiNFOFile.validate(bad, original: original) }
        bad = original
        bad.year = "2019"
        bad.rating = "7.5"
        bad.premiered = "2019-01-02"
        try KodiNFOFile.validate(bad, original: original)
    }

    @Test("Nur-URL-NFO wird angezeigt, nicht beschrieben; Szene-Text ist keine NFO")
    func urlOnlyNFO() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("film.nfo", "https://www.themoviedb.org/movie/4711\n", in: dir)
        #expect(MediaFormats.kind(of: url) == .sidecar)
        let contents = try KodiNFOFile.read(url: url)
        #expect(contents.isURLOnly)
        #expect(contents.urls == ["https://www.themoviedb.org/movie/4711"])
        #expect(contents.info.contains(DocumentInfoItem(label: "type", value: "url-only")))
        var edited = contents.fields
        edited.title = "Geht nicht"
        #expect(throws: TagError.urlOnlyNFO(path: url.path)) {
            try KodiNFOFile.write(url: url, fields: edited, original: contents.fields)
        }
        #expect(!MediaFormats.isArchivable(url: url))

        let scene = try writeFile("release.nfo", "  ____\n |    | Release Group presents\n http://example.invalid\n", in: dir)
        #expect(MediaFormats.kind(of: scene) == nil)
        #expect(throws: TagError.self) { try KodiNFOFile.read(url: scene) }
    }

    @Test("XML plus URL-Zeile hinter dem Wurzelelement bleibt beim Schreiben erhalten")
    func xmlWithTrailingURL() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "<movie>\n    <title>A</title>\n</movie>\nhttps://www.imdb.com/title/tt0000001/\n"
        let url = try writeFile("film.nfo", text, in: dir)
        let contents = try KodiNFOFile.read(url: url)
        #expect(contents.urls == ["https://www.imdb.com/title/tt0000001/"])
        var edited = contents.fields
        edited.title = "B"
        try KodiNFOFile.write(url: url, fields: edited, original: contents.fields)
        #expect(try String(contentsOf: url, encoding: .utf8)
            == text.replacingOccurrences(of: "<title>A</title>", with: "<title>B</title>"))
    }

    @Test("Neue Elemente entstehen mit der Einrückung der Datei am Ende des Wurzelelements")
    func nfoNewElements() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "<tvshow>\n\t<title>Serie</title>\n</tvshow>\n"
        let url = try writeFile("tvshow.nfo", text, in: dir)
        let original = try KodiNFOFile.read(url: url).fields
        var edited = original
        edited.genres = ["Comedy"]
        edited.studio = "Sender"
        try KodiNFOFile.write(url: url, fields: edited, original: original)
        #expect(try String(contentsOf: url, encoding: .utf8)
            == "<tvshow>\n\t<title>Serie</title>\n\t<genre>Comedy</genre>\n\t<studio>Sender</studio>\n</tvshow>\n")
        #expect(MediaFormats.videoURL(forNFO: url) == nil)
    }

    // MARK: - Kopplung Video ↔ NFO

    @Test("Ordner-Drop versteckt die NFO eines gelisteten Videos; Kopplung in beide Richtungen")
    func videoCoupling() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("sample.mkv")
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("sample.mkv"), to: video)
        let nfo = try writeFile("sample.nfo", Self.movieNFO, in: dir)
        let orphan = try writeFile("tvshow.nfo", "<tvshow>\n    <title>Serie</title>\n</tvshow>\n", in: dir)
        let subtitle = try writeFile("sample.de.srt", "1\n00:00:01,000 --> 00:00:02,000\nHallo\n", in: dir)

        let listed = MediaFormats.expandMediaFiles([dir]).map(\.lastPathComponent)
        #expect(listed == ["sample.de.srt", "sample.mkv", "tvshow.nfo"])
        #expect(MediaFormats.expandMediaFiles([nfo]).map(\.lastPathComponent) == ["sample.nfo"])
        #expect(MediaFormats.nfoURL(forVideo: video)?.lastPathComponent == "sample.nfo")
        #expect(MediaFormats.nfoURL(forVideo: subtitle) == nil)
        #expect(MediaFormats.videoURL(forNFO: nfo)?.lastPathComponent == "sample.mkv")
        #expect(MediaFormats.videoURL(forNFO: orphan) == nil)
        #expect(try KodiNFOFile.read(url: nfo).info.contains(DocumentInfoItem(label: "video", value: "sample.mkv")))
        #expect(MediaFormats.kind(of: subtitle) == .sidecar)
        #expect(!MediaFormats.isArchivable(url: subtitle))
        #expect(MediaFormats.isArchivable(url: nfo))
    }

    // MARK: - Untertitel

    @Test("SRT: CRLF, BOM und Latin-1 werden erkannt; Cues und Zeitspanne stimmen")
    func srtEncodings() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = "1\r\n00:00:01,000 --> 00:00:02,500\r\nGrüße\r\n\r\n2\r\n00:01:00,000 --> 00:01:03,250\r\nZeile 1\r\nZeile 2\r\n"
        let bom = try writeFile("film.de.srt", body, in: dir, bom: true)
        let plain = try writeFile("film.en.forced.srt", body, in: dir)
        let latin = try writeFile("film.fr.srt", body, in: dir, encoding: .isoLatin1)

        let a = try SubtitleFile.read(url: bom).info
        #expect(a.format == .srt)
        #expect(a.encoding == "UTF-8 (BOM)")
        #expect(a.lineEndings == "CRLF")
        #expect(a.cueCount == 2)
        #expect(a.firstStartMilliseconds == 1000)
        #expect(a.lastEndMilliseconds == 63_250)
        #expect(a.spanMilliseconds == 62_250)
        #expect(a.languageFromName == "de")
        #expect(a.flagsFromName == [])
        #expect(a.header == nil)

        let b = try SubtitleFile.read(url: plain).info
        #expect(b.encoding == "UTF-8")
        #expect(b.languageFromName == "en")
        #expect(b.flagsFromName == ["forced"])

        let c = try SubtitleFile.read(url: latin).info
        #expect(c.encoding == "Latin-1")
        #expect(c.cueCount == 2)

        // SRT hat keinen Speicherort für Titel/Sprache.
        let fields = try SubtitleFile.read(url: plain).fields
        var edited = fields
        edited.language = "de"
        #expect(throws: TagError.unsupportedDocumentField(name: "language")) {
            try SubtitleFile.requireWritable(edited, original: fields, url: plain)
        }
    }

    @Test("Sprache und Flags aus dem Dateinamen")
    func filenameLanguage() {
        func parts(_ name: String) -> (String, String?, [String]) {
            let p = SubtitleFile.filenameParts(of: URL(fileURLWithPath: "/tmp/\(name)"))
            return (p.base, p.language, p.flags)
        }
        #expect(parts("film.de.srt") == ("film", "de", []))
        #expect(parts("film.en.forced.vtt") == ("film", "en", ["forced"]))
        #expect(parts("film.pt-BR.sdh.srt") == ("film", "pt-BR", ["sdh"]))
        #expect(parts("film.srt") == ("film", nil, []))
        #expect(parts("film.2019.srt") == ("film.2019", nil, []))
        #expect(parts("de.srt") == ("de", nil, []))
        #expect(parts("Serie.S01E01.ger.srt") == ("Serie.S01E01", "ger", []))
        #expect(parts("film.forced.srt") == ("film", nil, ["forced"]))
    }

    @Test("VTT: Kopfblock lesen, Titel und Language schreiben, Rest byteweise gleich")
    func vttHeader() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "WEBVTT Mein Titel\nKind: captions\nLanguage: en\n\nNOTE Erster Hinweis\n\n00:01.000 --> 00:02.000\nHallo\n\nNOTE\nZweiter\nHinweis\n\n01:00:00.000 --> 01:00:01.000 line:0\nEnde\n"
        let url = try writeFile("film.vtt", text, in: dir)
        let contents = try SubtitleFile.read(url: url)
        #expect(contents.info.cueCount == 2)
        #expect(contents.info.firstStartMilliseconds == 1000)
        #expect(contents.info.lastEndMilliseconds == 3_600_000 + 1000)
        #expect(contents.info.header == SubtitleHeader(
            title: "Mein Titel", lines: ["Kind: captions", "Language: en"],
            notes: ["Erster Hinweis", "Zweiter\nHinweis"]))
        #expect(contents.fields == SubtitleEditableFields(title: "Mein Titel", language: "en"))

        var edited = contents.fields
        edited.title = "Neuer Titel"
        edited.language = "de"
        try SubtitleFile.write(url: url, fields: edited, original: contents.fields)
        #expect(try SubtitleFile.read(url: url).fields == edited)
        #expect(try String(contentsOf: url, encoding: .utf8) == text
            .replacingOccurrences(of: "WEBVTT Mein Titel", with: "WEBVTT Neuer Titel")
            .replacingOccurrences(of: "Language: en", with: "Language: de"))

        // Leere Werte entfernen Titel und Language-Zeile.
        let cleared = SubtitleEditableFields()
        try SubtitleFile.write(url: url, fields: cleared, original: edited)
        #expect(try String(contentsOf: url, encoding: .utf8) == text
            .replacingOccurrences(of: "WEBVTT Mein Titel", with: "WEBVTT")
            .replacingOccurrences(of: "Language: en\n", with: ""))

        // Language neu anlegen, wenn die Datei nur aus "WEBVTT" besteht.
        let minimal = try writeFile("min.vtt", "WEBVTT", in: dir)
        try SubtitleFile.write(url: minimal, fields: SubtitleEditableFields(language: "fr"),
                               original: SubtitleEditableFields())
        #expect(try String(contentsOf: minimal, encoding: .utf8) == "WEBVTT\nLanguage: fr")
        #expect(try SubtitleFile.read(url: minimal).fields.language == "fr")
    }

    @Test("Zeitverschiebung: hin und zurück byteweise identisch, negativ abgelehnt")
    func shift() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\nGrüße --> nicht anfassen\r\n\r\n2\r\n00:59:59,000 --> 01:00:00,000\r\nEnde\r\n"
        let url = try writeFile("film.srt", srt, in: dir, encoding: .isoLatin1)
        try SubtitleFile.shift(url: url, milliseconds: 1500)
        let shifted = try #require(String.decoded(try Data(contentsOf: url), as: .isoLatin1))
        #expect(shifted == srt
            .replacingOccurrences(of: "00:00:01,000 --> 00:00:02,500", with: "00:00:02,500 --> 00:00:04,000")
            .replacingOccurrences(of: "00:59:59,000 --> 01:00:00,000", with: "01:00:00,500 --> 01:00:01,500"))
        try SubtitleFile.shift(url: url, milliseconds: -1500)
        let latinBytes = try #require(srt.encoded(as: .isoLatin1))
        #expect(try Data(contentsOf: url) == latinBytes)
        #expect(throws: TagError.self) { try SubtitleFile.shift(url: url, milliseconds: -1001) }
        #expect(try Data(contentsOf: url) == latinBytes)

        // VTT ohne Stundenanteil bekommt ihn erst ab einer Stunde.
        let vtt = "WEBVTT\n\n59:59.000 --> 59:59.900\nA\n"
        #expect(try SubtitleFile.shifted(text: vtt, milliseconds: 1000)
            == "WEBVTT\n\n01:00:00.000 --> 01:00:00.900\nA\n")
        #expect(try SubtitleFile.shifted(text: vtt, milliseconds: -1000)
            == "WEBVTT\n\n59:58.000 --> 59:58.900\nA\n")
    }

    @Test("Muster: %{base}.%{lang} benennt einen Untertitel um")
    func subtitlePattern() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeFile("film.en.vtt", "WEBVTT Titel\n", in: dir)
        let fields = PatternFields.fields(from: try SubtitleFile.read(url: url), url: url)
        #expect(fields["BASE"] == "film")
        #expect(fields["LANG"] == "en")
        #expect(fields["TITLE"] == "Titel")
        let pattern = try FilenamePattern("%{base}.de")
        #expect(pattern.renderStem(fields: fields) == "film.de")
    }

    // MARK: - Archiv

    @Test("Archiv: NFO-Felder werden gesichert und wiederhergestellt, Untertitel bleiben draußen")
    func archiveRoundtrip() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nfo = try writeFile("film.nfo", Self.movieNFO, in: dir)
        let srt = try writeFile("film.de.srt", "1\n00:00:01,000 --> 00:00:02,000\nHallo\n", in: dir)
        let original = try KodiNFOFile.read(url: nfo).fields
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [nfo, srt], to: json, includeCovers: true)
        let archive = try TagArchiveIO.load(json)
        #expect(archive.version == TagArchive.currentVersion)
        #expect(archive.files.map(\.path) == ["film.nfo"])
        #expect(archive.files[0].kind == .sidecar)
        #expect(archive.files[0].nfo == original)

        var changed = original
        changed.title = "Weg"
        changed.genres = []
        try KodiNFOFile.write(url: nfo, fields: changed, original: original)
        let preview = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: true)
        #expect(preview.applied == ["film.nfo"])
        #expect(try KodiNFOFile.read(url: nfo).fields.title == "Weg")
        let report = try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        #expect(report.applied == ["film.nfo"])
        #expect(try KodiNFOFile.read(url: nfo).fields == original)
        #expect(try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false).unchanged == ["film.nfo"])

        // Ein unbrauchbares Jahr scheitert je Eintrag, vor jeder Sicherung.
        var hostile = archive
        hostile.files[0].nfo?.year = "irgendwann"
        let rejected = try TagArchiveIO.apply(hostile, relativeTo: dir, dryRun: true)
        #expect(rejected.failed.map(\.0) == ["film.nfo"])
        #expect(rejected.failed.first?.1.contains("year") == true)
    }


    @Test("NFO-Prüfung: Bewertung nur 0…10, premiered nur existierende Kalendertage")
    func nfoValidationRanges() throws {
        let original = NFOFields()
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(rating: "11"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(rating: "-0.5"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(rating: "inf"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(userRating: "10.5"), original: original) }
        #expect(throws: Never.self) { try KodiNFOFile.validate(NFOFields(rating: "7.5", userRating: "10"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(premiered: "2026-02-31"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(premiered: "2026-99-99"), original: original) }
        #expect(throws: TagError.self) { try KodiNFOFile.validate(NFOFields(premiered: "2023-02-29"), original: original) }
        #expect(throws: Never.self) { try KodiNFOFile.validate(NFOFields(premiered: "2024-02-29"), original: original) }
        // Ein unveränderter (schon vorher ungültiger) Altwert blockiert
        // andere Änderungen nicht.
        let legacy = NFOFields(premiered: "2026-02-31", rating: "11")
        var edited = legacy
        edited.title = "Neu"
        #expect(throws: Never.self) { try KodiNFOFile.validate(edited, original: legacy) }
    }

    @Test("ISODate: Schaltjahre und Monatslängen")
    func isoCalendarDays() {
        #expect(ISODate.isCalendarDay("2000-02-29"))
        #expect(!ISODate.isCalendarDay("1900-02-29"))
        #expect(ISODate.isCalendarDay("2024-04-30"))
        #expect(!ISODate.isCalendarDay("2024-04-31"))
        #expect(!ISODate.isCalendarDay("2024-00-10"))
        #expect(!ISODate.isCalendarDay("2024-1-10"))
        #expect(!ISODate.isCalendarDay("24-01-10"))
    }

    @Test("Untertitel-Verschiebung: unendliche oder riesige Sekunden enden als Fehler, nicht als Absturz")
    func subtitleShiftRange() throws {
        #expect(try SubtitleFile.shiftMilliseconds(seconds: 1.5) == 1500)
        #expect(try SubtitleFile.shiftMilliseconds(seconds: -0.25) == -250)
        #expect(throws: TagError.self) { try SubtitleFile.shiftMilliseconds(seconds: 1e16) }
        #expect(throws: TagError.self) { try SubtitleFile.shiftMilliseconds(seconds: .infinity) }
        #expect(throws: TagError.self) { try SubtitleFile.shiftMilliseconds(seconds: .nan) }
    }
}

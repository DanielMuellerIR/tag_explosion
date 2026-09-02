// Konsistenzprüfung: jede Regel einzeln auf synthetischen Items, dazu ein
// Lauf über echte Fixture-Kopien (Tags per TagFile.write gesetzt), damit
// auch der Leseweg `Item.load` und die Cover-Erkennung geprüft sind.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("LibraryCheck")
struct LibraryCheckTests {

    /// Synthetisches Audio-Item; `covers: nil` hieße „Format kann kein Cover",
    /// deshalb ist die Voreinstellung eine leere Liste (Cover fehlt).
    private func audio(_ name: String, folder: String = "/lib/album", _ fields: [String: String],
                       covers: [LibraryCheck.CoverSummary]? = [], duration: Int? = 180_000)
        -> LibraryCheck.Item {
        var properties = fields.sorted { $0.key < $1.key }.map { TagProperty(key: $0.key, value: $0.value) }
        // GENRE darf mehrwertig sein: "Jazz|Bebop" wird zu zwei Feldern.
        if let genres = fields["GENRE"], genres.contains("|") {
            properties.removeAll { $0.key == "GENRE" }
            properties += genres.split(separator: "|").map { TagProperty(key: "GENRE", value: String($0)) }
        }
        return LibraryCheck.Item(
            url: URL(fileURLWithPath: "\(folder)/\(name)"), kind: .audio, properties: properties,
            covers: covers, durationMilliseconds: duration,
            title: fields["TITLE"] ?? "", patternFields: PatternFields.fields(from: properties))
    }

    private let jpeg500 = LibraryCheck.CoverSummary(mimeType: "image/jpeg", bytes: 10, width: 500, height: 500)
    private let png300 = LibraryCheck.CoverSummary(mimeType: "image/png", bytes: 10, width: 300, height: 300)

    /// Vollständig getaggtes Album ohne Befund als Ausgangspunkt.
    private func cleanAlbum() -> [LibraryCheck.Item] {
        (1...3).map { index in
            audio("0\(index).mp3", [
                "TITLE": "Track \(index)", "ARTIST": "Duo", "ALBUM": "Kind of Blue",
                "ALBUMARTIST": "Duo", "TRACKNUMBER": "\(index)/3", "DATE": "1959", "GENRE": "Jazz",
            ], covers: [jpeg500], duration: 100_000 * index)
        }
    }

    private func codes(_ report: LibraryCheck.Report) -> [LibraryCheck.RuleCode] {
        report.findings.map(\.code)
    }

    @Test("Sauberes Album: keine Befunde, eine Gruppe mit Album-Label")
    func cleanAlbumHasNoFindings() {
        let report = LibraryCheck.run(cleanAlbum())
        #expect(report.findings.isEmpty)
        #expect(report.checkedFiles == 3)
        #expect(report.groups.map(\.label) == ["Kind of Blue — Duo"])
        #expect(report.plainText().contains("No findings in 3 file(s)"))
    }

    @Test("Tracknummern: Lücke, Dublette, fehlende Gesamtzahl, Track > Gesamt, fehlende Nummer")
    func trackNumberRules() {
        var items = cleanAlbum()
        items[1].properties.removeAll { $0.key == "TRACKNUMBER" }
        items[1].properties.append(TagProperty(key: "TRACKNUMBER", value: "1"))      // Dublette zu 1, ohne Gesamtzahl
        items[2].properties.removeAll { $0.key == "TRACKNUMBER" }
        items[2].properties.append(TagProperty(key: "TRACKNUMBER", value: "5/3"))    // größer als Gesamt
        items.append(audio("04.mp3", ["TITLE": "Vier", "ARTIST": "Duo", "ALBUM": "Kind of Blue",
                                       "ALBUMARTIST": "Duo", "TRACKNUMBER": "A1", "DATE": "1959",
                                       "GENRE": "Jazz"], covers: [jpeg500]))
        let report = LibraryCheck.run(items)
        let found = codes(report)
        #expect(found.contains(.trackDuplicate))
        #expect(found.contains(.trackGap))
        #expect(found.contains(.trackTotalMissing))
        #expect(found.contains(.trackExceedsTotal))
        #expect(found.contains(.trackMissing))
        let gap = report.findings.first { $0.code == .trackGap }
        // Erwartet 1…5 (höchste Nummer), vorhanden 1, 1, 5 → 2, 3, 4 fehlen.
        #expect(gap?.message == "missing 2, 3, 4")
        let missing = report.findings.first { $0.code == .trackMissing }
        #expect(missing?.files == ["/lib/album/04.mp3"])
        #expect(report.summary.first { $0.code == .trackDuplicate }?.files == 2)
    }

    @Test("Tracknummern: getrennte TRACKTOTAL-Felder (Vorbis) zählen als Gesamtzahl")
    func separateTotalFields() {
        var items = cleanAlbum()
        for index in items.indices {
            items[index].properties.removeAll { $0.key == "TRACKNUMBER" }
            items[index].properties.append(TagProperty(key: "TRACKNUMBER", value: "\(index + 1)"))
            items[index].properties.append(TagProperty(key: "TRACKTOTAL", value: "3"))
        }
        #expect(!codes(LibraryCheck.run(items)).contains(.trackTotalMissing))
    }

    @Test("Disc-Nummern: Lücke, fehlende Gesamtzahl, Disc > Gesamt; Tracks je Disc getrennt")
    func discNumberRules() {
        var items = cleanAlbum()
        items[0].properties.append(TagProperty(key: "DISCNUMBER", value: "1/2"))
        items[1].properties.append(TagProperty(key: "DISCNUMBER", value: "3/2"))   // größer als Gesamt
        items[2].properties.append(TagProperty(key: "DISCNUMBER", value: "1"))     // ohne Gesamtzahl
        // Track 1 auf Disc 1 und Track 1 auf Disc 3: keine Dublette.
        items[1].properties.removeAll { $0.key == "TRACKNUMBER" }
        items[1].properties.append(TagProperty(key: "TRACKNUMBER", value: "1/1"))
        let report = LibraryCheck.run(items)
        let found = codes(report)
        #expect(found.contains(.discGap))
        #expect(found.contains(.discTotalMissing))
        #expect(found.contains(.discExceedsTotal))
        #expect(!found.contains(.trackDuplicate))
        #expect(report.findings.first { $0.code == .discGap }?.message == "missing 2")
        // Ohne DISCNUMBER gibt es keine Disc-Befunde (einfaches Album).
        #expect(!codes(LibraryCheck.run(cleanAlbum())).contains(.discGap))
    }

    @Test("Album-Interpret: verschiedene Schreibweisen bleiben eine Gruppe und fallen auf")
    func albumArtistInconsistent() {
        var items = cleanAlbum()
        items[1].properties.removeAll { $0.key == "ALBUMARTIST" }
        items[1].properties.append(TagProperty(key: "ALBUMARTIST", value: " duo"))
        let report = LibraryCheck.run(items)
        #expect(report.groups.count == 1)
        let finding = report.findings.first { $0.code == .albumArtistInconsistent }
        #expect(finding?.files.count == 3)
        // Randleerzeichen sind schon beim Lesen weg; die Kleinschreibung bleibt sichtbar.
        #expect(finding?.message == "2× Duo, 1× duo")
    }

    @Test("Compilation ohne ALBUMARTIST bei mehreren Interpreten")
    func albumArtistMissingOnCompilation() {
        var items = cleanAlbum()
        for index in items.indices {
            items[index].properties.removeAll { $0.key == "ALBUMARTIST" }
        }
        // Ein Interpret überall: kein Befund.
        #expect(!codes(LibraryCheck.run(items)).contains(.albumArtistMissing))
        items[2].properties.removeAll { $0.key == "ARTIST" }
        items[2].properties.append(TagProperty(key: "ARTIST", value: "Trio"))
        let report = LibraryCheck.run(items)
        #expect(report.findings.first { $0.code == .albumArtistMissing }?.message == "2 different artists")
        #expect(report.groups.map(\.label) == ["Kind of Blue"])
    }

    @Test("Jahr, Genre und Album-Schreibweise innerhalb eines Albums")
    func dateGenreAlbumSpelling() {
        var items = cleanAlbum()
        items[0].properties.removeAll { $0.key == "DATE" }
        items[0].properties.append(TagProperty(key: "DATE", value: "1959-08-17"))
        items[1].properties.removeAll { $0.key == "GENRE" }
        items[1].properties.append(TagProperty(key: "GENRE", value: "Jazz"))
        items[1].properties.append(TagProperty(key: "GENRE", value: "Bebop"))
        items[2].properties.removeAll { $0.key == "ALBUM" }
        items[2].properties.append(TagProperty(key: "ALBUM", value: "Kind Of Blue "))
        let report = LibraryCheck.run(items)
        let found = codes(report)
        #expect(found.contains(.dateInconsistent))
        #expect(found.contains(.genreInconsistent))
        #expect(found.contains(.albumTitleInconsistent))
        #expect(report.findings.first { $0.code == .genreInconsistent }?.severity == .hint)
        #expect(report.findings.first { $0.code == .albumTitleInconsistent }?.message == "2× Kind of Blue, 1× Kind Of Blue")
        // Trotz Schreibvarianten eine Gruppe; das Label trägt die häufigste Form.
        #expect(report.groups.map(\.label) == ["Kind of Blue — Duo"])
    }

    @Test("Cover: fehlend (Warnung), uneinheitlich (Hinweis), Formate ohne Cover-Speicherort still")
    func coverRules() {
        var items = cleanAlbum()
        items[0].covers = []
        items[1].covers = [png300]
        items.append(audio("mod.mod", ["TITLE": "Modul", "ARTIST": "Duo", "ALBUM": "Kind of Blue",
                                        "ALBUMARTIST": "Duo", "TRACKNUMBER": "4/4", "DATE": "1959",
                                        "GENRE": "Jazz"], covers: nil))
        let report = LibraryCheck.run(items)
        let missing = report.findings.first { $0.code == .missingCover }
        #expect(missing?.files == ["/lib/album/01.mp3"])
        let inconsistent = report.findings.first { $0.code == .coverInconsistent }
        #expect(inconsistent?.severity == .hint)
        #expect(inconsistent?.files == ["/lib/album/02.mp3", "/lib/album/03.mp3"])
        #expect(inconsistent?.message == "1× image/jpeg 500×500, 1× image/png 300×300")
        // Gesamtzahl 4/4 mit Tracks 1…4 vorhanden: keine Lücke durch die Modul-Datei.
        #expect(!codes(report).contains(.trackGap))
    }

    @Test("Leere Pflichtfelder je Datei; ohne ALBUM zählt der Ordner als Gruppe")
    func emptyRequiredFields() {
        let items = [
            audio("a.mp3", folder: "/lib/loose", ["TITLE": "", "ARTIST": " ", "TRACKNUMBER": "1/2"], covers: [jpeg500]),
            audio("b.mp3", folder: "/lib/loose", ["TITLE": "B", "ARTIST": "X", "TRACKNUMBER": "2/2"], covers: [jpeg500]),
        ]
        let report = LibraryCheck.run(items)
        #expect(report.groups.map(\.label) == ["/lib/loose"])
        let byCode = Dictionary(grouping: report.findings, by: \.code)
        #expect(byCode[.emptyTitle]?.flatMap(\.files) == ["/lib/loose/a.mp3"])
        #expect(byCode[.emptyArtist]?.flatMap(\.files) == ["/lib/loose/a.mp3"])
        #expect(byCode[.emptyAlbum]?.flatMap(\.files) == ["/lib/loose/a.mp3", "/lib/loose/b.mp3"])
        #expect(report.files.first { $0.file == "/lib/loose/a.mp3" }?.codes
                == [.emptyTitle, .emptyArtist, .emptyAlbum])
    }

    @Test("Doppelte Titel: gleicher Titel + Interpret und Dauer ±2 s über alle Gruppen")
    func duplicateTitles() {
        let items = [
            audio("a.mp3", folder: "/lib/one", ["TITLE": "So What", "ARTIST": "Miles Davis", "ALBUM": "A",
                                                  "TRACKNUMBER": "1/1"], covers: [jpeg500], duration: 562_000),
            audio("b.mp3", folder: "/lib/two", ["TITLE": "so what ", "ARTIST": "MILES DAVIS", "ALBUM": "B",
                                                  "TRACKNUMBER": "1/1"], covers: [jpeg500], duration: 563_900),
            audio("c.mp3", folder: "/lib/three", ["TITLE": "So What", "ARTIST": "Miles Davis", "ALBUM": "C",
                                                    "TRACKNUMBER": "1/1"], covers: [jpeg500], duration: 570_000),
            audio("d.mp3", folder: "/lib/four", ["TITLE": "So What", "ARTIST": "Miles Davis", "ALBUM": "D",
                                                   "TRACKNUMBER": "1/1"], covers: [jpeg500], duration: nil),
        ]
        let report = LibraryCheck.run(items)
        let duplicates = report.findings.filter { $0.code == .duplicateTitle }
        #expect(duplicates.count == 1)
        #expect(duplicates.first?.files == ["/lib/one/a.mp3", "/lib/two/b.mp3"])
        #expect(duplicates.first?.group == "")
        #expect(report.plainText().contains("== Across all files"))
    }

    @Test("Dateinamen-Muster: nur mit Muster, Abweichung nennt den erwarteten Namen")
    func filenamePattern() throws {
        let items = [
            audio("01 - Track 1.mp3", ["TITLE": "Track 1", "ARTIST": "Duo", "ALBUM": "A",
                                       "ALBUMARTIST": "Duo", "TRACKNUMBER": "1/2"], covers: [jpeg500]),
            audio("zwei.mp3", ["TITLE": "Track 2", "ARTIST": "Duo", "ALBUM": "A",
                               "ALBUMARTIST": "Duo", "TRACKNUMBER": "2/2"], covers: [jpeg500]),
        ]
        #expect(!codes(LibraryCheck.run(items)).contains(.filenameMismatch))
        let pattern = try FilenamePattern("%{track:2} - %{title}")
        let report = LibraryCheck.run(items, pattern: pattern)
        let mismatch = report.findings.filter { $0.code == .filenameMismatch }
        #expect(mismatch.map(\.files) == [["/lib/album/zwei.mp3"]])
        #expect(mismatch.first?.message == "expected 02 - Track 2.mp3")
    }

    @Test("Bilder, E-Books und Dokumente: nur Titel leer und E-Book ohne Cover")
    func otherKinds() {
        let items = [
            LibraryCheck.Item(url: URL(fileURLWithPath: "/pics/a.jpg"), image: ImageCoreFields()),
            LibraryCheck.Item(url: URL(fileURLWithPath: "/books/b.epub"),
                              ebook: EbookCoreFields(title: "", authors: []), hasCover: false),
            LibraryCheck.Item(url: URL(fileURLWithPath: "/books/c.pdf"),
                              ebook: EbookCoreFields(title: "C", authors: []), hasCover: nil),
            LibraryCheck.Item(url: URL(fileURLWithPath: "/docs/d.docx"), document: DocumentCoreFields(title: "D")),
        ]
        let report = LibraryCheck.run(items)
        let byCode = Dictionary(grouping: report.findings, by: \.code)
        #expect(byCode[.emptyTitle]?.flatMap(\.files) == ["/pics/a.jpg", "/books/b.epub"])
        #expect(byCode[.missingCover]?.flatMap(\.files) == ["/books/b.epub"])
        #expect(byCode.keys.count == 2)
        #expect(report.groups.map(\.label) == ["/pics", "/books", "/docs"])
    }

    @Test("Unlesbare Datei wird gemeldet, der Rest weiter geprüft")
    func unreadableItem() {
        var items = cleanAlbum()
        items.append(LibraryCheck.Item(url: URL(fileURLWithPath: "/lib/album/broken.mp3"), kind: .audio,
                                       readError: "Cannot read file"))
        let report = LibraryCheck.run(items)
        #expect(codes(report) == [.unreadable])
        #expect(report.checkedFiles == 4)
        #expect(report.findings.first?.message == "Cannot read file")
    }

    @Test("Filter auf Regeln und JSON-Roundtrip des Berichts")
    func filterAndJSON() throws {
        var items = cleanAlbum()
        items[0].covers = []
        items[0].properties.removeAll { $0.key == "TITLE" }
        let report = LibraryCheck.run(items)
        #expect(Set(codes(report)) == [.missingCover, .emptyTitle])
        let filtered = report.filtered(to: [.emptyTitle])
        #expect(codes(filtered) == [.emptyTitle])
        #expect(filtered.summary.map(\.code) == [.emptyTitle])
        #expect(filtered.hasFindings(atLeast: .warning))
        #expect(!report.filtered(to: [.genreInconsistent]).hasFindings(atLeast: .hint))

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(LibraryCheck.Report.self, from: data)
        #expect(decoded == report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"missing-cover\""))
        #expect(json.contains("\"warning\""))
    }

    @Test("Severity ist vergleichbar: hint < warning")
    func severityOrder() {
        #expect(LibraryCheck.Severity.hint < .warning)
        #expect(LibraryCheck.RuleCode.coverInconsistent.severity == .hint)
        #expect(LibraryCheck.RuleCode.missingCover.severity == .warning)
    }

    @Test("Bildgröße aus PNG-/GIF-/BMP-Kopf ohne Dekodierung")
    func pixelSizeSynthetic() {
        // PNG: Signatur + IHDR-Länge + "IHDR" + Breite 640 + Höhe 480.
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
        png += Data([0, 0, 0x02, 0x80, 0, 0, 0x01, 0xE0, 8, 6, 0, 0, 0])
        #expect(ImagePixelSize.read(from: png)?.width == 640)
        #expect(ImagePixelSize.read(from: png)?.height == 480)
        var gif = Data("GIF89a".utf8)
        gif += Data([0x20, 0x01, 0x10, 0x00, 0, 0, 0, 0])
        #expect(ImagePixelSize.read(from: gif)?.width == 288)
        #expect(ImagePixelSize.read(from: gif)?.height == 16)
        var bmp = Data([0x42, 0x4D]) + Data(repeating: 0, count: 16)
        bmp += Data([0x0A, 0, 0, 0]) + Data([0xF6, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 4)
        #expect(ImagePixelSize.read(from: bmp)?.width == 10)
        #expect(ImagePixelSize.read(from: bmp)?.height == 10) // negative Höhe = Betrag
        #expect(ImagePixelSize.read(from: Data("kein Bild, wirklich nicht".utf8)) == nil)
    }
}

/// Lauf über echte Dateien: Fixture-Kopien bekommen gezielt Tags über den
/// regulären Schreibweg; geprüft wird über `Item.load` (Leseweg samt
/// Cover-Größe aus den Bilddaten).
@Suite("LibraryCheck auf Fixtures", .serialized)
struct LibraryCheckFixtureTests {

    private func makeAlbum() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func copy(_ fixture: String, to directory: URL, as name: String,
                      _ fields: [String: String], cover: Data? = nil) throws -> URL {
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent(fixture), to: target)
        let properties = fields.sorted { $0.key < $1.key }.map { TagProperty(key: $0.key, value: $0.value) }
        try TagFile.write(properties: properties,
                          artworks: cover.map { [Artwork(data: $0, pictureType: "Front Cover")] } ?? [],
                          to: target)
        return target
    }

    @Test("Album aus Fixture-Kopien: Cover-Größe aus den Bilddaten, Lücke, Album-Interpret, Muster")
    func fixtureAlbum() throws {
        let directory = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try Fixtures.coverData("cover.jpg")
        let png = try Fixtures.coverData("cover.png")
        let base = ["ARTIST": "Duo", "ALBUM": "Fixture Album", "ALBUMARTIST": "Duo", "DATE": "2020"]
        let first = try copy("sample.mp3", to: directory, as: "01 - Eins.mp3",
                             base.merging(["TITLE": "Eins", "TRACKNUMBER": "1/3"]) { $1 }, cover: jpeg)
        let second = try copy("sample.flac", to: directory, as: "03 - Drei.flac",
                              base.merging(["TITLE": "Drei", "TRACKNUMBER": "3/3", "ALBUMARTIST": "duo"]) { $1 },
                              cover: png)
        let third = try copy("sample.m4a", to: directory, as: "vier.m4a",
                             base.merging(["TITLE": "", "TRACKNUMBER": "4/3"]) { $1 })

        let items = MediaFormats.expandMediaFiles([directory]).compactMap(LibraryCheck.Item.load)
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.readError == nil })
        // Cover-Größe kommt aus den Bilddaten (Fixtures sind 64×64).
        let firstItem = try #require(items.first { $0.url.lastPathComponent == first.lastPathComponent })
        #expect(firstItem.covers?.first?.width == 64)
        #expect(firstItem.covers?.first?.mimeType == "image/jpeg")
        #expect(firstItem.durationMilliseconds ?? 0 > 1000)

        let report = LibraryCheck.run(items, pattern: try FilenamePattern("%{track:2} - %{title}"))
        let byCode = Dictionary(grouping: report.findings, by: \.code)
        #expect(byCode[.missingCover]?.flatMap(\.files) == [third.path])
        #expect(byCode[.coverInconsistent]?.first?.files == [first.path, second.path])
        #expect(byCode[.albumArtistInconsistent] != nil)
        #expect(byCode[.trackGap]?.first?.message == "missing 2")
        #expect(byCode[.trackExceedsTotal]?.flatMap(\.files) == [third.path])
        #expect(byCode[.emptyTitle]?.flatMap(\.files) == [third.path])
        // Dateiname: "vier.m4a" passt nicht, die beiden anderen schon.
        #expect(byCode[.filenameMismatch]?.flatMap(\.files) == [third.path])
        #expect(byCode[.dateInconsistent] == nil)
        #expect(report.groups.count == 1)
    }

    @Test("E-Book-Fixture mit Cover und Titel: kein Befund; Playlist und Rechnung werden ausgelassen")
    func fixtureEbookAndSkippedKinds() throws {
        let directory = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: directory) }
        let epub = directory.appendingPathComponent("buch.epub")
        try FileManager.default.copyItem(at: Fixtures.directory.appendingPathComponent("book2.epub"), to: epub)
        let playlist = directory.appendingPathComponent("liste.m3u")
        try Data("#EXTM3U\nbuch.epub\n".utf8).write(to: playlist)

        let items = MediaFormats.expandMediaFiles([directory]).compactMap(LibraryCheck.Item.load)
        #expect(items.map(\.url.lastPathComponent) == ["buch.epub"])
        #expect(items.first?.covers == [LibraryCheck.CoverSummary(mimeType: "", bytes: 0)])
        #expect(LibraryCheck.run(items).findings.isEmpty)
    }
}

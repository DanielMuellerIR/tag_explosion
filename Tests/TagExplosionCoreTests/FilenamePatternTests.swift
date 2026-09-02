// Muster-Engine und Umbenennungsplan: reine Funktionen, deshalb ohne
// Mediendateien prüfbar. Die Umbenennung selbst läuft gegen leere Dateien in
// einem Temp-Ordner — der Inhalt spielt für `moveItem` keine Rolle.
import Foundation
import Testing
@testable import TagExplosionCore

@Suite("Dateinamen-Muster")
struct FilenamePatternTests {

    @Test("Kurznamen, Breite und Custom-Keys werden erkannt")
    func parsesAliasesWidthAndCustomKeys() throws {
        let pattern = try FilenamePattern("%{track:2} - %{artist} - %{title} [%{isrc}]")
        #expect(pattern.placeholders.map(\.key) == ["TRACKNUMBER", "ARTIST", "TITLE", "ISRC"])
        #expect(pattern.placeholders[0].width == 2)
        #expect(pattern.placeholders[1].width == nil)
        #expect(pattern.placeholders[0].isNumeric)
        #expect(!pattern.placeholders[1].isNumeric)
    }

    @Test("Kaputte Muster werden mit sprechendem Fehler abgelehnt")
    func rejectsBrokenPatterns() {
        #expect(throws: FilenamePattern.ParseError.unbalancedBraces) {
            try FilenamePattern("%{artist - %{title}")
        }
        #expect(throws: FilenamePattern.ParseError.emptyPlaceholder) {
            try FilenamePattern("%{} - %{title}")
        }
        #expect(throws: FilenamePattern.ParseError.invalidWidth("x")) {
            try FilenamePattern("%{track:x}")
        }
        #expect(throws: FilenamePattern.ParseError.containsPathSeparator) {
            try FilenamePattern("%{artist}/%{title}")
        }
        #expect(throws: FilenamePattern.ParseError.noPlaceholder) {
            try FilenamePattern("nur text")
        }
    }

    @Test("Tags → Name: Nullen, Jahr aus Datum, Endung bleibt, Sonderzeichen entschärft")
    func rendersFileName() throws {
        let pattern = try FilenamePattern("%{track:2} %{artist} - %{title} (%{year})")
        let fields = [
            "TRACKNUMBER": "3/12",
            "ARTIST": "AC/DC",
            "TITLE": "Back: In\u{0007} Black",
            "DATE": "1980-07-25",
        ]
        #expect(pattern.renderFileName(fields: fields, extension: "MP3")
                == "03 AC-DC - Back- In Black (1980).MP3")
    }

    @Test("Leere Felder ziehen keine doppelten Leerzeichen nach sich; Punkt vorn fällt weg")
    func rendersWithMissingFields() throws {
        let pattern = try FilenamePattern("%{track:2} %{artist} - %{title}")
        #expect(pattern.renderFileName(fields: ["TITLE": "Intro"], extension: "flac")
                == "- Intro.flac")
        #expect(pattern.renderFileName(fields: [:], extension: "flac") == "-.flac")
        let onlyFields = try FilenamePattern("%{artist}%{title}")
        #expect(onlyFields.renderFileName(fields: [:], extension: "flac") == "")
        #expect(onlyFields.renderFileName(fields: ["TITLE": ".versteckt"], extension: "flac")
                == "versteckt.flac")
    }

    @Test("Zu lange Namen werden auf 255 Bytes gekürzt, die Endung bleibt")
    func truncatesLongNames() throws {
        let pattern = try FilenamePattern("%{title}")
        let long = String(repeating: "ä", count: 300) // 2 Bytes je Zeichen
        let name = pattern.renderFileName(fields: ["TITLE": long], extension: "opus")
        #expect(name.utf8.count <= FilenamePattern.maxNameBytes)
        #expect(name.hasSuffix(".opus"))
        #expect(name.count > 100)
    }

    @Test("Prozentzeichen und unbekannte %-Folgen bleiben wörtlich")
    func keepsLiteralPercent() throws {
        let pattern = try FilenamePattern("100%% %{title} 50%")
        #expect(pattern.renderStem(fields: ["TITLE": "x"]) == "100% x 50%")
    }

    @Test("Name → Tags: Trennzeichen wörtlich, Zahlen ohne führende Nullen")
    func extractsFieldsFromFileName() throws {
        let pattern = try FilenamePattern("%{track:2} - %{artist} - %{title}")
        let fields = pattern.extract(fromFileName: "07 - Miles Davis - So What.flac")
        #expect(fields == ["TRACKNUMBER": "7", "ARTIST": "Miles Davis", "TITLE": "So What"])
        // Der Bindestrich im Titel gehört zum letzten Feld (nicht-gierig davor).
        let dashed = pattern.extract(fromFileName: "01 - A - B - C.mp3")
        #expect(dashed == ["TRACKNUMBER": "1", "ARTIST": "A", "TITLE": "B - C"])
    }

    @Test("Name → Tags: Jahr ist vierstellig, Nichtpassendes liefert nil")
    func extractsYearAndRejectsMismatch() throws {
        let pattern = try FilenamePattern("%{artist} (%{year}) %{title}")
        #expect(pattern.extract(fromStem: "Kraftwerk (1978) Die Roboter")
                == ["ARTIST": "Kraftwerk", "DATE": "1978", "TITLE": "Die Roboter"])
        #expect(pattern.extract(fromStem: "Kraftwerk (78) Die Roboter") == nil)
        #expect(pattern.extract(fromStem: "ohne klammern") == nil)
        // Regex-Sonderzeichen im Muster sind wörtlich gemeint.
        let dotted = try FilenamePattern("%{track}. %{title}")
        #expect(dotted.extract(fromStem: "2. Titel") == ["TRACKNUMBER": "2", "TITLE": "Titel"])
        #expect(dotted.extract(fromStem: "2x Titel") == nil)
    }

    @Test("Roundtrip: gerenderter Name lässt sich mit demselben Muster wieder lesen")
    func roundTripsThroughFileName() throws {
        let pattern = try FilenamePattern("%{disc}-%{track:2} %{title}")
        let fields = ["DISCNUMBER": "2", "TRACKNUMBER": "5", "TITLE": "Stück"]
        let name = pattern.renderFileName(fields: fields, extension: "m4a")
        #expect(name == "2-05 Stück.m4a")
        #expect(pattern.extract(fromFileName: name) == fields)
    }

    @Test("Bild- und E-Book-Felder kennen Synonyme; fremde Schlüssel werden abgelehnt")
    func mapsImageAndEbookFields() throws {
        let image = ImageCoreFields(title: "Strand", keywords: ["Meer", "Sand"],
                                    creator: "Anna", dateTimeOriginal: "2022:08:01 10:00:00")
        let imageFields = PatternFields.fields(from: image)
        #expect(imageFields["ARTIST"] == "Anna")
        #expect(imageFields["KEYWORDS"] == "Meer, Sand")
        let pattern = try FilenamePattern("%{year} %{artist} %{title}")
        #expect(pattern.renderStem(fields: imageFields) == "2022 Anna Strand")

        var parsedImage = ImageCoreFields()
        try PatternFields.apply(["ARTIST": "Ben", "TITLE": "Berg", "DATE": "2020"], to: &parsedImage)
        #expect(parsedImage.creator == "Ben")
        #expect(parsedImage.title == "Berg")
        #expect(parsedImage.dateTimeOriginal == "2020")
        #expect(throws: PatternFields.ApplyError.unsupportedField(key: "ALBUM", kind: "image")) {
            try PatternFields.apply(["ALBUM": "x"], to: &parsedImage)
        }

        let ebook = EbookCoreFields(title: "Dune", authors: ["Frank Herbert"],
                                    series: "Dune", seriesIndex: "1", date: "1965")
        let ebookFields = PatternFields.fields(from: ebook)
        let ebookPattern = try FilenamePattern("%{author} - %{series} %{track:2} - %{title}")
        #expect(ebookPattern.renderStem(fields: ebookFields) == "Frank Herbert - Dune 01 - Dune")

        var parsedEbook = EbookCoreFields()
        try PatternFields.apply(["AUTHOR": "A, B", "SERIESINDEX": "3", "GENRE": "SF"], to: &parsedEbook)
        #expect(parsedEbook.authors == ["A", "B"])
        #expect(parsedEbook.seriesIndex == "3")
        #expect(parsedEbook.subjects == ["SF"])
    }

    @Test("Audio: geparste Werte ersetzen genau ihren Schlüssel, leere löschen")
    func appliesParsedValuesToProperties() {
        var properties = [
            TagProperty(key: "TITLE", value: "alt"),
            TagProperty(key: "GENRE", value: "Jazz"),
            TagProperty(key: "GENRE", value: "Bebop"),
        ]
        PatternFields.apply(["TITLE": "neu", "ARTIST": "Miles", "GENRE": ""], to: &properties)
        #expect(properties == [
            TagProperty(key: "ARTIST", value: "Miles"),
            TagProperty(key: "TITLE", value: "neu"),
        ])
    }
}

@Suite("Umbenennungsplan", .serialized)
struct FileRenamerTests {

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func touch(_ url: URL) throws {
        try Data("x".utf8).write(to: url)
    }

    @Test("Plan meldet doppelte Ziele, belegte Ziele, leere Namen und Unverändertes")
    func planDetectsConflicts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.mp3")
        let b = directory.appendingPathComponent("b.mp3")
        let c = directory.appendingPathComponent("c.mp3")
        let d = directory.appendingPathComponent("Song.mp3")
        let e = directory.appendingPathComponent("e.mp3")
        for url in [a, b, c, d, e] { try touch(url) }

        let pattern = try FilenamePattern("%{title}")
        let plan = FileRenamer.plan([
            .init(url: d, fields: ["TITLE": "Song"]),      // unverändert, belegt den Namen
            .init(url: a, fields: ["TITLE": "Song"]),      // gleiches Ziel wie d
            .init(url: b, fields: ["TITLE": "Neu"]),       // frei
            .init(url: c, fields: ["TITLE": "neu"]),       // gleiches Ziel wie b (Schreibweise)
            .init(url: e, fields: [:]),                    // leerer Name
        ], pattern: pattern)

        #expect(plan.hasConflicts)
        let caseSensitive = FileRenamer.isCaseSensitive(directory: directory)
        #expect(plan.items.map(\.status)
                == [.unchanged, .conflict, .rename, caseSensitive ? .rename : .conflict, .conflict])
        #expect(plan.items[1].reason?.contains("Same target") == true)
        #expect(plan.items[4].reason?.contains("empty") == true)

        // Ziel existiert schon als andere Datei.
        let occupied = FileRenamer.plan([.init(url: a, fields: ["TITLE": "e"])], pattern: pattern)
        #expect(occupied.items[0].status == .conflict)
        #expect(occupied.items[0].reason?.contains("already exists") == true)
        #expect(throws: FileRenamer.RenameError.planHasConflicts) {
            try FileRenamer.apply(plan)
        }
        // Nichts wurde angefasst.
        for url in [a, b, c, d, e] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("Zwei Dateien mit nur anders geschriebenem Ziel kollidieren auf case-insensitivem Volume")
    func caseOnlyDuplicatesCollideOnCaseInsensitiveVolume() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.mp3")
        let b = directory.appendingPathComponent("b.mp3")
        try touch(a); try touch(b)
        let pattern = try FilenamePattern("%{title}")
        let plan = FileRenamer.plan([
            .init(url: a, fields: ["TITLE": "song"]),
            .init(url: b, fields: ["TITLE": "SONG"]),
        ], pattern: pattern)
        if FileRenamer.isCaseSensitive(directory: directory) {
            #expect(!plan.hasConflicts)
        } else {
            #expect(plan.items[1].status == .conflict)
        }
    }

    @Test("Ausführen benennt um, auch nur die Schreibweise; Ziel wird nie überschrieben")
    func applyRenamesWithinFolder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("01 alt.mp3")
        let second = directory.appendingPathComponent("song.mp3")
        try Data("erster Inhalt".utf8).write(to: first)
        try Data("zweiter Inhalt".utf8).write(to: second)
        let stampBefore = try #require(FileStamp.current(of: first))

        let pattern = try FilenamePattern("%{track:2} %{title}")
        let plan = FileRenamer.plan([
            .init(url: first, fields: ["TRACKNUMBER": "1", "TITLE": "Neu"]),
            .init(url: second, fields: ["TRACKNUMBER": "2", "TITLE": "Song"]),
        ], pattern: pattern)
        #expect(!plan.hasConflicts)
        #expect(plan.items.map(\.target) == ["01 Neu.mp3", "02 Song.mp3"])

        let outcomes = try FileRenamer.apply(plan)
        #expect(outcomes.allSatisfy { $0.succeeded })
        let renamedFirst = directory.appendingPathComponent("01 Neu.mp3")
        #expect(try Data(contentsOf: renamedFirst) == Data("erster Inhalt".utf8))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        // Umbenennen lässt Inode und Änderungszeit in Ruhe: Ein offener
        // Editor kann seinen Stempel behalten.
        let stampAfter = try #require(FileStamp.current(of: renamedFirst))
        #expect(stampAfter.hasSameFileIdentity(as: stampBefore))
        #expect(stampAfter.modified == stampBefore.modified)

        // Nur die Schreibweise ändern (song → Song) ist kein Konflikt.
        let renamedSecond = directory.appendingPathComponent("02 Song.mp3")
        let casePlan = FileRenamer.plan(
            [.init(url: renamedSecond, fields: ["TRACKNUMBER": "2", "TITLE": "SONG"])],
            pattern: pattern)
        #expect(casePlan.items[0].status == .rename)
        let caseOutcome = try FileRenamer.apply(casePlan)
        #expect(caseOutcome[0].succeeded, "\(caseOutcome[0].error ?? "")")
        let listing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listing.contains("02 SONG.mp3"))
    }
}

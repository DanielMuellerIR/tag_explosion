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
        #expect(onlyFields.renderFileName(fields: ["TITLE": ". .versteckt"], extension: "flac")
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

    @Test("Ungültige Musterfelder lassen sämtliche bisherigen Werte unverändert")
    func invalidFieldsLeaveBuffersUnchanged() {
        let parsed = ["TITLE": "Neu", "ZZZ": "unbekannt"]
        var image = ImageCoreFields(title: "Alt")
        let originalImage = image
        #expect(throws: PatternFields.ApplyError.self) { try PatternFields.apply(parsed, to: &image) }
        #expect(image == originalImage)
        var ebook = EbookCoreFields(title: "Alt")
        let originalEbook = ebook
        #expect(throws: PatternFields.ApplyError.self) { try PatternFields.apply(parsed, to: &ebook) }
        #expect(ebook == originalEbook)
        var document = DocumentCoreFields()
        document.title = "Alt"
        let originalDocument = document
        #expect(throws: PatternFields.ApplyError.self) { try PatternFields.apply(parsed, to: &document) }
        #expect(document == originalDocument)
        var nfo = NFOFields()
        nfo.title = "Alt"
        let originalNFO = nfo
        #expect(throws: PatternFields.ApplyError.self) { try PatternFields.apply(parsed, to: &nfo) }
        #expect(nfo == originalNFO)
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

    @Test("XMP-Sidecar eines Bildes wandert mit; belegtes Sidecar-Ziel ist ein Konflikt")
    func sidecarFollowsImageRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("IMG_1.nef")
        let sidecar = directory.appendingPathComponent("IMG_1.xmp")
        let jpg = directory.appendingPathComponent("IMG_1.jpg")   // teilt sich die Sidecar
        let lone = directory.appendingPathComponent("notiz.xmp")  // .xmp als eigenes Format
        let audio = directory.appendingPathComponent("song.mp3")
        for url in [raw, sidecar, jpg, lone, audio] { try touch(url) }
        let pattern = try FilenamePattern("%{title}")

        let plan = FileRenamer.plan([
            .init(url: raw, fields: ["TITLE": "Strand"]),
            .init(url: jpg, fields: ["TITLE": "Strand"]),
            .init(url: lone, fields: ["TITLE": "Notiz"]),
            .init(url: audio, fields: ["TITLE": "Lied"]),
        ], pattern: pattern)
        #expect(!plan.hasConflicts)
        #expect(plan.items[0].sidecarSource == sidecar.path)
        #expect(plan.items[0].sidecarTarget == "Strand.xmp")
        // Das JPEG derselben Aufnahme nimmt die Sidecar nicht ein zweites Mal
        // mit — gleicher Zielname, also kein Konflikt.
        #expect(plan.items[1].status == .rename && plan.items[1].sidecarSource == nil)
        // Eine .xmp selbst und Audio kennen keine Sidecar.
        #expect(plan.items[2].sidecarSource == nil && plan.items[3].sidecarSource == nil)

        let outcomes = try FileRenamer.apply(plan)
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(outcomes[0].sidecarTarget == directory.appendingPathComponent("Strand.xmp").path)
        #expect(outcomes[1].sidecarTarget == outcomes[0].sidecarTarget)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Strand.nef").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Strand.xmp").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Notiz.xmp").path))
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("Ein gescheiterter XMP-Umzug blockiert auch die zweite Datei des RAW-JPEG-Paars")
    func sharedSidecarFailureBlocksDependentRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("IMG_1.nef")
        let jpg = directory.appendingPathComponent("IMG_1.jpg")
        let xmp = directory.appendingPathComponent("IMG_1.xmp")
        for url in [raw, jpg, xmp] { try touch(url) }
        let plan = FileRenamer.plan([raw, jpg].map { .init(url: $0, fields: ["TITLE": "Neu"]) },
                                    pattern: try FilenamePattern("%{title}"))
        try FileManager.default.removeItem(at: raw)
        let outcomes = try FileRenamer.apply(plan, journal: BackupJournal(url: directory.appendingPathComponent("journal.json")))
        #expect(outcomes.count == 2)
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(FileManager.default.fileExists(atPath: jpg.path))
        #expect(FileManager.default.fileExists(atPath: xmp.path))
    }

    @Test("MP4 nimmt NFO und LRC mit; ein belegtes zweites Sidecar-Ziel blockiert alles")
    func multipleSidecarsFollowRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["mp4", "nfo", "lrc"].map { directory.appendingPathComponent("Alt").appendingPathExtension($0) }
        for url in urls { try touch(url) }
        let targetLRC = directory.appendingPathComponent("Neu.lrc")
        try touch(targetLRC)
        let requests = [FileRenamer.Request(url: urls[0], fields: ["TITLE": "Neu"])]
        let pattern = try FilenamePattern("%{title}")
        #expect(FileRenamer.plan(requests, pattern: pattern).hasConflicts)
        try FileManager.default.removeItem(at: targetLRC)
        let journal = BackupJournal(url: directory.appendingPathComponent("journal.json"))
        let plan = FileRenamer.plan(requests, pattern: pattern)
        #expect(!plan.hasConflicts)
        #expect(plan.items[0].sidecarMoves.map(\.target) == ["Neu.nfo", "Neu.lrc"])
        // Der Vorschauplan bleibt auch als JSON vollständig ausführbar.
        let restored = try JSONDecoder().decode(FileRenamer.Plan.self, from: JSONEncoder().encode(plan))
        #expect(restored == plan)
        // Zwischen Vorschau und Ausführung verschwundene zweite Sidecar:
        // Die Vorprüfung muss Medium UND erste Sidecar unangetastet lassen.
        try FileManager.default.removeItem(at: urls[2])
        let blocked = try FileRenamer.apply(restored, journal: journal)
        #expect(blocked.first?.succeeded == false)
        for url in urls.prefix(2) { #expect(try Data(contentsOf: url) == Data("x".utf8)) }
        try touch(urls[2])
        let copy = directory.appendingPathComponent("backup.bin")
        try touch(copy)
        for url in urls { try journal.record(original: url, backup: copy, size: 1, reason: BackupReason.tags) }
        let outcomes = try FileRenamer.apply(restored, journal: journal)
        #expect(outcomes[0].sidecarTargets.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Neu.nfo", "Neu.lrc"])
        #expect(journal.rawEntries().allSatisfy { URL(fileURLWithPath: $0.originalPath).deletingPathExtension().lastPathComponent == "Neu" })
        #expect(outcomes.allSatisfy { $0.succeeded })
        for url in urls {
            #expect(!FileManager.default.fileExists(atPath: url.path))
            let target = directory.appendingPathComponent("Neu").appendingPathExtension(url.pathExtension)
            #expect(try Data(contentsOf: target) == Data("x".utf8))
        }
    }

    @Test("Fehler beim zweiten Sidecar-Umzug stellt vorherige Dateien wieder her", arguments: [false, true])
    func failedSecondSidecarRollsBack(rollbackFails: Bool) throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["mp4", "nfo", "lrc"].map { directory.appendingPathComponent("Alt").appendingPathExtension($0) }
        for url in urls { try touch(url) }
        let plan = FileRenamer.plan([.init(url: urls[0], fields: ["TITLE": "Neu"])],
                                    pattern: try FilenamePattern("%{title}"))
        enum MoveError: Error { case injected }
        let outcomes = try FileRenamer.apply(plan, journal: BackupJournal(url: directory.appendingPathComponent("journal.json"))) { source, target in
            if source == urls[2] || (rollbackFails && source.lastPathComponent == "Neu.nfo") {
                throw MoveError.injected
            }
            try FileManager.default.moveItem(at: source, to: target)
        }
        #expect(outcomes.first?.succeeded == false)
        // Ein fehlgeschlagener NFO-Rückweg darf den Rückweg des Mediums nicht verhindern.
        #expect(try Data(contentsOf: urls[0]) == Data("x".utf8))
        #expect(try Data(contentsOf: urls[2]) == Data("x".utf8))
        let nfo = rollbackFails ? directory.appendingPathComponent("Neu.nfo") : urls[1]
        #expect(try Data(contentsOf: nfo) == Data("x".utf8))
        if rollbackFails { #expect(outcomes[0].error?.contains(nfo.path) == true) }
    }

    @Test("Sidecar-Konflikte: belegtes Ziel, geteilte Sidecar mit zwei Namen, Zielname eines anderen Eintrags")
    func sidecarConflicts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("IMG_1.nef")
        let sidecar = directory.appendingPathComponent("IMG_1.xmp")
        let occupied = directory.appendingPathComponent("Strand.xmp")
        for url in [raw, sidecar, occupied] { try touch(url) }
        let pattern = try FilenamePattern("%{title}")

        // Sidecar-Ziel liegt schon auf der Platte → ganzer Eintrag Konflikt.
        let blocked = FileRenamer.plan([.init(url: raw, fields: ["TITLE": "Strand"])], pattern: pattern)
        #expect(blocked.items[0].status == .conflict)
        #expect(blocked.items[0].reason?.contains("sidecar") == true)
        #expect(throws: FileRenamer.RenameError.planHasConflicts) { try FileRenamer.apply(blocked) }
        #expect(FileManager.default.fileExists(atPath: raw.path) && FileManager.default.fileExists(atPath: sidecar.path))

        // Sidecar-Ziel kollidiert mit dem Ziel eines anderen Eintrags.
        let lone = directory.appendingPathComponent("notiz.xmp")
        try touch(lone)
        let clash = FileRenamer.plan([
            .init(url: lone, fields: ["TITLE": "Meer"]),
            .init(url: raw, fields: ["TITLE": "Meer"]),
        ], pattern: pattern)
        #expect(clash.items[0].status == .rename && clash.items[1].status == .conflict)

        // RAW+JPEG-Paar mit verschiedenen Zielnamen → die geteilte Sidecar
        // kann nur einen Namen bekommen.
        let jpg = directory.appendingPathComponent("IMG_1.jpg")
        try touch(jpg)
        let shared = FileRenamer.plan([
            .init(url: raw, fields: ["TITLE": "Meer"]),
            .init(url: jpg, fields: ["TITLE": "Küste"]),
        ], pattern: pattern)
        #expect(shared.items[0].status == .rename && shared.items[1].status == .conflict)
        #expect(shared.items[1].reason?.contains("shared") == true)
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


    @Test("LRC- und NFO-Sidecars wandern mit Audio bzw. Video; Journalpfade folgen")
    func audioAndVideoSidecarsFollowRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let flac = directory.appendingPathComponent("song.flac")
        let lrc = directory.appendingPathComponent("song.lrc")
        let mkv = directory.appendingPathComponent("film.mkv")
        let nfo = directory.appendingPathComponent("film.nfo")
        let lonely = directory.appendingPathComponent("solo.mp3")
        for url in [flac, lrc, mkv, nfo, lonely] { try touch(url) }
        let journal = BackupJournal(url: directory.appendingPathComponent("journal.json"))
        let copy = directory.appendingPathComponent("kopie.bin")
        try touch(copy)
        try journal.record(original: flac, backup: copy, size: 1, reason: BackupReason.tags)
        try journal.record(original: lrc, backup: copy, size: 1, reason: BackupReason.sidecar)

        let pattern = try FilenamePattern("%{title}")
        let plan = FileRenamer.plan([
            .init(url: flac, fields: ["TITLE": "Lied"]),
            // "Kino" statt "Film": Auf case-insensitiven Datenträgern gälte
            // `film.nfo` sonst weiter als vorhanden, weil `Film.nfo` da ist.
            .init(url: mkv, fields: ["TITLE": "Kino"]),
            .init(url: lonely, fields: ["TITLE": "Solo"]),
        ], pattern: pattern)
        #expect(!plan.hasConflicts)
        #expect(plan.items[0].sidecarSource == lrc.path && plan.items[0].sidecarTarget == "Lied.lrc")
        #expect(plan.items[1].sidecarSource == nfo.path && plan.items[1].sidecarTarget == "Kino.nfo")
        #expect(plan.items[2].sidecarSource == nil)

        let outcomes = try FileRenamer.apply(plan, journal: journal)
        #expect(outcomes.allSatisfy { $0.succeeded && $0.warning == nil })
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("Lied.lrc").path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("Kino.nfo").path))
        #expect(!fm.fileExists(atPath: lrc.path) && !fm.fileExists(atPath: nfo.path))
        // Historie: die Einträge zeigen jetzt auf die neuen Namen.
        let paths = journal.rawEntries().map(\.originalPath)
        let newFlac = directory.appendingPathComponent("Lied.flac")
        #expect(paths.contains(MediaFormats.canonicalFileURL(newFlac).path))
        #expect(paths.contains(MediaFormats.canonicalFileURL(directory.appendingPathComponent("Lied.lrc")).path))
        #expect(!paths.contains(MediaFormats.canonicalFileURL(flac).path))
        #expect(BackupHistory.versions(of: newFlac, journal: journal).count == 2)
    }
}

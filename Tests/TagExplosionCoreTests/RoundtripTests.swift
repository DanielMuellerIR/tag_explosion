// Roundtrip-Tests: Tags/Cover schreiben → neu öffnen → vergleichen.
// Die Fixtures werden bei Bedarf per generate_fixtures.sh (ffmpeg) erzeugt
// und pro Test in ein Temp-Verzeichnis kopiert, damit Tests einander nicht
// beeinflussen.
import Foundation
import Testing
@testable import TagExplosionCore

/// Erzeugt die Fixtures einmal pro Testlauf (ffmpeg, idempotent).
enum Fixtures {
    static let directory: URL = {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/generate_fixtures.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try! process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Fixture-Generierung fehlgeschlagen")
        let path = String(decoding: out, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }()

    /// Kopiert eine Fixture in ein frisches Temp-Verzeichnis (beschreibbar).
    static func workingCopy(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(name)
        let target = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    static func coverData(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }
}

/// Alle Formate, die der Roundtrip (Tags, Cover, Audio-Eigenschaften)
/// abdecken soll. mp2 läuft wie mp3 über ID3v2, aifc wie aiff.
let audioFormats = ["sample.mp3", "sample.mp2", "sample.m4a", "sample.m4b", "sample.flac",
                    "sample.ogg", "sample.opus", "sample.wav", "sample.aiff",
                    "sample.aifc", "sample.wv"]

/// Container, deren Tags TagLib schreiben kann, aber ohne Cover-Roundtrip:
/// Matroska (mkv/mka) liest ein geschriebenes Cover nicht zurück; 3gp/3g2
/// sind MP4-Container (Cover ginge), laufen hier aber als Container-Fall.
let containerFormats = ["sample.mp4", "sample.m4v", "sample.mkv", "sample.mka",
                        "sample.3gp", "sample.3g2"]

/// Tracker-Module: TagLib kennt nur Titel, Kommentar und Tracker-Namen.
/// Titel wie in der Fixture-Datei (`generate_fixtures.sh`).
let trackerFormats: [(file: String, title: String)] = [
    ("sample.mod", "Testmodul"), ("sample.xm", "Testmodul XM"),
    ("sample.s3m", "Testmodul S3M"), ("sample.it", "Testmodul IT"),
]

/// Formate ohne TagLib-Leser: nur Anzeige über mediainfo.
let displayOnlyFormats = ["sample.au", "sample.ogv"]

@Suite("Tag-Roundtrip", .serialized)
struct RoundtripTests {

    @Test("Parallele TagLib-Versionsabfragen sind threadsicher")
    func concurrentTagLibVersionReads() async {
        let versions = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<64 {
                group.addTask {
                    var version = ""
                    // Ein einzelner kurzer C-Aufruf überlappt auf schnellen
                    // Rechnern nicht zuverlässig. Viele Abfragen pro Task
                    // üben die gemeinsame C-Grenze tatsächlich parallel aus.
                    for _ in 0..<10_000 { version = TagFile.tagLibVersion }
                    return version
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(Set(versions).count == 1)
        #expect(versions.first?.isEmpty == false)
    }

    @Test("Parallele Audio-Öffnungen initialisieren TagLib threadsicher")
    func concurrentAudioOpens() async throws {
        let urls = try (0..<64).map { _ in
            try Fixtures.workingCopy("sample.mp3")
        }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for url in urls {
                group.addTask {
                    try TagFile.read(at: url).properties.count
                }
            }
            for try await propertyCount in group {
                #expect(propertyCount >= 0)
            }
        }
    }

    @Test("Properties schreiben und lesen", arguments: audioFormats)
    func propertiesRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let props = [
            TagProperty(key: "TITLE", value: "Tütensuppe № 5"),
            TagProperty(key: "ARTIST", value: "Die Testkapelle"),
            TagProperty(key: "ALBUM", value: "Größte Härte"),
            TagProperty(key: "TRACKNUMBER", value: "3"),
            TagProperty(key: "GENRE", value: "Elektro-Polka"),
            TagProperty(key: "COMMENT", value: "Umlaute äöü und Emoji 🎵"),
        ]
        try TagFile.write(properties: props, to: url)

        let readBack = try TagFile.read(at: url)
        for prop in props {
            #expect(readBack.values(for: prop.key).contains(prop.value),
                    "\(format): \(prop.key) fehlt oder falsch")
        }
    }

    @Test("Cover schreiben, lesen und entfernen", arguments: audioFormats)
    func coverRoundtrip(format: String) throws {
        // WAV/AIFF (ID3v2 in RIFF/AIFF) können auch Bilder; wenn TagLib das
        // für ein Format nicht unterstützt, schlägt der Test bewusst fehl,
        // damit wir es merken und dokumentieren.
        let url = try Fixtures.workingCopy(format)
        let cover = try Fixtures.coverData("cover.jpg")
        try TagFile.write(artworks: [Artwork(data: cover, pictureType: "Front Cover")], to: url)

        let readBack = try TagFile.read(at: url)
        try #require(readBack.artworks.count == 1, "\(format): Cover nicht geschrieben")
        #expect(readBack.artworks[0].data == cover, "\(format): Coverdaten verändert")
        #expect(readBack.artworks[0].resolvedMimeType == "image/jpeg")

        // Entfernen
        try TagFile.write(artworks: [], to: url)
        let afterRemove = try TagFile.read(at: url)
        #expect(afterRemove.artworks.isEmpty, "\(format): Cover nicht entfernt")
    }

    @Test("Audio-Eigenschaften plausibel", arguments: audioFormats)
    func audioProperties(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let data = try TagFile.read(at: url)
        let audio = try #require(data.audio, "\(format): keine Audio-Eigenschaften")
        // 2-Sekunden-Sinuston
        #expect(audio.lengthMilliseconds > 1500 && audio.lengthMilliseconds < 2500,
                "\(format): Länge \(audio.lengthMilliseconds) ms unplausibel")
        #expect(audio.sampleRateHz > 0)
        #expect(audio.channels >= 1)
    }

    @Test("Mehrwertige Felder bleiben erhalten")
    func multiValueFields() throws {
        let url = try Fixtures.workingCopy("sample.flac")
        let props = [
            TagProperty(key: "GENRE", value: "Jazz"),
            TagProperty(key: "GENRE", value: "Funk"),
            TagProperty(key: "ARTIST", value: "A"),
        ]
        try TagFile.write(properties: props, to: url)
        let readBack = try TagFile.read(at: url)
        #expect(readBack.values(for: "GENRE").sorted() == ["Funk", "Jazz"])
    }

    @Test("Container-Tags schreiben und lesen", arguments: containerFormats)
    func containerPropertiesRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let props = [
            TagProperty(key: "TITLE", value: "Video-Titel äöü"),
            TagProperty(key: "GENRE", value: "Dokumentation"),
        ]
        try TagFile.write(properties: props, to: url)
        let readBack = try TagFile.read(at: url)
        for prop in props {
            #expect(readBack.values(for: prop.key).contains(prop.value),
                    "\(format): \(prop.key) fehlt oder falsch")
        }
    }

    @Test("Audio-Eigenschaften der reinen Ton-Container plausibel",
          arguments: ["sample.mka", "sample.3gp", "sample.3g2"])
    func containerAudioProperties(format: String) throws {
        // Diese Fixtures tragen den 2-Sekunden-Sinuston ohne Bildspur.
        let data = try TagFile.read(at: Fixtures.workingCopy(format))
        let audio = try #require(data.audio, "\(format): keine Audio-Eigenschaften")
        #expect(audio.lengthMilliseconds > 1500 && audio.lengthMilliseconds < 2500,
                "\(format): Länge \(audio.lengthMilliseconds) ms unplausibel")
        #expect(audio.sampleRateHz > 0)
        #expect(audio.channels >= 1)
    }

    @Test("3GP-Container tragen auch ein Cover", arguments: ["sample.3gp", "sample.3g2"])
    func threeGPCoverRoundtrip(format: String) throws {
        // Gleicher MP4-Weg wie m4a: Das Cover landet im covr-Atom. TagLib
        // übernimmt dort nur Bilddaten, die es als JPEG/PNG erkennt — die
        // Fixture ist ein echtes JPEG.
        let url = try Fixtures.workingCopy(format)
        let cover = try Fixtures.coverData("cover.jpg")
        try TagFile.write(artworks: [Artwork(data: cover, pictureType: "Front Cover")], to: url)
        let readBack = try TagFile.read(at: url)
        try #require(readBack.artworks.count == 1, "\(format): Cover nicht geschrieben")
        #expect(readBack.artworks[0].data == cover)
    }

    @Test("Nicht existierende Datei wirft cannotOpen")
    func missingFile() throws {
        // Hinweis: Eine *existierende* Datei mit Müll-Inhalt und .mp3-Endung
        // öffnet TagLib tolerant (leerer Tag, keine Audio-Eigenschaften) —
        // das ist gewollt lax und wird deshalb hier nicht als Fehler erwartet.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gibts-nicht-\(UUID().uuidString).mp3")
        #expect(throws: TagError.self) {
            _ = try TagFile.read(at: missing)
        }
    }

    @Test("MIME-Sniffing erkennt JPEG und PNG")
    func mimeSniffing() throws {
        let jpg = try Fixtures.coverData("cover.jpg")
        let png = try Fixtures.coverData("cover.png")
        #expect(Artwork.sniffMimeType(from: jpg) == "image/jpeg")
        #expect(Artwork.sniffMimeType(from: png) == "image/png")
    }
}

@Suite("MediaInfo")
struct MediaInfoTests {

    @Test("Report enthält General- und Audio-Track")
    func basicReport() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let report = try MediaInfoReader.read(url: url)
        #expect(report.tracks.contains { $0.type == "General" })
        #expect(report.tracks.contains { $0.type == "Audio" })
        #expect(!report.text.isEmpty)
    }

    @Test("Tags erscheinen im MediaInfo-Report")
    func tagsVisible() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [
            TagProperty(key: "TITLE", value: "Sichtbarkeit"),
            TagProperty(key: "ARTIST", value: "MediaInfo Check"),
        ], to: url)
        let report = try MediaInfoReader.read(url: url)
        let general = try #require(report.tracks.first { $0.type == "General" })
        #expect(general.fields.contains { $0.key == "Title" && $0.value == "Sichtbarkeit" })
    }

    @Test("Umlaute überleben den Weg bis in den MediaInfo-Report (UTF-8-Schreibweise)")
    func umlautsSurviveToMediaInfo() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        try TagFile.write(properties: [
            TagProperty(key: "ARTIST", value: "Testkünstler Ärger Öse"),
        ], to: url)
        let report = try MediaInfoReader.read(url: url)
        let general = try #require(report.tracks.first { $0.type == "General" })
        #expect(general.fields.contains { $0.key == "Performer" && $0.value == "Testkünstler Ärger Öse" },
                "Performer-Feld: \(general.fields.filter { $0.key == "Performer" })")
    }

    @Test("Surrogate-Escapes aus mediainfo-JSON werden als Latin1 dekodiert")
    func surrogateEscapeRepair() throws {
        // 0xFC = ü, 0xF6 = ö in Latin1; mediainfo schreibt "\udcfc"/"\udcf6".
        // Die Reparatur stellt die Rohbytes wieder her; die Latin1-Deutung
        // trifft erst die Kodierungsentscheidung in decodeLossyJSON.
        let raw = Data(#"{"a":"Ungek\udcfcrzt","b":"B\udcf6rn"}"#.utf8)
        #expect(MediaInfoReader.decodeLossyJSON(raw) == #"{"a":"Ungekürzt","b":"Börn"}"#)
    }
}

/// Tracker-Module lesen sich über TagLib, speichern aber nur Titel, Kommentar
/// (Sample-/Instrumentnamen, eine Zeile je Name) und Tracker-Namen. Alle
/// anderen Felder muss der Schreibweg ablehnen, ohne die Datei anzufassen.
@Suite("Tracker-Module", .serialized)
struct TrackerFormatTests {

    @Test("Titel und Tracker-Name werden gelesen", arguments: trackerFormats)
    func readsTitle(format: (file: String, title: String)) throws {
        let data = try TagFile.read(at: Fixtures.workingCopy(format.file))
        #expect(data.values(for: "TITLE") == [format.title], "\(format.file): Titel")
        #expect(!data.values(for: "TRACKERNAME").isEmpty, "\(format.file): Tracker-Name fehlt")
        #expect(data.artworks.isEmpty)
        // Ohne Sample-Daten gibt es keine Spielzeit; die Kanalzahl steht im Kopf.
        #expect(data.audio?.channels == 4, "\(format.file): Kanäle \(String(describing: data.audio))")
    }

    @Test("Titel und Kommentar überleben den Roundtrip", arguments: trackerFormats)
    func titleAndCommentRoundtrip(format: (file: String, title: String)) throws {
        // Latin1 und kurz: Die Formate speichern Titel in 20–28 Byte ohne
        // Unicode; längere oder nicht-Latin1-Zeichen kürzt TagLib stumm.
        let url = try Fixtures.workingCopy(format.file)
        let props = [
            TagProperty(key: "TITLE", value: "Modul äöü"),
            TagProperty(key: "COMMENT", value: "Kommentarzeile"),
        ]
        try TagFile.write(properties: props, to: url)
        let readBack = try TagFile.read(at: url)
        #expect(readBack.values(for: "TITLE") == ["Modul äöü"], "\(format.file): Titel")
        // Der Kommentar wird auf die Sample-Namen verteilt: erste Zeile = unser Text.
        let comment = readBack.values(for: "COMMENT").first ?? ""
        #expect(comment.split(separator: "\n", omittingEmptySubsequences: false).first == "Kommentarzeile",
                "\(format.file): Kommentar \(comment.prefix(40))")
    }

    @Test("Unbekannte Felder werden abgelehnt, die Datei bleibt unverändert",
          arguments: trackerFormats)
    func rejectsUnsupportedFieldsWithoutTouchingFile(format: (file: String, title: String)) throws {
        let url = try Fixtures.workingCopy(format.file)
        let before = try Data(contentsOf: url)
        let props = [
            TagProperty(key: "TITLE", value: "Neu"),
            TagProperty(key: "ARTIST", value: "Die Testkapelle"),
        ]
        #expect(throws: TagError.propertiesRejected(count: 1)) {
            try TagFile.write(properties: props, to: url)
        }
        #expect(try Data(contentsOf: url) == before, "\(format.file): Datei wurde angefasst")
        #expect(MediaFormats.writableTagKeys(for: url)?.contains("ARTIST") == false)
    }

    @Test("Cover werden abgelehnt, die Datei bleibt unverändert", arguments: trackerFormats)
    func rejectsCoverWithoutTouchingFile(format: (file: String, title: String)) throws {
        let url = try Fixtures.workingCopy(format.file)
        let before = try Data(contentsOf: url)
        let cover = try Fixtures.coverData("cover.jpg")
        #expect(throws: TagError.self) {
            try TagFile.write(artworks: [Artwork(data: cover, pictureType: "Front Cover")], to: url)
        }
        #expect(try Data(contentsOf: url) == before, "\(format.file): Datei wurde angefasst")
        #expect(!MediaFormats.supportsEmbeddedArtwork(url))
    }
}

/// Sun-AU und Ogg-Video haben in TagLib keinen Leser: Der Tag-Weg meldet das
/// klar, die Technik-Anzeige über mediainfo funktioniert trotzdem.
@Suite("Nur-Anzeige-Formate")
struct DisplayOnlyFormatTests {

    @Test("TagLib lehnt die Datei ab, die App darf sie trotzdem öffnen",
          arguments: displayOnlyFormats)
    func tagLibCannotOpen(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        #expect(throws: TagError.cannotOpen(path: url.path)) {
            _ = try TagFile.read(at: url)
        }
        #expect(MediaFormats.kind(of: url) == .audio)
        #expect(MediaFormats.toleratesMissingTagReader(url))
        #expect(!MediaFormats.supportsEmbeddedArtwork(url))
    }

    @Test("mediainfo liefert einen Report", arguments: displayOnlyFormats)
    func mediaInfoReport(format: String) throws {
        let report = try MediaInfoReader.read(url: Fixtures.workingCopy(format))
        let general = try #require(report.tracks.first { $0.type == "General" })
        #expect(general.fields.contains { $0.key == "Format" }, "\(format): kein Format-Feld")
        // Bei VP8-in-Ogg listet mediainfo keine Einzelspuren; AU hat eine Tonspur.
        if format.hasSuffix(".au") {
            #expect(report.tracks.contains { $0.type == "Audio" })
        }
    }
}

@Suite("MediaInfo-Cross-Check neue Endungen")
struct MediaInfoNewFormatTests {

    @Test("Mit TagLib geschriebene Titel liest mediainfo",
          arguments: ["sample.mp2", "sample.3gp", "sample.3g2", "sample.mka",
                      "sample.xm", "sample.s3m", "sample.it"])
    func titleVisibleInMediaInfo(format: String) throws {
        // Nicht dabei: aifc (mediainfo zeigt ID3 in AIFF nicht als Title)
        // und mod (mediainfo liest den ProTracker-Titel nicht).
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Sichtbar")], to: url)
        let report = try MediaInfoReader.read(url: url)
        let general = try #require(report.tracks.first { $0.type == "General" })
        #expect(general.fields.contains { $0.key == "Title" && $0.value == "Sichtbar" },
                "\(format): \(general.fields.filter { $0.key == "Title" })")
    }
}

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

/// Alle Formate, die der Roundtrip abdecken soll.
let audioFormats = ["sample.mp3", "sample.m4a", "sample.m4b", "sample.flac",
                    "sample.ogg", "sample.opus", "sample.wav", "sample.aiff",
                    "sample.wv"]

/// Video-Container, deren Tags TagLib schreiben kann.
let videoFormats = ["sample.mp4", "sample.m4v", "sample.mkv"]

@Suite("Tag-Roundtrip", .serialized)
struct RoundtripTests {

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

    @Test("Video-Tags schreiben und lesen", arguments: videoFormats)
    func videoPropertiesRoundtrip(format: String) throws {
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

    @Test("Surrogate-Escapes aus mediainfo-JSON werden als Latin1 repariert")
    func surrogateEscapeRepair() throws {
        // 0xFC = ü, 0xF6 = ö in Latin1; mediainfo schreibt "\udcfc"/"\udcf6"
        let raw = Data(#"{"a":"Ungek\udcfcrzt","b":"B\udcf6rn"}"#.utf8)
        let repaired = MediaInfoReader.repairSurrogateEscapes(in: raw)
        let s = String(data: repaired, encoding: .utf8)
        #expect(s == #"{"a":"Ungekürzt","b":"Börn"}"#)
    }
}

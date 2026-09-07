// Kapitel (Hörbuch/Podcast): Lesen der ffmpeg-Fixtures, Roundtrip je
// schreibbarem Format, Cross-Check mit ffprobe, Erhalt beim Tag-Schreiben,
// Austauschformate (JSON/Text) und Plausibilitätsprüfung.
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

private let ffprobePath = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Kapitel, wie ffprobe sie sieht — der externe Beweis, dass andere Programme
/// unsere Kapitel lesen können (nicht nur TagLib selbst).
private func ffprobeChapters(of url: URL) -> [(title: String, start: Int, end: Int)]? {
    guard let ffprobe = ffprobePath,
          let result = try? runCapturedProcess(executable: ffprobe,
              arguments: ["-v", "error", "-print_format", "json", "-show_chapters", url.path],
              currentDirectory: TagxTestProcess.repoRoot),
          result.status == 0,
          let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
          let list = json["chapters"] as? [[String: Any]]
    else { return nil }
    return list.map { entry in
        let tags = entry["tags"] as? [String: Any]
        // ffprobe liefert Sekunden als String; auf Millisekunden runden.
        let start = Double(entry["start_time"] as? String ?? "0") ?? 0
        let end = Double(entry["end_time"] as? String ?? "0") ?? 0
        return (title: tags?["title"] as? String ?? "",
                start: Int((start * 1000).rounded()), end: Int((end * 1000).rounded()))
    }
}

private let ffprobeAvailable = ffprobePath != nil

/// Alle Formate, in die Kapitel geschrieben werden können.
let chapterFormats = ["sample.mp3", "sample.m4a", "sample.m4b", "sample.mkv"]

@Suite("Kapitel", .serialized)
struct ChapterTests {

    // MARK: - Lesen

    @Test("ffmpeg-Kapitel werden gelesen", arguments: ["chapters.mp3", "chapters.m4b", "chapters.mkv"])
    func readsFfmpegChapters(fixture: String) throws {
        let data = try TagFile.read(at: Fixtures.directory.appendingPathComponent(fixture))
        #expect(data.supportsChapters)
        try #require(data.chapters.count == 2, "\(fixture): erwartet 2 Kapitel")
        #expect(data.chapters[0].title == "Intro")
        #expect(data.chapters[0].startMilliseconds == 0)
        #expect(data.chapters[1].title == "Kapitel Zwei")
        #expect(data.chapters[1].startMilliseconds == 1000)
        // MP4 speichert kein Ende; es ergibt sich aus dem nächsten Beginn bzw.
        // der Spielzeit (AAC-Encoder-Delay macht die Spielzeit minimal länger).
        #expect(data.chapters[0].endMilliseconds == 1000)
        #expect(abs(data.chapters[1].endMilliseconds - 2000) <= 100)
    }

    @Test("Formate ohne Kapitel melden das ehrlich",
          arguments: ["sample.flac", "sample.ogg", "sample.opus", "sample.wav"])
    func unsupportedFormatsReportNoChapters(format: String) throws {
        let data = try TagFile.read(at: Fixtures.directory.appendingPathComponent(format))
        #expect(!data.supportsChapters)
        #expect(data.chapters.isEmpty)
        let url = try Fixtures.workingCopy(format)
        #expect(throws: TagError.chaptersUnsupported(path: url.path)) {
            try TagFile.write(chapters: [Chapter(title: "X", startMilliseconds: 0, endMilliseconds: 1)], to: url)
        }
    }

    // MARK: - Roundtrip

    static let sample = [
        Chapter(title: "Einleitung", startMilliseconds: 0, endMilliseconds: 700),
        Chapter(title: "Kapitel 1 — Ümläute & 🎧", startMilliseconds: 700, endMilliseconds: 1500),
        Chapter(title: "Schluss", startMilliseconds: 1500, endMilliseconds: 2000),
    ]

    @Test("Kapitel schreiben, lesen und entfernen", arguments: chapterFormats)
    func chapterRoundtrip(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        #expect(try TagFile.read(at: url).chapters.isEmpty)

        try TagFile.write(chapters: Self.sample, to: url)
        let readBack = try TagFile.read(at: url).chapters
        try #require(readBack.count == 3, "\(format): Kapitel nicht geschrieben")
        for (written, read) in zip(Self.sample, readBack) {
            #expect(read.title == written.title, Comment(rawValue: format))
            #expect(read.startMilliseconds == written.startMilliseconds, Comment(rawValue: format))
            // MP4 leitet das Ende beim Lesen ab; bei den anderen muss es stimmen.
            if !format.hasSuffix("m4a"), !format.hasSuffix("m4b") {
                #expect(read.endMilliseconds == written.endMilliseconds, Comment(rawValue: format))
            }
        }

        // Ersetzen: neue Liste verdrängt die alte vollständig.
        let replacement = [Chapter(title: "Nur eins", startMilliseconds: 0, endMilliseconds: 2000)]
        try TagFile.write(chapters: replacement, to: url)
        #expect(try TagFile.read(at: url).chapters.map(\.title) == ["Nur eins"], Comment(rawValue: format))

        // Entfernen
        try TagFile.write(chapters: [], to: url)
        #expect(try TagFile.read(at: url).chapters.isEmpty, "\(format): Kapitel nicht entfernt")
    }

    @Test("ffprobe liest unsere Kapitel", .enabled(if: ffprobeAvailable, "ffprobe fehlt"),
          arguments: chapterFormats)
    func ffprobeCrossCheck(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(chapters: Self.sample, to: url)
        let seen = try #require(ffprobeChapters(of: url))
        try #require(seen.count == 3, "\(format): ffprobe sieht \(seen.count) Kapitel")
        for (written, probe) in zip(Self.sample, seen) {
            #expect(probe.title == written.title, Comment(rawValue: format))
            // MP4-Kapitelspuren liegen im Zeitraster der Audiospur (1/44100):
            // eine Millisekunde Rundung ist erlaubt.
            #expect(abs(probe.start - written.startMilliseconds) <= 1, Comment(rawValue: format))
        }
        try TagFile.write(chapters: [], to: url)
        #expect(try #require(ffprobeChapters(of: url)).isEmpty, "\(format): ffprobe sieht noch Kapitel")
    }

    @Test("Tag- und Cover-Schreiben lässt Kapitel stehen", arguments: chapterFormats)
    func chaptersSurviveTagWrite(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        try TagFile.write(chapters: Self.sample, to: url)
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Neuer Titel"),
                         TagProperty(key: "ARTIST", value: "Sprecherin")],
            artworks: [Artwork(data: try Fixtures.coverData("cover.jpg"), pictureType: "Front Cover")],
            to: url)
        let after = try TagFile.read(at: url)
        #expect(after.firstValue(for: "TITLE") == "Neuer Titel", Comment(rawValue: format))
        #expect(after.artworks.count == 1, Comment(rawValue: format))
        #expect(after.chapters.map(\.title) == Self.sample.map(\.title), Comment(rawValue: format))
    }

    @Test("Kapitel-Schreiben lässt Tags, Cover und Audiostream stehen", arguments: chapterFormats)
    func tagsSurviveChapterWrite(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let cover = try Fixtures.coverData("cover.jpg")
        try TagFile.write(properties: [TagProperty(key: "ALBUM", value: "Hörbuch")],
                          artworks: [Artwork(data: cover, pictureType: "Front Cover")], to: url)
        let audioBefore = FileIntegrityTests.ffmpegAvailable
            ? try #require(FileIntegrityTests.audioStreamChecksum(of: url)) : nil

        try TagFile.write(chapters: Self.sample, to: url)
        let after = try TagFile.read(at: url)
        #expect(after.firstValue(for: "ALBUM") == "Hörbuch", Comment(rawValue: format))
        #expect(after.artworks.first?.data == cover, Comment(rawValue: format))
        #expect(after.chapters.count == 3, Comment(rawValue: format))
        if let audioBefore {
            #expect(FileIntegrityTests.audioStreamChecksum(of: url) == audioBefore, Comment(rawValue: format))
        }
    }

    @Test("Unstimmige Kapitel werden vor dem Schreiben abgelehnt")
    func invalidChaptersAreRejectedBeforeWriting() throws {
        let url = try Fixtures.workingCopy("sample.mp3")
        let before = try Data(contentsOf: url)
        let bad = [
            Chapter(title: "Ende vor Beginn", startMilliseconds: 500, endMilliseconds: 100),
        ]
        #expect(throws: TagError.self) { try TagFile.write(chapters: bad, to: url) }
        let unsorted = [
            Chapter(title: "B", startMilliseconds: 900, endMilliseconds: 1000),
            Chapter(title: "A", startMilliseconds: 0, endMilliseconds: 900),
        ]
        #expect(throws: TagError.self) { try TagFile.write(chapters: unsorted, to: url) }
        // Überlappung: Kapitel 2 beginnt, bevor Kapitel 1 endet — sortiert,
        // aber trotzdem kein gültiger Bereich (Review 2026-09-02).
        let overlapping = [
            Chapter(title: "A", startMilliseconds: 0, endMilliseconds: 1000),
            Chapter(title: "B", startMilliseconds: 500, endMilliseconds: 1500),
        ]
        #expect(throws: TagError.self) { try TagFile.write(chapters: overlapping, to: url) }
        #expect(throws: TagError.self) { try ChapterList.validate(overlapping) }
        // Nahtlos (Ende = nächster Beginn) bleibt erlaubt.
        let seamless = [
            Chapter(title: "A", startMilliseconds: 0, endMilliseconds: 1000),
            Chapter(title: "B", startMilliseconds: 1000, endMilliseconds: 1500),
        ]
        #expect(throws: Never.self) { try ChapterList.validate(seamless) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Nicht darstellbare Kapitelenden verändern die Datei nicht", arguments: ["sample.mp3", "sample.mkv"])
    func rejectsUnrepresentableEnd(format: String) throws {
        let url = try Fixtures.workingCopy(format)
        let before = try Data(contentsOf: url)
        let chapters = [Chapter(title: "Zu lang", startMilliseconds: 0, endMilliseconds: Int.max)]
        #expect(throws: TagError.self) { try TagFile.write(chapters: chapters, to: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - Austauschformate

    @Test("Zeitstempel lesen und schreiben")
    func timestamps() {
        #expect(ChapterList.formatTimestamp(0) == "00:00:00.000")
        #expect(ChapterList.formatTimestamp(3_723_456) == "01:02:03.456")
        #expect(ChapterList.parseTimestamp("01:02:03.456") == 3_723_456)
        #expect(ChapterList.parseTimestamp("1:02:03") == 3_723_000)
        #expect(ChapterList.parseTimestamp("02:03") == 123_000)
        #expect(ChapterList.parseTimestamp("5.5") == 5_500)
        #expect(ChapterList.parseTimestamp("5,25") == 5_250)
        #expect(ChapterList.parseTimestamp("00:00:01.1234") == 1_123)
        #expect(ChapterList.parseTimestamp("abc") == nil)
        #expect(ChapterList.parseTimestamp("1:2:3:4") == nil)
        #expect(ChapterList.parseTimestamp("") == nil)
        for text in ["\(Int.max)", "\(Int.max):00", "\(Int.max):00:00", "9223372036854775.808"] {
            #expect(ChapterList.parseTimestamp(text) == nil)
        }
        #expect(ChapterList.parseTimestamp(ChapterList.formatTimestamp(Int.max)) == Int.max)
        #expect(LRC.parseTimestamp(LRC.formatTimestamp(Int.max)) == Int.max)
    }

    @Test("Textformat: eine Zeile pro Kapitel, Enden aus dem nächsten Beginn")
    func textFormat() throws {
        let text = """
        # Kommentar
        00:00:00.000 Intro
        00:00:01.500 Kapitel Zwei

        00:00:01.750
        """
        let chapters = try ChapterList.parseText(text, totalLength: 2000)
        #expect(chapters == [
            Chapter(title: "Intro", startMilliseconds: 0, endMilliseconds: 1500),
            Chapter(title: "Kapitel Zwei", startMilliseconds: 1500, endMilliseconds: 1750),
            Chapter(title: "", startMilliseconds: 1750, endMilliseconds: 2000),
        ])
        #expect(ChapterList.renderText(chapters)
                == "00:00:00.000 Intro\n00:00:01.500 Kapitel Zwei\n00:00:01.750 \n")
        #expect(throws: TagError.self) { try ChapterList.parseText("Intro 00:00", totalLength: nil) }
    }

    @Test("JSON: Array oder show-Ausgabe, fehlendes Ende wird ergänzt")
    func jsonFormat() throws {
        let array = Data(#"[{"title":"A","start":0},{"title":"B","start":1000,"end":1900}]"#.utf8)
        #expect(try ChapterList.parseJSON(array, totalLength: nil) == [
            Chapter(title: "A", startMilliseconds: 0, endMilliseconds: 1000),
            Chapter(title: "B", startMilliseconds: 1000, endMilliseconds: 1900),
        ])
        let envelope = Data(#"{"file":"x.mp3","chapters":[{"start":5,"end":9}]}"#.utf8)
        #expect(try ChapterList.parseJSON(envelope, totalLength: nil)
                == [Chapter(title: "", startMilliseconds: 5, endMilliseconds: 9)])
        #expect(throws: TagError.self) { try ChapterList.parseJSON(Data("{}".utf8), totalLength: nil) }

        // renderJSON → parseJSON ist verlustfrei.
        let rendered = try ChapterList.renderJSON(Self.sample)
        #expect(try ChapterList.parseJSON(rendered, totalLength: nil) == Self.sample)
    }

    @Test("Datei-Import erkennt JSON und Text am Inhalt")
    func loadDetectsFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-chapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("kapitel.txt") // Endung absichtlich „falsch“
        try ChapterList.renderJSON(Self.sample).write(to: json)
        #expect(try ChapterList.load(from: json, totalLength: nil) == Self.sample)
        let text = dir.appendingPathComponent("kapitel.json")
        try Data(ChapterList.renderText(Self.sample).utf8).write(to: text)
        #expect(try ChapterList.load(from: text, totalLength: 2000).map(\.title) == Self.sample.map(\.title))
    }
}

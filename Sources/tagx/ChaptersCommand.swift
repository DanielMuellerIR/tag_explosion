// tagx chapters show/set/clear — Kapitel von Hörbüchern und Podcasts
// (MP3: ID3 CHAP/CTOC, MP4: Nero chpl + QuickTime-Spur, Matroska: Chapters).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Chapters: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show, set, or remove chapters (MP3, MP4/M4A/M4B, Matroska).",
        subcommands: [ChaptersShow.self, ChaptersSet.self, ChaptersClear.self],
        defaultSubcommand: ChaptersShow.self
    )
}

/// JSON-Form von `chapters show`; `chapters set --from` liest sie wieder ein.
struct ChapterReport: Codable {
    var file: String
    /// false bei Formaten ohne Kapitel — dann ist `chapters` immer leer.
    var supported: Bool
    var chapters: [Chapter]
}

struct ChaptersShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "List the chapters of a file (text: HH:MM:SS.mmm Title, or JSON).")

    @Argument(help: "Media file") var file: String
    @Flag(name: .long, help: "Output as JSON ({file, supported, chapters: [{title, start, end}]}, times in ms)")
    var json = false

    func run() throws {
        let url = try resolveFile(file)
        let data = try TagFile.read(at: url)
        if json {
            try printJSON(ChapterReport(file: url.path, supported: data.supportsChapters,
                                        chapters: data.chapters))
            return
        }
        // Textausgabe ist zugleich das Import-Format von `chapters set --from`.
        // Hinweise gehen auf stderr, damit stdout importierbar bleibt.
        if !data.supportsChapters {
            FileHandle.standardError.write(
                Data("Note: \(url.lastPathComponent) — this format has no chapters\n".utf8))
        } else if data.chapters.isEmpty {
            FileHandle.standardError.write(Data("Note: \(url.lastPathComponent) has no chapters\n".utf8))
        }
        print(ChapterList.renderText(data.chapters), terminator: "")
    }
}

struct ChaptersSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Replace all chapters from a JSON or text file (one line per chapter: HH:MM:SS.mmm Title).")

    @Argument(help: "Media file (MP3, MP4/M4A/M4B, Matroska)") var file: String
    @Option(name: .long, help: "Chapter list: JSON ([{title, start, end}] in ms) or text; '-' reads stdin")
    var from: String
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        // Inhalt und Stempel gehören zusammen (siehe `tagx set`).
        let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
        let existing = snapshot.value
        guard existing.supportsChapters else {
            throw ValidationError(TagError.chaptersUnsupported(path: url.path).localizedDescription)
        }
        // Fehlende Enden (Textformat, JSON ohne `end`) ergänzt die Spielzeit.
        let length = existing.audio?.lengthMilliseconds
        let chapters: [Chapter]
        do {
            if from == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else {
                    throw TagError.invalidChapters(reason: "stdin is not UTF-8 text")
                }
                let first = text.first { !$0.isWhitespace }
                chapters = (first == "[" || first == "{")
                    ? try ChapterList.parseJSON(data, totalLength: length)
                    : try ChapterList.parseText(text, totalLength: length)
            } else {
                chapters = try ChapterList.load(from: try resolveFile(from), totalLength: length)
            }
        } catch let error as TagError {
            throw ValidationError(error.localizedDescription)
        }

        // Gleiche Liste wie in der Datei: nichts anfassen, keine Sicherung.
        guard chapters != existing.chapters else {
            try snapshot.requireCurrent(at: url)
            print("OK \(url.lastPathComponent): chapters unchanged (\(chapters.count))")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url, reason: BackupReason.chapters)
        try TagFile.write(chapters: chapters, to: url, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent): \(chapters.count) chapter(s) written")
    }
}

struct ChaptersClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Remove all chapters.")

    @Argument(help: "Media file") var file: String
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
        guard snapshot.value.supportsChapters else {
            throw ValidationError(TagError.chaptersUnsupported(path: url.path).localizedDescription)
        }
        guard !snapshot.value.chapters.isEmpty else {
            try snapshot.requireCurrent(at: url)
            print("OK \(url.lastPathComponent): no chapters to remove")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url, reason: BackupReason.chapters)
        try TagFile.write(chapters: [], to: url, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent): chapters removed")
    }
}

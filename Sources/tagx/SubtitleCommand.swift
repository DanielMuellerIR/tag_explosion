// tagx subtitle — Untertitel (.srt/.vtt) anzeigen, VTT-Kopf setzen und alle
// Cues zeitlich verschieben.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Subtitle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subtitle",
        abstract: "Show .srt/.vtt subtitles, edit the WebVTT header, shift all cues.",
        subcommands: [SubtitleShow.self, SubtitleSet.self, SubtitleShift.self],
        defaultSubcommand: SubtitleShow.self
    )
}

struct SubtitleShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show cue count, time span, encoding, language from the file name and the WebVTT header.")

    @Argument(help: "Subtitle file (srt, vtt)") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var file: String
        var info: SubtitleInfo
        /// Editierbare VTT-Felder (bei SRT leer).
        var fields: SubtitleEditableFields
    }

    func run() throws {
        let url = try resolveFile(file)
        let contents = try SubtitleFile.readSnapshot(url: url).value
        if json {
            try printJSON(Report(file: url.path, info: contents.info, fields: contents.fields))
            return
        }
        let info = contents.info
        print("FORMAT=\(info.format.rawValue)")
        print("CUES=\(info.cueCount)")
        if let start = info.firstStartMilliseconds, let end = info.lastEndMilliseconds {
            print("FIRST=\(ChapterList.formatTimestamp(start))")
            print("LAST=\(ChapterList.formatTimestamp(end))")
            print("SPAN=\(ChapterList.formatTimestamp(info.spanMilliseconds))")
        }
        print("ENCODING=\(info.encoding)")
        print("LINEENDINGS=\(info.lineEndings)")
        if let language = info.languageFromName { print("LANG=\(language)") }
        if !info.flagsFromName.isEmpty { print("FLAGS=\(info.flagsFromName.joined(separator: ","))") }
        if let header = info.header {
            if !header.title.isEmpty { print("TITLE=\(header.title)") }
            for line in header.lines { print("HEADER=\(line)") }
            for note in header.notes { print("NOTE=\(note.replacingOccurrences(of: "\n", with: " | "))") }
        }
    }
}

struct SubtitleSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the WebVTT title and Language header (an empty value deletes it). SRT has no header.")

    @Argument(help: "Subtitle file (vtt)") var file: String
    @Option(help: "Title after WEBVTT") var title: String?
    @Option(help: "Language header, e.g. de") var language: String?
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try SubtitleFile.readSnapshot(url: url)
        let original = snapshot.value.fields
        var fields = original
        if let title { fields.title = title }
        if let language { fields.language = language }
        do {
            try SubtitleFile.requireWritable(fields, original: original, url: url)
        } catch let error as TagError {
            switch error {
            case .unsupportedDocumentField, .invalidDocumentValue:
                throw ValidationError(error.localizedDescription)
            default: throw error
            }
        }
        guard fields != original else {
            try snapshot.requireCurrent(at: url)
            print("No changes")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url)
        try SubtitleFile.write(url: url, fields: fields, original: original, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent)")
    }
}

struct SubtitleShift: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shift",
        abstract: "Shift all cue times, e.g. --seconds 1.5 or --seconds=-0.25 (negative values need the = form). Everything else stays byte-identical.")

    @Argument(help: "Subtitle file (srt, vtt)") var file: String
    @Option(help: "Offset in seconds (decimal, may be negative)") var seconds: Double
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        // Bereichsprüfung im Core: `inf`, `nan` oder 1e16 sind gültige
        // Doubles, aber keine Verschiebung — Fehler statt Laufzeitabbruch.
        let milliseconds: Int
        do {
            milliseconds = try SubtitleFile.shiftMilliseconds(seconds: seconds)
        } catch TagError.invalidSubtitleShift(let reason) {
            throw ValidationError(TagError.invalidSubtitleShift(reason: reason).localizedDescription)
        }
        guard milliseconds != 0 else {
            print("No changes")
            return
        }
        guard let stamp = FileStamp.current(of: url) else {
            throw TagError.cannotOpen(path: url.path)
        }
        do {
            try TrashBackup.shared.backUp(url)
            try SubtitleFile.shift(url: url, milliseconds: milliseconds, expecting: stamp)
        } catch TagError.invalidSubtitleShift(let reason) {
            throw ValidationError(TagError.invalidSubtitleShift(reason: reason).localizedDescription)
        }
        print("OK \(url.lastPathComponent): shifted by \(milliseconds) ms")
    }
}

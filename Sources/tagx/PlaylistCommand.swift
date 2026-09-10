// tagx playlist — Playlists und Cue-Sheets anzeigen, beschriften und aus
// einer Dateiauswahl erzeugen; tagx cue — dasselbe für Cue-Sheets plus
// `apply` (Cue-Angaben in die referenzierten Audiodateien schreiben).
// Alles nativ im Core (PlaylistTool, PlaylistExporter, CueApply).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Playlist: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playlist",
        abstract: "Show, label, and export playlists (cue, m3u, m3u8, pls, xspf).",
        subcommands: [PlaylistShow.self, PlaylistSet.self, PlaylistExport.self],
        defaultSubcommand: PlaylistShow.self
    )
}

struct Cue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cue",
        abstract: "Show and edit cue sheets; apply their titles to the referenced audio files.",
        subcommands: [PlaylistShow.self, PlaylistSet.self, CueApplyCommand.self],
        defaultSubcommand: PlaylistShow.self
    )
}

/// Playlist-Datei prüfen (Endung bekannt, Datei vorhanden).
func resolvePlaylistFile(_ path: String) throws -> URL {
    let url = try resolveFile(path)
    guard PlaylistFormat(url: url) != nil else {
        throw ValidationError("Not a playlist or cue sheet (cue, m3u, m3u8, pls, xspf): \(path)")
    }
    return url
}

struct PlaylistShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show header fields, entries, resolved paths, and total duration.")

    @Argument(help: "Playlist or cue sheet") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var file: String
        var format: PlaylistFormat
        var fields: PlaylistCoreFields
        var entries: [PlaylistEntry]
        /// Felder, die dieses Format speichern kann (sortiert).
        var supportedFields: [String]
        var info: [DocumentInfoItem]
        var totalDurationMilliseconds: Int
        var unknownDurationCount: Int
        var missingCount: Int
        var usedEncodingFallback: Bool
    }

    func run() throws {
        let url = try resolvePlaylistFile(file)
        let contents = try PlaylistTool.readSnapshot(url: url).value
        if json {
            try printJSON(Report(
                file: url.path, format: contents.format, fields: contents.fields,
                entries: contents.entries,
                supportedFields: PlaylistTool.supportedFields(url: url).map(\.rawValue).sorted(),
                info: contents.info,
                totalDurationMilliseconds: contents.totalDurationMilliseconds,
                unknownDurationCount: contents.unknownDurationCount,
                missingCount: contents.missingCount,
                usedEncodingFallback: contents.usedEncodingFallback))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        print("FORMAT=\(contents.format.rawValue)")
        line("TITLE", contents.fields.title)
        line("PERFORMER", contents.fields.performer)
        line("DATE", contents.fields.date)
        line("GENRE", contents.fields.genre)
        for item in contents.info { print("INFO.\(item.label)=\(item.value)") }
        for entry in contents.entries {
            let status = entry.isRemote ? "remote" : (entry.resolvedPath == nil ? "no file"
                : (entry.exists ? "ok" : "MISSING"))
            let duration = entry.durationMilliseconds.map(PlaylistTool.formatDuration) ?? "?"
            let label = [entry.performer, entry.title].filter { !$0.isEmpty }.joined(separator: " - ")
            print("\(entry.number). [\(status)] \(duration) \(label)")
            print("    \(entry.resolvedPath ?? entry.location)")
        }
        var total = "TOTAL=\(PlaylistTool.formatDuration(contents.totalDurationMilliseconds))"
        if contents.unknownDurationCount > 0 { total += " (+\(contents.unknownDurationCount) unknown)" }
        print(total)
        if contents.missingCount > 0 { print("MISSING=\(contents.missingCount)") }
        if contents.usedEncodingFallback { print("NOTE=file is not UTF-8; decoded with Latin1/MacRoman fallback") }
    }
}

struct PlaylistSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set header fields and entry labels (an empty value deletes). Fields the format cannot store are rejected.")

    @Argument(help: "Playlist or cue sheet") var file: String
    @Option(help: "Playlist/album title") var title: String?
    @Option(help: "Playlist/album performer (cue, xspf)") var performer: String?
    @Option(help: "Date (cue REM DATE)") var date: String?
    @Option(help: "Genre (cue REM GENRE)") var genre: String?
    @Option(name: .customLong("entry-title"), parsing: .upToNextOption,
            help: "Entry title N=TEXT (N = entry number as shown by `show`)")
    var entryTitle: [String] = []
    @Option(name: .customLong("entry-performer"), parsing: .upToNextOption,
            help: "Entry performer N=TEXT (cue, xspf)")
    var entryPerformer: [String] = []
    @OptionGroup var safeMode: SafeModeOptions

    /// "3=Text" → (Index in der Eintragsliste, Text)
    private func parseAssignment(_ assignment: String, entries: [PlaylistEntry]) throws -> (Int, String) {
        guard let eq = assignment.firstIndex(of: "="),
              let number = Int(assignment[..<eq].trimmingCharacters(in: .whitespaces)) else {
            throw ValidationError("Invalid entry assignment (expected N=TEXT): \(assignment)")
        }
        guard let index = entries.firstIndex(where: { $0.number == number }) else {
            throw ValidationError("No entry with number \(number)")
        }
        return (index, String(assignment[assignment.index(after: eq)...]))
    }

    func run() throws {
        safeMode.apply()
        let url = try resolvePlaylistFile(file)
        let snapshot = try PlaylistTool.readSnapshot(url: url)
        let contents = snapshot.value
        let original = contents.fields
        var fields = original
        if let title { fields.title = title }
        if let performer { fields.performer = performer }
        if let date { fields.date = date }
        if let genre { fields.genre = genre }
        for assignment in entryTitle {
            let (index, text) = try parseAssignment(assignment, entries: contents.entries)
            fields.entries[index].title = text
        }
        for assignment in entryPerformer {
            let (index, text) = try parseAssignment(assignment, entries: contents.entries)
            fields.entries[index].performer = text
        }
        do {
            try PlaylistTool.requireWritable(fields, original: original, url: url)
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
        try PlaylistTool.write(url: url, fields: fields, original: original, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent)")
    }
}

struct PlaylistExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write a playlist (m3u, m3u8, pls, xspf) for the given media files; paths relative to the playlist.")

    @Argument(help: "Media files (in playlist order)") var files: [String]
    @Option(name: .long, help: "Playlist format: m3u, m3u8, pls, xspf (default: from --out extension)")
    var format: String?
    @Option(name: .long, help: "Output playlist file") var out: String
    @Option(name: .long, help: "Playlist title (#PLAYLIST / xspf title)") var title: String = ""
    @Flag(name: .long, help: "Write absolute paths instead of paths relative to the playlist") var absolute = false
    @Flag(name: .long, help: "Overwrite an existing output file") var force = false
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        // Ohne diesen Aufruf bleibt die Sicherung im Exporter still wirkungslos:
        // der Core sichert per Vorgabe nicht, und nur `apply()` schaltet den
        // abgesicherten Modus ein (Review-Fund 2026-09-10).
        safeMode.apply()
        let urls = try files.map(resolveFile)
        let output = URL(fileURLWithPath: out)
        let formatName = format ?? output.pathExtension.lowercased()
        guard let playlistFormat = PlaylistFormat(rawValue: formatName), playlistFormat != .cue else {
            throw ValidationError("Unsupported playlist format \"\(formatName)\" (use m3u, m3u8, pls or xspf)")
        }
        let summary: PlaylistExporter.Summary
        do {
            summary = try PlaylistExporter.export(
                files: urls, to: output, format: playlistFormat, absolutePaths: absolute,
                title: title, overwrite: force)
        } catch let error as PlaylistExporter.ExportError {
            throw ValidationError(error.localizedDescription)
        }
        print("OK \(output.path): \(summary.count) entries")
        for url in summary.untagged {
            FileHandle.standardError.write(
                Data("Note: no readable tags, using the file name: \(url.path)\n".utf8))
        }
    }
}

struct CueApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Write cue titles, performers, and track numbers into the referenced audio files (dry run unless --apply).")

    @Argument(help: "Cue sheet") var file: String
    @Flag(name: .long, help: "Actually write the files (default: only show the plan)") var apply = false
    @Flag(name: .long, help: "Output the plan as JSON") var json = false
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolvePlaylistFile(file)
        guard PlaylistFormat(url: url) == .cue else {
            throw ValidationError("Not a cue sheet: \(url.path)")
        }
        let plan: CueApply.Plan
        do {
            plan = try CueApply.plan(cueURL: url)
        } catch let error as CueApply.ApplyError {
            throw ValidationError(error.localizedDescription)
        }
        let written = apply ? try CueApply.apply(plan) : 0
        if json {
            // Nur JSON auf stdout — Skripte lesen die Ausgabe als Ganzes.
            try printJSON(Report(cue: plan.cue, items: plan.items, dryRun: !apply, written: written))
            return
        }
        for item in plan.items {
            let status = item.changedKeys.isEmpty ? "unchanged" : item.changedKeys.joined(separator: ",")
            print("\(item.number). \(item.file): \(status)")
            for key in item.changedKeys { print("    \(key)=\(item.properties[key] ?? "")") }
        }
        guard apply else {
            print("DRY RUN: \(plan.changingItems.count) file(s) would change (use --apply to write)")
            return
        }
        print("OK: \(written) file(s) changed")
    }

    struct Report: Codable {
        var cue: String
        var items: [CueApply.Item]
        var dryRun: Bool
        /// Zahl der tatsächlich geschriebenen Dateien (0 im Dry-run).
        var written: Int
    }
}

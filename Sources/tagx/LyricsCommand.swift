// tagx lyrics show/set/export/clear — unsynchronisierte Lyrics (mit Sprache
// bei ID3v2) und synchronisierte Lyrics (ID3v2 SYLT, sonst LRC-Sidecar
// `<name>.lrc` neben der Datei). Austauschformat ist LRC (`[mm:ss.xx] Text`).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Lyrics: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show, set, export, or remove lyrics (plain text with language; synchronized as SYLT or .lrc sidecar).",
        subcommands: [LyricsShow.self, LyricsSet.self, LyricsExport.self, LyricsClear.self],
        defaultSubcommand: LyricsShow.self
    )
}

/// Wo die synchronisierten Zeilen einer Datei liegen.
enum SyncedLyricsSource: String, Codable {
    /// ID3v2 SYLT-Frame in der Datei selbst.
    case embedded
    /// `<name>.lrc` neben der Datei (Formate ohne ID3v2).
    case sidecar
}

/// Synchronisierte Zeilen samt Quelle. Vorrang: eingebettete SYLT-Zeilen
/// (ID3v2), sonst die Sidecar `<name>.lrc` — auch bei ID3v2-Trägern, denn
/// `lyrics set --sidecar` legt sie dort bewusst an. Dieselbe Regel gilt für
/// show, export und clear, damit ein Sidecar-Import nie unsichtbar wird.
/// nil, wenn es nirgends welche gibt.
func loadSyncedLyrics(for url: URL, data: TagData) throws -> (lines: [SyncedLyricLine], source: SyncedLyricsSource)? {
    if data.supportsSyncedLyrics, !data.syncedLyrics.isEmpty {
        return (data.syncedLyrics, .embedded)
    }
    guard let lines = try LRC.loadSidecar(for: url), !lines.isEmpty else { return nil }
    return (lines, .sidecar)
}

/// JSON-Form von `lyrics show`.
struct LyricsReport: Codable {
    var file: String
    /// Unsynchronisierter Text (leer = keiner).
    var lyrics: String
    /// ISO 639-2 oder leer; nur ID3v2-Träger speichern sie.
    var language: String
    /// Ob die Datei SYLT und Sprache speichern kann (ID3v2).
    var supportsSynced: Bool
    var synced: [SyncedLyricLine]
    var syncedSource: SyncedLyricsSource?
    /// Pfad der Sidecar, wenn die Zeilen von dort stammen.
    var sidecar: String?
}

struct LyricsShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the lyrics (plain text; --lrc prints the synchronized lines as LRC).")

    @Argument(help: "Media file") var file: String
    @Flag(name: .long, help: "Output as JSON ({file, lyrics, language, supportsSynced, synced: [{time, text}], syncedSource})")
    var json = false
    @Flag(name: .long, help: "Print the synchronized lines as LRC instead of the plain text")
    var lrc = false

    func run() throws {
        let url = try resolveFile(file)
        let data = try TagFile.read(at: url)
        let synced = try loadSyncedLyrics(for: url, data: data)
        if json {
            try printJSON(LyricsReport(
                file: url.path, lyrics: FixedFields.lyricsText(in: data.properties),
                language: data.lyricsLanguage, supportsSynced: data.supportsSyncedLyrics,
                synced: synced?.lines ?? [], syncedSource: synced?.source,
                sidecar: synced?.source == .sidecar ? LRC.sidecarURL(for: url).path : nil))
            return
        }
        // Hinweise gehen auf stderr, damit stdout direkt in eine Datei kann.
        if lrc {
            guard let synced else {
                FileHandle.standardError.write(Data("Note: \(url.lastPathComponent) has no synchronized lyrics\n".utf8))
                return
            }
            print(LRC.render(synced.lines), terminator: "")
            return
        }
        let text = FixedFields.lyricsText(in: data.properties)
        if text.isEmpty {
            FileHandle.standardError.write(Data("Note: \(url.lastPathComponent) has no lyrics\n".utf8))
        }
        if !data.lyricsLanguage.isEmpty {
            FileHandle.standardError.write(Data("Language: \(data.lyricsLanguage)\n".utf8))
        }
        if let synced {
            FileHandle.standardError.write(
                Data("Synchronized: \(synced.lines.count) line(s) (\(synced.source.rawValue))\n".utf8))
        }
        if !text.isEmpty { print(text) }
    }
}

struct LyricsSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set lyrics from a file: .lrc = synchronized (SYLT, or .lrc sidecar for formats without ID3v2), anything else = plain text.")

    @Argument(help: "Media file") var file: String
    @Option(name: .long, help: "Lyrics file (.lrc or text); '-' reads stdin (LRC if it contains [mm:ss.xx] timestamps)")
    var from: String?
    @Option(name: .long, help: "Plain-text lyrics given directly")
    var text: String?
    @Option(name: .long, help: "Language of the lyrics, ISO 639-2 (three letters, e.g. deu); ID3v2 only")
    var language: String?
    @Flag(name: .long, help: "Write synchronized lyrics to the .lrc sidecar even if the file could hold SYLT")
    var sidecar = false
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        guard from != nil || text != nil || language != nil else {
            throw ValidationError("Provide --from FILE, --text TEXT, or --language CODE.")
        }
        if from != nil, text != nil {
            throw ValidationError("Use either --from or --text, not both.")
        }
        let url = try resolveFile(file)
        guard FixedFields.supportsLyrics(url) else {
            throw ValidationError("This format cannot store lyrics: \(url.lastPathComponent)")
        }
        // Eingaben vollständig prüfen, bevor die Datei gesichert oder angefasst wird.
        var language = self.language.map(FixedFields.normalizedLanguage)
        if let language, !FixedFields.isValidLanguage(language) {
            throw TagError.invalidFieldValue(field: "language", reason: "expected three letters (ISO 639-2), got \"\(language)\"")
        }
        var plainText = text
        var syncedLines: [SyncedLyricLine]?
        if let from {
            let (content, isLRC) = try readInput(from)
            if isLRC {
                do { syncedLines = try LRC.parse(content).lines } catch let error as TagError {
                    throw ValidationError(error.localizedDescription)
                }
            } else {
                plainText = content
            }
        }

        let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
        let existing = snapshot.value
        // Eingebettete SYLT-Zeilen haben beim Lesen Vorrang vor der Sidecar.
        // Ein erzwungener Sidecar-Import neben vorhandenem SYLT wäre für
        // show/export unsichtbar — deshalb ablehnen statt still schreiben.
        if sidecar, syncedLines != nil, existing.supportsSyncedLyrics, !existing.syncedLyrics.isEmpty {
            throw ValidationError(
                "\(url.lastPathComponent) already has embedded synchronized lyrics (SYLT); they take precedence over a sidecar. Run `lyrics clear` first or drop --sidecar.")
        }
        if language != nil, !existing.supportsSyncedLyrics {
            FileHandle.standardError.write(
                Data("Note: \(url.lastPathComponent) — this format stores no lyrics language; ignored\n".utf8))
            language = nil
        }

        // Eine LRC-Datei füllt auch den unsynchronisierten Text, wenn noch keiner da ist.
        var properties = existing.properties
        if let plainText {
            properties = FixedFields.settingLyrics(plainText, in: properties)
        } else if let syncedLines, FixedFields.lyricsText(in: properties).isEmpty {
            properties = FixedFields.settingLyrics(LRC.plainText(syncedLines), in: properties)
        }

        let useSidecar = syncedLines != nil && (sidecar || !existing.supportsSyncedLyrics)
        let embeddedLines = useSidecar ? nil : syncedLines
        let propertiesChanged = properties != existing.properties
        let languageChanged = language.map { $0 != existing.lyricsLanguage } ?? false
        let embeddedChanged = embeddedLines.map { $0 != existing.syncedLyrics } ?? false

        var messages: [String] = []
        if propertiesChanged || languageChanged || embeddedChanged {
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try TagFile.write(properties: propertiesChanged ? properties : nil,
                              syncedLyrics: embeddedChanged ? embeddedLines : nil,
                              lyricsLanguage: languageChanged ? language : nil,
                              to: url, expecting: snapshot.stamp)
            if propertiesChanged { messages.append("lyrics set") }
            if languageChanged { messages.append("language \(language ?? "")") }
            if let embeddedLines, embeddedChanged { messages.append("\(embeddedLines.count) synchronized line(s) (SYLT)") }
        } else if syncedLines == nil || !useSidecar {
            try snapshot.requireCurrent(at: url)
            messages.append("unchanged")
        }
        if useSidecar, let syncedLines {
            let sidecarURL = LRC.sidecarURL(for: url)
            // Stempel der Sidecar VOR dem Vergleich erheben: Ändert ein anderes
            // Programm die .lrc zwischen Lesen und Austausch, bricht der
            // Schreibweg ab, statt dessen Änderung zu überschreiben.
            let sidecarState = SidecarState.current(of: sidecarURL)
            if try LRC.loadSidecar(for: url) == syncedLines {
                messages.append("sidecar unchanged")
            } else {
                try LRC.writeSidecar(syncedLines, for: url, expecting: sidecarState)
                messages.append("\(syncedLines.count) synchronized line(s) → \(sidecarURL.lastPathComponent)")
            }
        }
        print("OK \(url.lastPathComponent): " + messages.joined(separator: ", "))
    }

    /// Inhalt der Eingabe und ob sie als LRC gilt: Dateien nach Endung,
    /// stdin nach Inhalt (LRC, wenn Zeitstempel drinstehen).
    private func readInput(_ source: String) throws -> (content: String, isLRC: Bool) {
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let content = String(data: data, encoding: .utf8) else {
                throw ValidationError("stdin is not UTF-8 text")
            }
            let isLRC = (try? LRC.parse(content)) != nil
            return (content, isLRC)
        }
        let inputURL = try resolveFile(source)
        guard let content = try? String(contentsOf: inputURL, encoding: .utf8) else {
            throw ValidationError("\(inputURL.lastPathComponent) is not UTF-8 text")
        }
        return (content, inputURL.pathExtension.lowercased() == "lrc")
    }
}

struct LyricsExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the lyrics to a file: .lrc when synchronized lines exist, else plain text (.txt).")

    @Argument(help: "Media file") var file: String
    @Option(name: .long, help: "Target file (default: <name>.lrc or <name>.txt next to the file)")
    var to: String?
    @Flag(name: .long, help: "Export the plain text even if synchronized lines exist")
    var txt = false

    func run() throws {
        let url = try resolveFile(file)
        let data = try TagFile.read(at: url)
        let synced = txt ? nil : try loadSyncedLyrics(for: url, data: data)
        let content: String
        let defaultTarget: URL
        if let synced {
            content = LRC.render(synced.lines)
            defaultTarget = LRC.sidecarURL(for: url)
        } else {
            content = FixedFields.lyricsText(in: data.properties)
            guard !content.isEmpty else {
                throw ValidationError("No lyrics in \(url.lastPathComponent)")
            }
            defaultTarget = url.deletingPathExtension().appendingPathExtension("txt")
        }
        let target = to.map { URL(fileURLWithPath: $0) } ?? defaultTarget
        // Auch ein Export ist ein Schreibweg: nie stillschweigend überschreiben.
        do {
            try Data(content.utf8).write(to: target, options: .withoutOverwriting)
        } catch where FileManager.default.fileExists(atPath: target.path) {
            throw ValidationError("Output file already exists: \(target.path)")
        }
        print(target.path)
    }
}

struct LyricsClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Remove plain and synchronized lyrics (SYLT or .lrc sidecar).")

    @Argument(help: "Media file") var file: String
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
        let existing = snapshot.value
        let properties = FixedFields.settingLyrics("", in: existing.properties)
        let propertiesChanged = properties != existing.properties
        let syncedChanged = existing.supportsSyncedLyrics && !existing.syncedLyrics.isEmpty
        var messages: [String] = []
        if propertiesChanged || syncedChanged {
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try TagFile.write(properties: propertiesChanged ? properties : nil,
                              syncedLyrics: syncedChanged ? [] : nil,
                              to: url, expecting: snapshot.stamp)
            messages.append("lyrics removed")
        } else {
            try snapshot.requireCurrent(at: url)
        }
        // Eine Sidecar kann auch neben einem ID3v2-Träger liegen
        // (`lyrics set --sidecar`); clear räumt beide Speicherorte.
        let sidecarState = SidecarState.current(of: LRC.sidecarURL(for: url))
        if try LRC.loadSidecar(for: url) != nil {
            try LRC.writeSidecar([], for: url, expecting: sidecarState)
            messages.append("sidecar removed")
        }
        print("OK \(url.lastPathComponent): " + (messages.isEmpty ? "no lyrics to remove" : messages.joined(separator: ", ")))
    }
}

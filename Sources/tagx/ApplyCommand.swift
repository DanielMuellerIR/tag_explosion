// tagx apply — eine Regeldatei (JSON) auf die Tags mehrerer Dateien anwenden.
//
// Per Voreinstellung ein Probelauf: Der Änderungsplan (Datei, Feld, alt →
// neu) wird nur angezeigt; erst --apply schreibt, und zwar über denselben
// Weg wie `tagx parse` (Lese-Schnappschuss, No-op-Erkennung, Papierkorb-
// Sicherung, atomarer Austausch). Exit-Codes: 0 = ok, 64 = Regeldatei
// ungültig (Meldung nennt Regelnummer und JSON-Zeile), 1 = Lese- oder
// Schreibfehler an mindestens einer Datei.
import ArgumentParser
import Foundation
import TagExplosionCore

/// Exit-Code für eine unbrauchbare Regeldatei — wie EX_USAGE in sysexits.h
/// und derselbe Code, den ArgumentParser für Eingabefehler benutzt.
let usageExitCode = ExitCode(64)

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a JSON rules file to the tags of files/folders (dry run unless --apply).",
        discussion: """
            Rules run in order: set (with %{artist}-style placeholders), copy, replace \
            (literal or regex with $1 groups), case (upper, lower, title, sentence), trim, \
            remove and number (track numbers in sort order). Each rule may be limited to \
            media kinds and a field condition. `tagx apply --example` prints a commented \
            example file. The preview lists every change as FIELD: old -> new; nothing is \
            written without --apply. Writing uses the same safe path as `tagx set` \
            (trash copy, atomic replace).
            """
    )

    @Argument(help: "Rules file (JSON); see --example") var rules: String?
    @Argument(help: "Media files or folders (recursive)") var paths: [String] = []
    @Flag(name: .long, help: "Actually write the changes (default: preview only)") var apply = false
    @Flag(name: .long, help: "Output as JSON") var json = false
    @Flag(name: .long, help: "Print an example rules file and exit") var example = false
    @OptionGroup var safeMode: SafeModeOptions

    /// Eine Datei im Bericht: geplante Änderungen, nach --apply die Zahl der
    /// geschriebenen Felder oder der Fehler.
    struct Item: Codable {
        var file: String
        var kind: MediaFormats.Kind
        var changes: [TagFieldChange]
        var changed: Int?
        var error: String?
    }

    struct Report: Codable {
        var rules: String
        var applied: Bool
        var items: [Item]
    }

    func run() throws {
        if example {
            print(TagRulesIO.exampleJSON)
            return
        }
        safeMode.apply()
        guard let rules else { throw ValidationError("Provide a rules file (or --example).") }
        guard !paths.isEmpty else { throw ValidationError("Provide at least one file or folder.") }

        let rulesURL = try resolveFile(rules)
        let document: TagRuleDocument
        do {
            document = try TagRulesIO.load(rulesURL)
        } catch let error as TagRulesError {
            // Bewusst kein ValidationError: Der hängt die Befehlshilfe an,
            // die bei einer kaputten Regeldatei nicht weiterhilft.
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw usageExitCode
        }

        // Dateien einsammeln: explizit genannte Dateien müssen taggbar sein;
        // aus Ordnern werden nur die taggbaren Medien genommen (wie export).
        var files: [URL] = []
        for path in paths {
            let url = try resolveFile(path)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                files += MediaFormats.expandMediaFiles([url]).filter { MediaFormats.isArchivable(url: $0) }
            } else {
                guard MediaFormats.isArchivable(url: url) else {
                    throw ValidationError("Not a taggable media file: \(url.path)")
                }
                files.append(url)
            }
        }
        guard !files.isEmpty else { throw ValidationError("No taggable media files found.") }

        // Erst alle Dateien lesen; eine unlesbare Datei landet als Fehler im
        // Bericht und blockiert die anderen nicht.
        var seen = Swift.Set<URL>()
        files = files.filter { seen.insert($0).inserted }
        var stamps: [URL: FileStamp] = [:]
        var items: [Item] = []
        var inputs: [TagRuleInput] = []
        var readErrors: [String: String] = [:]
        for url in files {
            let kind = MediaFormats.kind(of: url) ?? .audio
            do {
                let snapshot = try FileSnapshot.capture(at: url) {
                    if kind == .audio { return TagRuleFields.values(from: try TagFile.read(at: url).properties) }
                    return try readPatternFields(at: url).mapValues { [$0] }
                }
                stamps[url] = snapshot.stamp
                inputs.append(TagRuleInput(url: url, kind: kind, values: snapshot.value))
            } catch {
                readErrors[url.path] = Self.describe(error)
                items.append(Item(file: url.path, kind: kind, changes: [], changed: nil,
                                  error: readErrors[url.path]))
            }
        }
        let plans = try TagRuleEngine.plan(document, inputs: inputs)
        items += plans.map { Item(file: $0.url.path, kind: $0.kind, changes: $0.changes, changed: nil, error: nil) }
        // Bericht in der Reihenfolge der Eingabe, nicht „Fehler zuerst".
        let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        items.sort { (order[$0.file] ?? 0) < (order[$1.file] ?? 0) }

        guard apply else {
            if json {
                try printJSON(Report(rules: rulesURL.path, applied: false, items: items))
            } else {
                for item in items { printPreview(item) }
                let changed = items.filter { !$0.changes.isEmpty }.count
                print("Dry run: \(changed) file(s) to change, \(items.count - changed - readErrors.count) unchanged, "
                      + "\(readErrors.count) error(s) — use --apply to write")
            }
            if !readErrors.isEmpty { throw ExitCode(1) }
            return
        }

        var failed = !readErrors.isEmpty
        for index in items.indices where items[index].error == nil {
            guard !items[index].changes.isEmpty else {
                items[index].changed = 0
                continue
            }
            let url = URL(fileURLWithPath: items[index].file)
            let newValues = Dictionary(uniqueKeysWithValues: items[index].changes.map { ($0.field, $0.new) })
            do {
                if let stamp = stamps[url] { try FileStamp.requireUnchanged(stamp, at: url) }
                let values = Dictionary(uniqueKeysWithValues: items[index].changes.map { ($0.field, $0.allNewValues) })
                items[index].changed = try Parse.write(fields: newValues, to: url, ruleValues: values, expecting: stamps[url])
            } catch {
                items[index].error = Self.describe(error)
                failed = true
            }
        }
        if json {
            try printJSON(Report(rules: rulesURL.path, applied: true, items: items))
        } else {
            for item in items {
                let name = URL(fileURLWithPath: item.file).lastPathComponent
                if let error = item.error {
                    print("FAILED \(item.file): \(error)")
                } else {
                    print("OK \(name): \(item.changed ?? 0) field(s) changed")
                }
            }
            let written = items.filter { $0.error == nil && ($0.changed ?? 0) > 0 }.count
            print("Applied to \(written) of \(items.count) file(s)")
        }
        if failed { throw ExitCode(1) }
    }

    private func printPreview(_ item: Item) {
        if let error = item.error {
            print("ERROR \(item.file): \(error)")
            return
        }
        guard !item.changes.isEmpty else {
            print("UNCHANGED \(item.file)")
            return
        }
        print("CHANGE \(item.file)")
        for change in item.changes {
            let target = change.newDisplay.isEmpty ? "(remove)" : change.newDisplay
            print("  \(change.field): \(change.oldDisplay) -> \(target)")
        }
    }

    /// ArgumentParsers `ValidationError` trägt seinen Text in `message`;
    /// `localizedDescription` wäre dort nur ein generischer Satz.
    private static func describe(_ error: Error) -> String {
        if let validation = error as? ValidationError { return validation.message }
        return error.localizedDescription
    }
}

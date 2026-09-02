// tagx rename / tagx parse — Dateiname ↔ Tags über Muster im kid3-Stil.
//
// Beide Befehle sind per Voreinstellung ein Probelauf (dry run) und ändern
// erst mit --apply etwas. Exit-Codes: 0 = ok, 1 = Fehler, 2 = Konflikt oder
// Muster passt nicht (dann wird bewusst NICHTS geändert, auch nicht die
// Dateien ohne Konflikt — halb umbenannte Alben sind schlimmer als keine).
import ArgumentParser
import Foundation
import TagExplosionCore

/// Exit-Code für „Vorschau zeigt Konflikte" beziehungsweise „Muster passt
/// nicht" — unterscheidbar von echten Fehlern (1), damit Skripte reagieren können.
let conflictExitCode = ExitCode(2)

/// Kurzhilfe zu den Platzhaltern, in beiden Befehlen gleich.
private let patternHelp = """
    Pattern with placeholders such as %{artist}, %{title}, %{album}, %{albumartist}, \
    %{track}, %{disc}, %{year}, %{genre}, %{composer}, %{comment} or any tag key \
    (%{isrc}). %{track:2} pads numbers with zeros. Images: %{title}, %{creator} \
    (also %{artist}), %{description}, %{keywords}, %{copyright}, %{date}/%{year}. \
    E-books: %{title}, %{author}, %{series}, %{seriesindex} (also %{track}), \
    %{publisher}, %{language}, %{isbn}, %{date}/%{year}, %{subjects} (also %{genre}).
    """

/// Liest die Feldwerte einer Datei passend zu ihrer Medienart.
func readPatternFields(at url: URL) throws -> [String: String] {
    switch MediaFormats.kind(of: url) {
    case .audio:
        return PatternFields.fields(from: try TagFile.read(at: url))
    case .image:
        return PatternFields.fields(from: try ExifTool.readCoreFields(url: url))
    case .ebook:
        return PatternFields.fields(
            from: try EbookTool.readSnapshot(url: url, includeCover: false).value.fields)
    case .invoice, nil:
        throw ValidationError("Not a taggable media file: \(url.path)")
    }
}

/// Muster aus der Kommandozeile lesen; Fehler als Eingabefehler melden.
func parsePattern(_ text: String) throws -> FilenamePattern {
    do {
        return try FilenamePattern(text)
    } catch let error as FilenamePattern.ParseError {
        throw ValidationError(error.localizedDescription)
    }
}

// MARK: - rename

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rename files from their tags using a pattern (dry run unless --apply).",
        discussion: """
            Files stay in their folder; only the name changes, the extension is kept. \
            The preview lists every file as RENAME, KEEP or CONFLICT. Conflicts \
            (two files with the same target, a target that already exists, an empty \
            name) block the whole run with exit code 2.
            """
    )

    @Option(name: .shortAndLong, help: ArgumentHelp("Rename pattern", discussion: patternHelp))
    var pattern: String
    @Argument(help: "Media file(s)") var files: [String]
    @Flag(name: .long, help: "Actually rename (default: preview only)") var apply = false
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var pattern: String
        var applied: Bool
        var items: [FileRenamer.Item]
        /// Nur nach --apply: je umbenannter Datei das Ergebnis.
        var results: [FileRenamer.Outcome]?
    }

    func run() throws {
        let compiled = try parsePattern(pattern)
        guard !files.isEmpty else { throw ValidationError("Provide at least one file.") }
        let requests = try files.map { path -> FileRenamer.Request in
            let url = try resolveFile(path)
            return FileRenamer.Request(url: url, fields: try readPatternFields(at: url))
        }
        let plan = FileRenamer.plan(requests, pattern: compiled)

        guard apply, !plan.hasConflicts else {
            // Vorschau (oder --apply mit Konflikten: dann zeigt die Vorschau,
            // woran es hängt, und nichts wird angefasst).
            if json {
                try printJSON(Report(pattern: pattern, applied: false, items: plan.items, results: nil))
            } else {
                printPlan(plan)
                let summary = "\(plan.renames.count) to rename, "
                    + "\(plan.items.count - plan.renames.count - plan.conflicts.count) unchanged, "
                    + "\(plan.conflicts.count) conflict(s)"
                print(apply ? "Nothing renamed: \(summary)" : "Dry run: \(summary) — use --apply to rename")
            }
            if plan.hasConflicts { throw conflictExitCode }
            return
        }

        let outcomes = try FileRenamer.apply(plan)
        if json {
            try printJSON(Report(pattern: pattern, applied: true, items: plan.items, results: outcomes))
        } else {
            for outcome in outcomes {
                if let error = outcome.error {
                    print("FAILED \(outcome.source): \(error)")
                } else {
                    var line = "OK \(outcome.source) -> \(URL(fileURLWithPath: outcome.target).lastPathComponent)"
                    if let sidecar = outcome.sidecarTarget {
                        line += " (+ sidecar \(URL(fileURLWithPath: sidecar).lastPathComponent))"
                    }
                    print(line)
                }
            }
            print("Renamed \(outcomes.filter(\.succeeded).count) of \(outcomes.count) file(s)")
        }
        if outcomes.contains(where: { !$0.succeeded }) { throw ExitCode(1) }
    }

    private func printPlan(_ plan: FileRenamer.Plan) {
        for item in plan.items {
            switch item.status {
            case .rename:
                var line = "RENAME \(item.source) -> \(item.target)"
                if let sidecarSource = item.sidecarSource, let sidecarTarget = item.sidecarTarget {
                    line += " (+ sidecar \(URL(fileURLWithPath: sidecarSource).lastPathComponent) -> \(sidecarTarget))"
                }
                print(line)
            case .unchanged: print("KEEP \(item.source)")
            case .conflict: print("CONFLICT \(item.source) -> \(item.target): \(item.reason ?? "")")
            }
        }
    }
}

// MARK: - parse

struct Parse: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set tags from the file name using a pattern (dry run unless --apply).",
        discussion: """
            Text between placeholders must appear literally in the file name; \
            %{track}, %{disc} and %{year} match digits only. A file that does not \
            match the pattern blocks the whole run with exit code 2. Writing uses \
            the same safe path as `tagx set` (trash copy, atomic replace).
            """
    )

    @Option(name: .shortAndLong, help: ArgumentHelp("Parse pattern", discussion: patternHelp))
    var pattern: String
    @Argument(help: "Media file(s)") var files: [String]
    @Flag(name: .long, help: "Actually write the tags (default: preview only)") var apply = false
    @Flag(name: .long, help: "Output as JSON") var json = false
    @OptionGroup var safeMode: SafeModeOptions

    struct Item: Codable {
        var file: String
        var matched: Bool
        var fields: [String: String]
        /// Nur nach --apply: Zahl der wirklich geänderten Felder.
        var changed: Int?
        var error: String?
    }

    struct Report: Codable {
        var pattern: String
        var applied: Bool
        var items: [Item]
    }

    func run() throws {
        safeMode.apply()
        let compiled = try parsePattern(pattern)
        guard !files.isEmpty else { throw ValidationError("Provide at least one file.") }

        // Erst alle Dateien lesen und parsen; geschrieben wird erst, wenn
        // jedes Muster passt.
        var items: [Item] = []
        for path in files {
            let url = try resolveFile(path)
            guard MediaFormats.kind(of: url) != nil, MediaFormats.kind(of: url) != .invoice else {
                throw ValidationError("Not a taggable media file: \(url.path)")
            }
            let stem = url.deletingPathExtension().lastPathComponent
            let parsed = compiled.extract(fromStem: stem)
            items.append(Item(file: url.path, matched: parsed != nil, fields: parsed ?? [:],
                              changed: nil, error: nil))
        }
        let unmatched = items.filter { !$0.matched }

        guard apply, unmatched.isEmpty else {
            if json {
                try printJSON(Report(pattern: pattern, applied: false, items: items))
            } else {
                for item in items { printPreview(item) }
                if !unmatched.isEmpty {
                    print("Nothing written: \(unmatched.count) file(s) do not match the pattern")
                } else {
                    print("Dry run: \(items.count) file(s) — use --apply to write the tags")
                }
            }
            if !unmatched.isEmpty { throw conflictExitCode }
            return
        }

        var failed = false
        for index in items.indices {
            let url = URL(fileURLWithPath: items[index].file)
            do {
                items[index].changed = try Self.write(fields: items[index].fields, to: url)
            } catch {
                items[index].error = error.localizedDescription
                failed = true
            }
        }
        if json {
            try printJSON(Report(pattern: pattern, applied: true, items: items))
        } else {
            for item in items {
                if let error = item.error {
                    print("FAILED \(item.file): \(error)")
                } else {
                    print("OK \(URL(fileURLWithPath: item.file).lastPathComponent): \(item.changed ?? 0) field(s) changed")
                }
            }
        }
        if failed { throw ExitCode(1) }
    }

    private func printPreview(_ item: Item) {
        guard item.matched else {
            print("NOMATCH \(item.file)")
            return
        }
        let assignments = item.fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("\(item.file): \(assignments)")
    }

    /// Schreibt die geparsten Werte auf dem bestehenden Weg der Medienart:
    /// Lese-Schnappschuss, No-op-Erkennung, Papierkorb-Sicherung, atomarer
    /// Austausch. Liefert die Zahl der geänderten Felder.
    static func write(fields parsed: [String: String], to url: URL) throws -> Int {
        switch MediaFormats.kind(of: url) {
        case .audio:
            let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
            var properties = snapshot.value.properties
            PatternFields.apply(parsed, to: &properties)
            let before = valueMap(snapshot.value.properties)
            let after = valueMap(properties)
            let changed = Swift.Set(before.keys).union(after.keys)
                .filter { (before[$0] ?? []) != (after[$0] ?? []) }
            guard !changed.isEmpty else {
                try snapshot.requireCurrent(at: url)
                return 0
            }
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try TagFile.write(properties: properties, to: url, expecting: snapshot.stamp)
            return changed.count

        case .image:
            let snapshot = try ExifTool.readCoreFieldsSnapshot(url: url)
            let original = snapshot.value.fields
            var fields = original
            do {
                try PatternFields.apply(parsed, to: &fields)
                try ExifTool.requireValidCoreFields(fields, original: original)
            } catch let error as PatternFields.ApplyError {
                throw ValidationError(error.localizedDescription)
            } catch let error as ImageMetadataValidationError {
                throw ValidationError(error.localizedDescription)
            }
            guard fields != original else {
                try snapshot.requireCurrent(at: url)
                return 0
            }
            try snapshot.requireCurrent(at: url)
            // Kamera-RAW, bmp/svg und eine vorhandene Sidecar schreiben in die
            // XMP-Sidecar; gesichert wird dann diese (siehe `tagx exif set`).
            let destination = ExifTool.writeDestination(for: url, preferSidecar: false)
            try TrashBackup.shared.backUp(destination.url)
            try ExifTool.writeCoreFields(url: url, fields: fields, original: original,
                                         expecting: snapshot.stamp, to: destination,
                                         sidecar: snapshot.value.sidecar)
            return parsed.count

        case .ebook:
            let snapshot = try EbookTool.readSnapshot(url: url, includeCover: false)
            let original = snapshot.value.fields
            var fields = original
            do {
                try PatternFields.apply(parsed, to: &fields)
            } catch let error as PatternFields.ApplyError {
                throw ValidationError(error.localizedDescription)
            }
            if !EbookTool.supportsSeries(url: url),
               fields.series != original.series || fields.seriesIndex != original.seriesIndex {
                throw ValidationError("This format cannot store a series (PDF).")
            }
            do {
                try EbookTool.requireStorableSeries(fields, original: original, url: url)
            } catch TagError.seriesIndexWithoutSeries {
                throw ValidationError("A series index needs a series name (%{series}).")
            }
            guard fields != original else {
                try snapshot.requireCurrent(at: url)
                return 0
            }
            try snapshot.requireCurrent(at: url)
            try TrashBackup.shared.backUp(url)
            try EbookTool.write(url: url, fields: fields, original: original,
                                coverUpdate: .unchanged, expecting: snapshot.stamp)
            return parsed.count

        case .invoice, nil:
            throw ValidationError("Not a taggable media file: \(url.path)")
        }
    }

    /// Schlüssel → alle Werte, reihenfolgeunabhängig vergleichbar.
    private static func valueMap(_ properties: [TagProperty]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for property in properties { map[property.key, default: []].append(property.value) }
        return map
    }
}

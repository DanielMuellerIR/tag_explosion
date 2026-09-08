// Dateiname ↔ Tags in der App: Feldwerte der Einträge für die Muster-Engine,
// Umbenennen über das Modell (Liste und Auswahl folgen dem neuen Pfad) und
// das Übertragen geparster Werte in die Bearbeitungspuffer.
import Foundation
import TagExplosionCore

extension FileEntry {
    /// Feldwerte für die Muster-Engine — aus dem Bearbeitungspuffer, damit
    /// die Vorschau genau das zeigt, was gerade in den Feldern steht.
    var patternFields: [String: String] {
        switch kind {
        case .audio: return PatternFields.fields(from: properties)
        case .image: return PatternFields.fields(from: imageFields)
        case .ebook: return PatternFields.fields(from: ebookFields)
        case .document: return PatternFields.fields(from: documentFields)
        case .sidecar:
            switch sidecarContents {
            case .nfo: return PatternFields.fields(from: nfoFields)
            case .subtitle(let subtitle): return PatternFields.fields(from: subtitle, url: url)
            case nil: return [:]
            }
        case .invoice, .playlist: return [:]
        }
    }

    /// Rechnungen sind reine Anzeige, Playlists tragen keine Tags im Sinne
    /// der Muster: kein Umbenennen aus Tags, keine Tags aus dem Dateinamen.
    var supportsFilenamePatterns: Bool { kind != .invoice && kind != .playlist }

    /// Überträgt aus dem Dateinamen geparste Werte in den Bearbeitungspuffer.
    /// Der Eintrag wird dadurch „dirty" und läuft beim Speichern über den
    /// gewohnten Weg (Sicherung, atomarer Austausch). Wirft, wenn ein
    /// Schlüssel für diese Medienart kein Feld hat.
    func applyParsedFields(_ parsed: [String: String]) throws {
        switch kind {
        case .audio: PatternFields.apply(parsed, to: &properties)
        case .image: try PatternFields.apply(parsed, to: &imageFields)
        case .ebook: try PatternFields.apply(parsed, to: &ebookFields)
        case .document: try PatternFields.apply(parsed, to: &documentFields)
        case .sidecar:
            // Nur NFO-Felder haben einen Speicherort; Untertitel tragen die
            // Sprache im Dateinamen (Richtung „Umbenennen").
            guard case .nfo(let nfo) = sidecarContents, !nfo.isURLOnly else {
                throw PatternFields.ApplyError.unsupportedField(
                    key: parsed.keys.sorted().first ?? "", kind: "subtitle")
            }
            try PatternFields.apply(parsed, to: &nfoFields)
        case .invoice, .playlist:
            throw PatternFields.ApplyError.unsupportedField(
                key: parsed.keys.sorted().first ?? "", kind: kind.rawValue)
        }
    }
}

/// Zuletzt benutzte Muster, getrennt je Richtung, plus ein paar Vorgaben.
enum PatternHistory {
    enum Direction {
        case rename
        case parse

        var defaultsKey: String {
            switch self {
            case .rename: return "filenamePatternHistoryRename"
            case .parse: return "filenamePatternHistoryParse"
            }
        }
    }

    static let maxEntries = 8

    /// Vorgaben, die für beide Richtungen taugen.
    static let presets: [String] = [
        "%{track:2} - %{title}",
        "%{artist} - %{title}",
        "%{track:2} - %{artist} - %{title}",
        "%{albumartist} - %{album} - %{track:2} - %{title}",
        "%{disc}-%{track:2} %{title}",
    ]

    static func load(_ direction: Direction) -> [String] {
        UserDefaults.standard.stringArray(forKey: direction.defaultsKey) ?? []
    }

    /// Merkt sich ein Muster vorn in der Liste (ohne Dubletten, gedeckelt).
    static func remember(_ pattern: String, _ direction: Direction) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var history = load(direction).filter { $0 != trimmed }
        history.insert(trimmed, at: 0)
        UserDefaults.standard.set(Array(history.prefix(maxEntries)), forKey: direction.defaultsKey)
    }

    /// Startwert für das Musterfeld: das zuletzt benutzte, sonst die erste Vorgabe.
    static func initialPattern(_ direction: Direction) -> String {
        load(direction).first ?? presets[0]
    }
}

extension AppModel {

    /// Vorschau: alter Name → neuer Name je Eintrag, mit Konflikten.
    func renamePlan(for targets: [FileEntry], pattern: FilenamePattern) -> FileRenamer.Plan {
        FileRenamer.plan(
            targets.filter(\.supportsFilenamePatterns)
                .map { FileRenamer.Request(url: $0.url, fields: $0.patternFields) },
            pattern: pattern)
    }

    /// Benennt die Dateien der Einträge nach dem Muster um. Ungespeicherte
    /// Änderungen werden vorher über den gewohnten Speichern/Verwerfen/
    /// Abbrechen-Dialog geklärt: Der neue Name soll zu dem passen, was
    /// wirklich in der Datei steht — nicht zu einem Puffer, der beim
    /// Verwerfen wieder verschwindet.
    func renameFiles(_ targets: [FileEntry], pattern: FilenamePattern) async {
        guard !isDestructiveActionLocked else { return }
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Umbenennen müssen die Änderungen gespeichert oder verworfen werden."),
            entries: targets,
            perform: { [weak self] in
                await self?.performRename(targets, pattern: pattern)
            }
        )
    }

    /// Plant nach der Konfliktklärung erneut — jetzt aus dem Plattenstand —
    /// und führt aus. Ein Plan mit Konflikten wird komplett abgelehnt.
    private func performRename(_ targets: [FileEntry], pattern: FilenamePattern) async {
        let plan = renamePlan(for: targets, pattern: pattern)
        guard !plan.hasConflicts else {
            alertMessage = String(localized: "Umbenennen abgebrochen — Konflikte:") + "\n"
                + plan.conflicts.map {
                    "\(URL(fileURLWithPath: $0.source).lastPathComponent): \($0.reason ?? "")"
                }.joined(separator: "\n")
            return
        }
        guard !plan.renames.isEmpty else { return }

        let outcomes: [FileRenamer.Outcome]
        do {
            outcomes = try await Task.detached(priority: .userInitiated) {
                try FileRenamer.apply(plan)
            }.value
        } catch {
            alertMessage = String(localized: "Umbenennen fehlgeschlagen:") + "\n" + error.localizedDescription
            return
        }

        applyRenameOutcomes(outcomes)
    }

    /// Einträge folgen erfolgreichen Umzügen auch bei einem Journalfehler;
    /// dessen Warnung bleibt sichtbar, damit die Historie nicht sicher erscheint.
    func applyRenameOutcomes(_ outcomes: [FileRenamer.Outcome]) {
        var failures: [String] = []
        var warnings: [String] = []
        for outcome in outcomes {
            if let warning = outcome.warning {
                warnings.append("\(URL(fileURLWithPath: outcome.source).lastPathComponent): \(warning)")
            }
            guard outcome.succeeded else {
                failures.append("\(URL(fileURLWithPath: outcome.source).lastPathComponent): \(outcome.error ?? "")")
                continue
            }
            relocateEntry(from: URL(fileURLWithPath: outcome.source),
                          to: URL(fileURLWithPath: outcome.target),
                          sidecar: outcome.sidecarTarget.map { URL(fileURLWithPath: $0) })
        }
        var messages = warnings
        if !failures.isEmpty {
            messages.insert(String(localized: "Nicht alle Dateien konnten umbenannt werden:") + "\n"
                + failures.joined(separator: "\n"), at: 0)
        }
        if !messages.isEmpty { alertMessage = messages.joined(separator: "\n") }
    }

    /// Ersetzt den Eintrag einer umbenannten Datei durch denselben Eintrag
    /// unter neuem Pfad — an derselben Stelle der Liste, Auswahl inklusive.
    /// Die Fenster-Registry (`WindowSessions`) kennt nur Modelle, keine
    /// Pfade; Fenstertitel und `representedURL` leiten sich aus dem Eintrag
    /// ab und folgen damit automatisch.
    /// `sidecar`: neuer Pfad der mit umbenannten XMP-Sidecar, damit der
    /// Eintrag seine Sidecar weiter unter dem richtigen Namen kennt.
    func relocateEntry(from oldURL: URL, to newURL: URL, sidecar: URL? = nil) {
        let canonicalOld = MediaFormats.canonicalFileURL(oldURL)
        guard let index = entries.firstIndex(where: {
            MediaFormats.canonicalFileURL($0.url) == canonicalOld
        }) else { return }
        let old = entries[index]
        guard let moved = FileEntry(relocating: old, to: newURL, sidecar: sidecar) else { return }
        entries[index] = moved
        if selection.remove(old.url) != nil {
            selection.insert(moved.url)
        }
    }

    /// Ergebnis von „Tags aus Dateiname" für die Rückmeldung.
    struct ParseOutcome: Equatable {
        var applied = 0
        /// Dateinamen, auf die das Muster nicht passt.
        var unmatched: [String] = []
        /// Dateien, deren Medienart ein geparstes Feld nicht kennt.
        var failed: [String] = []
    }

    /// Überträgt die aus dem Dateinamen gelesenen Werte in die Puffer der
    /// Einträge. Geschrieben wird nichts — das erledigt das normale Speichern.
    @discardableResult
    func applyFileNamePattern(_ pattern: FilenamePattern, to targets: [FileEntry]) -> ParseOutcome {
        var outcome = ParseOutcome()
        for entry in targets where entry.supportsFilenamePatterns {
            let stem = entry.url.deletingPathExtension().lastPathComponent
            guard let parsed = pattern.extract(fromStem: stem) else {
                outcome.unmatched.append(entry.url.lastPathComponent)
                continue
            }
            do {
                try entry.applyParsedFields(parsed)
                outcome.applied += 1
            } catch {
                outcome.failed.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !outcome.unmatched.isEmpty || !outcome.failed.isEmpty {
            var lines: [String] = []
            if !outcome.unmatched.isEmpty {
                lines.append(String(localized: "Muster passt nicht auf:") + "\n"
                             + outcome.unmatched.joined(separator: "\n"))
            }
            if !outcome.failed.isEmpty {
                lines.append(String(localized: "Nicht übernommen:") + "\n"
                             + outcome.failed.joined(separator: "\n"))
            }
            alertMessage = lines.joined(separator: "\n\n")
        }
        return outcome
    }
}

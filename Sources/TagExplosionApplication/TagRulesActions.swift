// Batch-Regeln in der App: Vorschau-Plan aus den Bearbeitungspuffern,
// Übernahme in die Puffer und Speichern über den gewohnten Weg, dazu die
// Liste der zuletzt benutzten Regeldateien. Die Regel-Logik selbst liegt im
// Core (`TagRuleEngine`); hier steht nur die Anbindung ans Modell.
import Foundation
import TagExplosionCore

/// Zuletzt geladene oder gespeicherte Regeldateien (Pfade in UserDefaults,
/// neueste zuerst, gedeckelt). Nicht mehr vorhandene Dateien fallen beim
/// Laden der Liste heraus.
public enum RuleFileHistory {
    public static let defaultsKey = "tagRuleFileHistory"
    public static let maxEntries = 8

    public static func load(defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: defaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func remember(_ url: URL, defaults: UserDefaults = .standard) {
        var paths = (defaults.stringArray(forKey: defaultsKey) ?? [])
            .filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(maxEntries)), forKey: defaultsKey)
    }
}

/// Ergebnis der Übernahme eines Regelplans in die Bearbeitungspuffer.
public struct RuleApplyOutcome: Equatable {
    public init(failed: [String] = [], appliedURLs: Set<URL> = []) {
        self.failed = failed; self.appliedURLs = appliedURLs
    }
    /// Einträge, deren Puffer sich geändert hat.
    public var changed: Int { appliedURLs.count }
    /// Dateiname plus Fehler — Felder, die die Medienart nicht kennt.
    public var failed: [String] = []
    /// Nur diese Einträge haben den Plan übernommen und dürfen gespeichert werden.
    public var appliedURLs: Set<URL> = []
}

extension AppModel {

    /// Sendbarer Schnappschuss der Editorpuffer für die Regelauswertung.
    public func ruleInputs(for targets: [FileEntry]) -> [TagRuleInput] {
        targets.filter(\.supportsFilenamePatterns).map { entry in
            let values = entry.kind == .audio
                ? TagProperty.valuesByKey(entry.properties) : entry.patternFields.mapValues { [$0] }
            return TagRuleInput(url: entry.url, kind: entry.kind, values: values)
        }
    }

    public nonisolated static func rulePlan(for inputs: [TagRuleInput], document: TagRuleDocument) throws -> [TagRulePlan] {
        return try TagRuleEngine.plan(document, inputs: inputs).filter { !$0.changes.isEmpty }
    }

    public func rulePlan(for targets: [FileEntry], document: TagRuleDocument) throws -> [TagRulePlan] {
        try Self.rulePlan(for: ruleInputs(for: targets), document: document)
    }

    /// Überträgt einen Plan in die Bearbeitungspuffer der Einträge. Die
    /// Einträge werden dadurch „dirty"; ein Feld, das die Medienart nicht
    /// kennt (z.B. ALBUM bei einem Bild), landet in `failed` und lässt den
    /// Eintrag unverändert.
    public func applyRulePlan(_ plans: [TagRulePlan], to targets: [FileEntry]) -> RuleApplyOutcome {
        var outcome = RuleApplyOutcome()
        let byURL = Dictionary(uniqueKeysWithValues: targets.map { ($0.url, $0) })
        for plan in plans where !plan.changes.isEmpty {
            guard let entry = byURL[plan.url] else { continue }
            do {
                if entry.kind == .audio {
                    TagRuleFields.apply(Dictionary(uniqueKeysWithValues: plan.changes.map {
                        ($0.field, $0.allNewValues)
                    }), to: &entry.properties)
                } else {
                    try entry.applyParsedFields(plan.newValues)
                }
                outcome.appliedURLs.insert(entry.url)
            } catch {
                outcome.failed.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Anwenden-Knopf: Plan berechnen, Puffer füllen, dann über den gemeinsamen
    /// Speicherweg schreiben (Auto-Backup, Papierkorb-Sicherung, atomarer
    /// Austausch — alles wie beim normalen Speichern). false = nichts
    /// geschrieben oder mindestens eine Datei fehlgeschlagen.
    @discardableResult
    public func applyRules(_ document: TagRuleDocument, to targets: [FileEntry]) async -> Bool {
        await applyRules(document, to: targets) { await self.saveEntries($0) }
    }

    /// Der austauschbare Speicheraufruf prüft die Auswahl der Dateien,
    /// ohne für einen abgelehnten Regelsatz echte Medien schreiben zu müssen.
    public func applyRules(_ document: TagRuleDocument, to targets: [FileEntry],
                    save: ([FileEntry]) async -> Bool) async -> Bool {
        guard !isDestructiveActionLocked else { return false }
        let inputs = ruleInputs(for: targets)
        guard let plans = await prepareRules(document, inputs: inputs) else { return false }
        return await applyPreparedRules(plans, matching: inputs, to: targets, save: save)
    }

    func prepareRules(_ document: TagRuleDocument, inputs: [TagRuleInput]) async -> [TagRulePlan]? {
        do {
            let plans = try await BlockingWork.run { try Self.rulePlan(for: inputs, document: document) }
            try Task.checkCancellation()
            return plans
        } catch {
            alertMessage = String(localized: "Regeln konnten nicht angewendet werden:")
                + "\n" + error.localizedDescription
            return nil
        }
    }

    /// Übernimmt die sichtbare Vorschau erst nach einem erneuten Abgleich der
    /// Eingaben. Planung und Übernahme können verschiedene Actor-Turns sein.
    public func applyPreparedRules(_ plans: [TagRulePlan], matching inputs: [TagRuleInput],
                                   to targets: [FileEntry]) async -> Bool {
        let currentEntries = Set(entries.map(ObjectIdentifier.init))
        guard targets.allSatisfy({ currentEntries.contains(ObjectIdentifier($0)) }) else { return false }
        return await applyPreparedRules(plans, matching: inputs, to: targets) { await self.saveEntries($0) }
    }

    private func applyPreparedRules(_ plans: [TagRulePlan], matching inputs: [TagRuleInput],
                                    to targets: [FileEntry], save: ([FileEntry]) async -> Bool) async -> Bool {
        guard !isDestructiveActionLocked, inputs == ruleInputs(for: targets) else { return false }
        let outcome = applyRulePlan(plans, to: targets)
        if !outcome.failed.isEmpty {
            alertMessage = String(localized: "Nicht übernommen:") + "\n"
                + outcome.failed.joined(separator: "\n")
        }
        let dirty = targets.filter { outcome.appliedURLs.contains($0.url) && $0.isDirty }
        guard !dirty.isEmpty else { return outcome.failed.isEmpty }
        let saved = await save(dirty)
        return saved && outcome.failed.isEmpty
    }
}

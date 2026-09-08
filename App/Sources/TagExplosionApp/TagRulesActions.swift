// Batch-Regeln in der App: Vorschau-Plan aus den Bearbeitungspuffern,
// Übernahme in die Puffer und Speichern über den gewohnten Weg, dazu die
// Liste der zuletzt benutzten Regeldateien. Die Regel-Logik selbst liegt im
// Core (`TagRuleEngine`); hier steht nur die Anbindung ans Modell.
import Foundation
import TagExplosionCore

/// Zuletzt geladene oder gespeicherte Regeldateien (Pfade in UserDefaults,
/// neueste zuerst, gedeckelt). Nicht mehr vorhandene Dateien fallen beim
/// Laden der Liste heraus.
enum RuleFileHistory {
    static let defaultsKey = "tagRuleFileHistory"
    static let maxEntries = 8

    static func load() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func remember(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            .filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(maxEntries)), forKey: defaultsKey)
    }
}

/// Ergebnis der Übernahme eines Regelplans in die Bearbeitungspuffer.
struct RuleApplyOutcome: Equatable {
    /// Einträge, deren Puffer sich geändert hat.
    var changed: Int { appliedURLs.count }
    /// Dateiname plus Fehler — Felder, die die Medienart nicht kennt.
    var failed: [String] = []
    /// Nur diese Einträge haben den Plan übernommen und dürfen gespeichert werden.
    var appliedURLs: Set<URL> = []
}

extension AppModel {

    /// Vorschau: je Eintrag die geplanten Änderungen (nur Einträge mit
    /// Änderungen). Grundlage sind die Bearbeitungspuffer, damit die Tabelle
    /// zeigt, was der Anwenden-Knopf wirklich tut. Wirft bei einer
    /// ungültigen Regel (`TagRulesError`).
    func rulePlan(for targets: [FileEntry], document: TagRuleDocument) throws -> [TagRulePlan] {
        let inputs = targets.filter(\.supportsFilenamePatterns).map {
            TagRuleInput(url: $0.url, kind: $0.kind, values: $0.kind == .audio ? TagProperty.valuesByKey($0.properties) : $0.patternFields.mapValues { [$0] })
        }
        return try TagRuleEngine.plan(document, inputs: inputs).filter { !$0.changes.isEmpty }
    }

    /// Überträgt einen Plan in die Bearbeitungspuffer der Einträge. Die
    /// Einträge werden dadurch „dirty"; ein Feld, das die Medienart nicht
    /// kennt (z.B. ALBUM bei einem Bild), landet in `failed` und lässt den
    /// Eintrag unverändert.
    func applyRulePlan(_ plans: [TagRulePlan], to targets: [FileEntry]) -> RuleApplyOutcome {
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
    func applyRules(_ document: TagRuleDocument, to targets: [FileEntry]) async -> Bool {
        await applyRules(document, to: targets) { await self.saveEntries($0) }
    }

    /// Der austauschbare Speicheraufruf prüft die Auswahl der Dateien,
    /// ohne für einen abgelehnten Regelsatz echte Medien schreiben zu müssen.
    func applyRules(_ document: TagRuleDocument, to targets: [FileEntry],
                    save: ([FileEntry]) async -> Bool) async -> Bool {
        guard !isDestructiveActionLocked else { return false }
        let plans: [TagRulePlan]
        do {
            plans = try rulePlan(for: targets, document: document)
        } catch {
            alertMessage = String(localized: "Regeln konnten nicht angewendet werden:")
                + "\n" + error.localizedDescription
            return false
        }
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

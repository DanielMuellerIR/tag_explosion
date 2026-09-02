// Batch-Regeln im Modell: Der Plan entsteht aus den Bearbeitungspuffern,
// die Übernahme macht die Einträge dirty (geschrieben wird erst beim
// Speichern), Felder ohne Speicherort in der Medienart werden gemeldet, und
// die Liste der zuletzt benutzten Regeldateien lässt Fehlendes weg.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("AppModel Batch-Regeln", .serialized)
@MainActor
struct AppModelRulesTests {

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func audioEntry(at url: URL, _ fields: [String: String]) throws -> FileEntry {
        try Data("inhalt \(url.lastPathComponent)".utf8).write(to: url)
        let properties = fields.sorted { $0.key < $1.key }
            .map { TagProperty(key: $0.key, value: $0.value) }
        return FileEntry(url: url, loaded: .audio(TagData(properties: properties, artworks: [], audio: nil)))
    }

    @Test("Plan aus den Puffern, Übernahme macht dirty, unveränderte Einträge bleiben sauber")
    func planAndApplyIntoBuffers() throws {
        let directory = try makeDirectory("rules")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try audioEntry(at: directory.appendingPathComponent("2 - b.mp3"),
                                   ["TITLE": " so what ", "ARTIST": "Miles"])
        let second = try audioEntry(at: directory.appendingPathComponent("1 - a.mp3"),
                                    ["TITLE": "Blue in Green", "ARTIST": "Miles", "ALBUMARTIST": "Miles"])
        // Der Puffer zählt, nicht der Plattenstand: eine ungespeicherte
        // Änderung geht in die Vorschau ein.
        first.setSingleValue("ALBUMARTIST", "")
        let model = AppModel()
        model.entries = [first, second]

        let document = TagRuleDocument(rules: [
            TagRule(action: .trim, field: "*"),
            TagRule(action: .case, field: "title", mode: .title),
            TagRule(action: .copy, field: "albumartist", from: "artist", onlyIfEmpty: true),
        ])
        let plans = try model.rulePlan(for: [first, second], document: document)
        #expect(plans.count == 1)
        #expect(plans[0].url == first.url)
        #expect(plans[0].changes == [
            TagFieldChange(field: "ALBUMARTIST", old: "", new: "Miles"),
            TagFieldChange(field: "TITLE", old: " so what ", new: "So What"),
        ])

        let outcome = model.applyRulePlan(plans, to: [first, second])
        #expect(outcome == RuleApplyOutcome(changed: 1, failed: []))
        #expect(first.isDirty)
        #expect(first.firstValue("TITLE") == "So What")
        #expect(first.firstValue("ALBUMARTIST") == "Miles")
        #expect(!second.isDirty)
        // Nichts auf der Platte: Übernehmen ist kein Speichern.
        #expect(try Data(contentsOf: first.url) == Data("inhalt 2 - b.mp3".utf8))
    }

    @Test("Ungültige Regel: Plan wirft, applyRules meldet den Fehler und schreibt nichts")
    func invalidRuleIsReported() async throws {
        let directory = try makeDirectory("rules-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try audioEntry(at: directory.appendingPathComponent("a.mp3"), ["TITLE": "x"])
        let model = AppModel()
        model.entries = [entry]
        let broken = TagRuleDocument(rules: [TagRule(action: .copy, field: "album")])

        #expect(throws: TagRulesError.self) {
            try model.rulePlan(for: [entry], document: broken)
        }
        let saved = await model.applyRules(broken, to: [entry])
        #expect(!saved)
        #expect(model.alertMessage?.contains("Rule 1") == true)
        #expect(!entry.isDirty)
    }

    @Test("Feld ohne Speicherort in der Medienart landet in failed, Eintrag bleibt sauber")
    func unsupportedFieldForImage() throws {
        let directory = try makeDirectory("rules-image")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bild.jpg")
        try Data("kein bild".utf8).write(to: url)
        var fields = ImageCoreFields()
        fields.title = "x"
        let image = FileEntry(url: url, loaded: .image(ImageCoreReading(fields: fields)))
        let model = AppModel()
        model.entries = [image]

        let document = TagRuleDocument(rules: [TagRule(action: .set, field: "album", value: "Y")])
        let plans = try model.rulePlan(for: [image], document: document)
        #expect(plans[0].changes == [TagFieldChange(field: "ALBUM", old: "", new: "Y")])
        let outcome = model.applyRulePlan(plans, to: [image])
        #expect(outcome.changed == 0)
        #expect(outcome.failed.count == 1)
        #expect(outcome.failed[0].hasPrefix("bild.jpg"))
        #expect(!image.isDirty)
    }

    @Test("Verlauf der Regeldateien: neueste zuerst, ohne Dubletten, fehlende Dateien fallen weg")
    func ruleFileHistory() throws {
        let directory = try makeDirectory("rules-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = UserDefaults.standard.stringArray(forKey: RuleFileHistory.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: RuleFileHistory.defaultsKey) }
        UserDefaults.standard.removeObject(forKey: RuleFileHistory.defaultsKey)

        let a = directory.appendingPathComponent("a.json")
        let b = directory.appendingPathComponent("b.json")
        try Data("{}".utf8).write(to: a)
        try Data("{}".utf8).write(to: b)
        RuleFileHistory.remember(a)
        RuleFileHistory.remember(b)
        RuleFileHistory.remember(a)
        #expect(RuleFileHistory.load() == [a, b])
        try FileManager.default.removeItem(at: b)
        #expect(RuleFileHistory.load() == [a])
    }
}

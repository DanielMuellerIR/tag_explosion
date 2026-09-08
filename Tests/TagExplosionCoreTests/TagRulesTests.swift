// Batch-Regeln: Engine und Textwerkzeuge sind reine Funktionen, deshalb
// ohne Mediendateien prüfbar. Je Aktion ein Test, dazu Filter, Reihenfolge,
// No-op-Erkennung und die Fehlermeldungen der Regeldatei (mit Zeilenangabe).
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("Batch-Regeln")
struct TagRulesTests {

    private func doc(_ rules: TagRule...) -> TagRuleDocument {
        TagRuleDocument(rules: rules)
    }

    private func parse(_ json: String) throws -> TagRuleDocument {
        try TagRulesIO.parse(Data(json.utf8))
    }

    @Test("Bereinigung erhält zusätzliche Werte auch bei unverändertem ersten Wert")
    func preservesAdditionalValues() throws {
        let properties = [TagProperty(key: "ARTIST", value: "Miles"),
                          TagProperty(key: "ARTIST", value: " Coltrane "),
                          TagProperty(key: "GENRE", value: "Jazz"),
                          TagProperty(key: "GENRE", value: "")]
        // Dieser Test trifft schon vor der Korrektur den produktiven Adapter.
        let input = TagRuleInput(url: URL(fileURLWithPath: "/test.flac"), kind: .audio,
                                 values: TagRuleFields.values(from: properties))
        let plan = try TagRuleEngine.plan(doc(TagRule(action: .trim, field: "*")), inputs: [input])
        #expect(plan[0].changes.count == 1)
        #expect(plan[0].changes[0].allNewValues == ["Miles", "Coltrane"])
        var output = properties
        TagRuleFields.apply(["ARTIST": plan[0].changes[0].allNewValues], to: &output)
        #expect(TagRuleFields.values(from: output)["GENRE"] == ["Jazz", ""])
        let chain = try TagRuleEngine.plan(doc(
            TagRule(action: .trim, field: "*"),
            TagRule(action: .case, field: "ARTIST", mode: .upper),
            TagRule(action: .replace, field: "ARTIST", search: "MILES", replacement: "Davis"),
            TagRule(action: .copy, field: "ALBUMARTIST", from: "ARTIST")), inputs: [input])[0]
        #expect(chain.changes.first { $0.field == "ALBUMARTIST" }?.allNewValues == ["Davis", "COLTRANE"])
        let removed = try TagRuleEngine.plan(doc(TagRule(action: .remove, field: "ARTIST")), inputs: [input])[0]
        #expect(removed.changes[0].allNewValues == [])
        let set = try TagRuleEngine.plan(doc(TagRule(action: .set, field: "ARTIST", value: "Solo")), inputs: [input])[0]
        #expect(set.changes[0].allNewValues == ["Solo"])
    }

    @Test("CLI-Regeln: mehrwertiger Roundtrip entspricht dem Core-Plan", arguments: ["sample.flac", "sample.mp3", "sample.m4a"])
    func cliRoundtrip(_ fixture: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let properties = [TagProperty(key: "ARTIST", value: " Miles "),
                          TagProperty(key: "ARTIST", value: "Coltrane"),
                          TagProperty(key: "GENRE", value: " Jazz "),
                          TagProperty(key: "GENRE", value: "Bebop")]
        try TagFile.write(properties: properties, to: url)
        let document = doc(TagRule(action: .trim, field: "*"),
                           TagRule(action: .case, field: "ARTIST", mode: .upper),
                           TagRule(action: .replace, field: "ARTIST", search: "MILES", replacement: "Davis"),
                           TagRule(action: .copy, field: "ALBUMARTIST", from: "ARTIST"),
                           TagRule(action: .set, field: "COMMENT", value: "one"),
                           TagRule(action: .remove, field: "TITLE"))
        let rules = url.deletingLastPathComponent().appendingPathComponent("rules.json")
        try TagRulesIO.save(document, to: rules)
        let result = try runTagx(arguments: ["apply", rules.path, url.path, "--apply", "--json", "--no-backup"])
        let report = Data(result.stdout.utf8)
        #expect(result.status == 0)
        #expect(result.stdout.contains("newValues"))
        let values = TagRuleFields.values(from: try TagFile.read(at: url).properties)
        #expect(values["ARTIST"] == ["Davis", "COLTRANE"])
        #expect(values["ALBUMARTIST"] == ["Davis", "COLTRANE"])
        #expect(values["COMMENT"] == ["one"])
        #expect(values["TITLE"] == nil)
        let json = try #require(JSONSerialization.jsonObject(with: report) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        let changes = try #require(items.first?["changes"] as? [[String: Any]])
        let artist = try #require(changes.first { $0["field"] as? String == "ARTIST" })
        #expect(artist["oldValues"] as? [String] == [" Miles ", "Coltrane"])
        #expect(artist["newValues"] as? [String] == ["Davis", "COLTRANE"])
        #expect(values["GENRE"] == ["Jazz", "Bebop"])
    }

    // MARK: Aktionen

    @Test("set: Platzhalter aus anderen Feldern, Breite und Jahr wie bei Mustern")
    func setWithPlaceholders() throws {
        let fields = ["ARTIST": "AC/DC", "TRACKNUMBER": "3/12", "DATE": "1980-07-25"]
        let result = try TagRuleEngine.apply(
            doc(TagRule(action: .set, field: "comment", value: "%{artist} · %{track:2} · %{year} · 100%%")),
            to: fields)
        // Kein Dateinamen-Entschärfen: der Schrägstrich bleibt.
        #expect(result["COMMENT"] == "AC/DC · 03 · 1980 · 100%")
        // Die Breite gilt wie bei Dateinamen nur von 1 bis 9.
        #expect(TagRuleText.expandPlaceholders("%{track:10}", fields: fields) == "3")
        #expect(TagRuleText.expandPlaceholders("%{track:\(Int.max)}", fields: fields) == "3")
    }

    @Test("copy: nur wenn Ziel leer; leere Quelle lässt das Ziel in Ruhe")
    func copyOnlyIfEmpty() throws {
        let rule = TagRule(action: .copy, field: "albumartist", from: "artist", onlyIfEmpty: true)
        #expect(try TagRuleEngine.apply(doc(rule), to: ["ARTIST": "Miles"])["ALBUMARTIST"] == "Miles")
        #expect(try TagRuleEngine.apply(doc(rule), to: ["ARTIST": "Miles", "ALBUMARTIST": "Various"])["ALBUMARTIST"]
                == "Various")
        #expect(try TagRuleEngine.apply(doc(rule), to: ["ALBUMARTIST": "Various"])["ALBUMARTIST"] == "Various")
        let always = TagRule(action: .copy, field: "albumartist", from: "artist")
        #expect(try TagRuleEngine.apply(doc(always), to: ["ARTIST": "Miles", "ALBUMARTIST": "Various"])["ALBUMARTIST"]
                == "Miles")
    }

    @Test("replace: wörtlich, ohne Groß-/Kleinschreibung, Regex mit Gruppen")
    func replaceLiteralAndRegex() throws {
        let literal = TagRule(action: .replace, field: "title", search: "_", replacement: " ")
        #expect(try TagRuleEngine.apply(doc(literal), to: ["TITLE": "So_What_(Live)"])["TITLE"] == "So What (Live)")

        let insensitive = TagRule(action: .replace, field: "title", search: "remastered",
                                  replacement: "Remaster", ignoreCase: true)
        #expect(try TagRuleEngine.apply(doc(insensitive), to: ["TITLE": "X (REMASTERED)"])["TITLE"] == "X (Remaster)")

        // Wörtlich heißt wörtlich: Regex-Metazeichen bleiben Zeichen.
        let dots = TagRule(action: .replace, field: "title", search: ".", replacement: "-")
        #expect(try TagRuleEngine.apply(doc(dots), to: ["TITLE": "a.b"])["TITLE"] == "a-b")

        let regex = TagRule(action: .replace, field: "title", search: #"^(\d+)\s*-\s*(.+)$"#,
                            replacement: "$2 ($1)", regex: true)
        #expect(try TagRuleEngine.apply(doc(regex), to: ["TITLE": "07 - So What"])["TITLE"] == "So What (07)")

        // `*` bearbeitet alle Felder mit Wert.
        let all = TagRule(action: .replace, field: "*", search: "  ", replacement: " ")
        let result = try TagRuleEngine.apply(doc(all), to: ["TITLE": "a  b", "ARTIST": "c  d"])
        #expect(result == ["TITLE": "a b", "ARTIST": "c d"])
    }

    @Test("case: upper, lower, sentence")
    func caseSimpleModes() throws {
        #expect(TagRuleText.changeCase("Straße ärger", mode: .upper, smallWords: []) == "STRASSE ÄRGER")
        #expect(TagRuleText.changeCase("ÄRGER", mode: .lower, smallWords: []) == "ärger")
        #expect(TagRuleText.changeCase("hallo WELT. wie geht's? gut! ja", mode: .sentence, smallWords: [])
                == "Hallo welt. Wie geht's? Gut! Ja")
        #expect(TagRuleText.changeCase("(ein) test", mode: .sentence, smallWords: []) == "(Ein) test")
    }

    @Test("case title: kleine Wörter, Umlaute, Bindestriche, Klammern, Satzzeichen")
    func titleCase() throws {
        func title(_ text: String) -> String {
            TagRuleText.changeCase(text, mode: .title, smallWords: TagRule.defaultSmallWords)
        }
        #expect(title("the lord of the rings") == "The Lord of the Rings")
        // Am Ende bleibt ein kleines Wort groß, am Anfang sowieso.
        #expect(title("of the") == "Of The")
        #expect(title("DER RING DES NIBELUNGEN") == "Der Ring des Nibelungen")
        #expect(title("ärger im büro") == "Ärger im Büro")
        #expect(title("rock-and-roll für immer") == "Rock-and-Roll für Immer")
        #expect(title("so what (live in berlin)") == "So What (Live in Berlin)")
        #expect(title("titel: der film") == "Titel: Der Film")
        #expect(title("was? die antwort") == "Was? Die Antwort")
        #expect(title("don't stop") == "Don't Stop")
        #expect(title("ac/dc live") == "Ac/Dc Live")
        #expect(title("„die zeit“ und das leben") == "„Die Zeit“ und das Leben")
        // Mehrfacher Leerraum und Tabs bleiben, wie sie sind.
        #expect(title("a  b\tc") == "A  B\tC")
        // Eigene Liste kleiner Wörter.
        #expect(TagRuleText.changeCase("the end of it", mode: .title, smallWords: ["it"]) == "The End Of It")
        #expect(title("") == "")
    }

    @Test("trim: Ränder, Steuerzeichen, Mehrfach-Leerzeichen, Zeilenumbrüche innen bleiben")
    func trim() throws {
        #expect(TagRuleText.trim("  So   What \t\n") == "So What")
        #expect(TagRuleText.trim("\u{0}Titel\u{7}") == "Titel")
        #expect(TagRuleText.trim("Zeile 1\nZeile   2") == "Zeile 1\nZeile 2")
        let rule = TagRule(action: .trim, field: "*")
        let result = try TagRuleEngine.apply(doc(rule), to: ["TITLE": " a ", "ARTIST": "b", "COMMENT": ""])
        #expect(result["TITLE"] == "a")
        #expect(result["ARTIST"] == "b")
    }

    @Test("remove: Feld verschwindet; Plan meldet alt → leer")
    func remove() throws {
        let input = TagRuleInput(url: URL(fileURLWithPath: "/x/a.mp3"), kind: .audio,
                                 fields: ["TITLE": "A", "COMMENT": "weg"])
        let plans = try TagRuleEngine.plan(doc(TagRule(action: .remove, field: "comment")), inputs: [input])
        #expect(plans[0].changes == [TagFieldChange(field: "COMMENT", old: "weg", new: "")])
        #expect(try TagRuleEngine.apply(doc(TagRule(action: .remove, field: "comment")), to: input.fields)
                == ["TITLE": "A"])
    }

    @Test("number: Dateiname natürlich sortiert, Gesamtzahl, Breite, Start")
    func numberByFilename() throws {
        let names = ["10 zehn.mp3", "2 zwei.mp3", "1 eins.mp3"]
        let inputs = names.map { TagRuleInput(url: URL(fileURLWithPath: "/x/\($0)"), kind: .audio, fields: [:]) }
        let plans = try TagRuleEngine.plan(
            doc(TagRule(action: .number, field: "track", sortBy: "filename", total: true)), inputs: inputs)
        // Ergebnis in Eingabereihenfolge, Nummern nach Sortierung.
        #expect(plans.map { $0.changes[0].new } == ["3/3", "2/3", "1/3"])

        let padded = try TagRuleEngine.plan(
            doc(TagRule(action: .number, start: 5, width: 2)), inputs: inputs)
        #expect(padded.map { $0.changes[0].new } == ["07", "06", "05"])
        #expect(padded[0].changes[0].field == "TRACKNUMBER")
        let maximum = try TagRuleEngine.plan(doc(TagRule(action: .number, start: Int.max)),
                                             inputs: Array(inputs.prefix(1)))
        #expect(maximum[0].changes[0].new == String(Int.max))
        #expect(throws: TagRulesError.self) {
            try TagRuleEngine.plan(doc(TagRule(action: .number, start: Int.max)), inputs: inputs)
        }
    }

    @Test("number: nach Feld zahlenbewusst, Filter nimmt nur passende Dateien")
    func numberByFieldWithFilter() throws {
        func input(_ name: String, _ fields: [String: String], kind: MediaFormats.Kind = .audio) -> TagRuleInput {
            TagRuleInput(url: URL(fileURLWithPath: "/x/\(name)"), kind: kind, fields: fields)
        }
        let inputs = [
            input("a.mp3", ["TRACKNUMBER": "10/12", "ALBUM": "X"]),
            input("b.mp3", ["TRACKNUMBER": "9", "ALBUM": "X"]),
            input("c.mp3", ["TRACKNUMBER": "2", "ALBUM": "Y"]),
            input("d.jpg", ["TRACKNUMBER": "1"], kind: .image),
        ]
        let rule = TagRule(action: .number, field: "track", sortBy: "track", total: true,
                           kinds: [.audio], when: TagRuleCondition(field: "album", test: .equals, value: "X"))
        let plans = try TagRuleEngine.plan(doc(rule), inputs: inputs)
        #expect(plans[0].changes == [TagFieldChange(field: "TRACKNUMBER", old: "10/12", new: "2/2")])
        #expect(plans[1].changes == [TagFieldChange(field: "TRACKNUMBER", old: "9", new: "1/2")])
        #expect(plans[2].changes.isEmpty)
        #expect(plans[3].changes.isEmpty)
    }

    // MARK: Filter, Reihenfolge, No-op

    @Test("Bedingungen: empty, notEmpty, equals, contains, matches (auch ohne Groß/Klein)")
    func conditions() {
        let fields = ["TITLE": "So What", "GENRE": ""]
        #expect(TagRuleCondition(field: "genre", test: .empty).matches(fields))
        #expect(TagRuleCondition(field: "missing", test: .empty).matches(fields))
        #expect(!TagRuleCondition(field: "title", test: .empty).matches(fields))
        #expect(TagRuleCondition(field: "title", test: .notEmpty).matches(fields))
        #expect(TagRuleCondition(field: "title", test: .equals, value: "so what", ignoreCase: true).matches(fields))
        #expect(!TagRuleCondition(field: "title", test: .equals, value: "so what").matches(fields))
        #expect(TagRuleCondition(field: "title", test: .contains, value: "what", ignoreCase: true).matches(fields))
        #expect(!TagRuleCondition(field: "title", test: .contains, value: "what").matches(fields))
        #expect(TagRuleCondition(field: "title", test: .matches, value: #"^So\s"#).matches(fields))
        #expect(!TagRuleCondition(field: "title", test: .matches, value: #"^what"#).matches(fields))
    }

    @Test("Regeln laufen in Reihenfolge; eine spätere Bedingung sieht das Ergebnis der früheren")
    func rulesRunInOrder() throws {
        let document = doc(
            TagRule(action: .set, field: "albumartist", value: "%{artist}",
                    when: TagRuleCondition(field: "albumartist", test: .empty)),
            TagRule(action: .case, field: "albumartist", mode: .upper,
                    when: TagRuleCondition(field: "albumartist", test: .notEmpty)))
        #expect(try TagRuleEngine.apply(document, to: ["ARTIST": "Miles"])["ALBUMARTIST"] == "MILES")
    }

    @Test("Medienart-Filter und No-op: unveränderte Felder tauchen im Plan nicht auf")
    func kindFilterAndNoop() throws {
        let audio = TagRuleInput(url: URL(fileURLWithPath: "/x/a.mp3"), kind: .audio, fields: ["TITLE": "Abc"])
        let image = TagRuleInput(url: URL(fileURLWithPath: "/x/b.jpg"), kind: .image, fields: ["TITLE": "abc"])
        let rule = TagRule(action: .case, field: "title", mode: .title, kinds: [.audio, .image])
        let plans = try TagRuleEngine.plan(doc(rule), inputs: [audio, image])
        #expect(plans[0].changes.isEmpty) // schon in Titel-Schreibweise
        #expect(plans[1].changes == [TagFieldChange(field: "TITLE", old: "abc", new: "Abc")])

        let audioOnly = TagRule(action: .case, field: "title", mode: .upper, kinds: [.audio])
        let filtered = try TagRuleEngine.plan(doc(audioOnly), inputs: [audio, image])
        #expect(filtered[0].changes.count == 1)
        #expect(filtered[1].changes.isEmpty)
        #expect(filtered[0].newValues == ["TITLE": "ABC"])
    }

    // MARK: Regeldatei

    @Test("JSON-Roundtrip: nur die Parameter der Aktion werden geschrieben, Kurznamen kanonisiert")
    func jsonRoundtrip() throws {
        let document = doc(
            TagRule(action: .copy, field: "albumartist", from: "artist", onlyIfEmpty: true,
                    search: "Rest aus dem Editor", comment: "Hinweis"),
            TagRule(action: .number, sortBy: "Filename", total: true))
        let data = try TagRulesIO.encode(document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"_comment\" : \"Hinweis\""))
        #expect(!text.contains("Rest aus dem Editor"))
        #expect(text.contains("\"field\" : \"ALBUMARTIST\""))
        let reloaded = try TagRulesIO.parse(data)
        #expect(reloaded.rules[0].from == "ARTIST")
        #expect(reloaded.rules[1].sortBy == "filename")
        #expect(reloaded.rules[1].field == "TRACKNUMBER")
        #expect(reloaded.version == TagRuleDocument.currentVersion)
    }

    @Test("Beispiel-Regeldatei ist gültig und deckt alle Aktionen ab")
    func exampleIsValid() throws {
        let document = try parse(TagRulesIO.exampleJSON)
        #expect(Set(document.rules.map(\.action)) == Set(TagRule.Action.allCases))
        #expect(document.comment?.isEmpty == false)
        // Die Regex-Regel des Beispiels ist ausführbar.
        let fields = try TagRuleEngine.apply(document, to: ["TITLE": "so what (Remastered)", "ARTIST": "x"])
        #expect(fields["TITLE"] == "So What")
        #expect(fields["ALBUMARTIST"] == "x")
        #expect(fields["TRACKNUMBER"] == "1/1")
    }

    @Test("Unbekannte Aktion: Fehler nennt Regelnummer, Zeile und den Namen")
    func unknownActionReportsLine() {
        let json = """
        {
          "version": 1,
          "rules": [
            { "action": "trim", "field": "*" },
            {
              "action": "explode",
              "field": "title"
            }
          ]
        }
        """
        #expect(throws: TagRulesError.invalidRule(
            index: 1, line: 5,
            reason: "key \"action\": unknown action \"explode\" (expected one of set, copy, replace, case, trim, remove, number)")) {
            try parse(json)
        }
    }

    @Test("Fehlende Pflichtparameter, falsche Version, kaputte Regex und Syntaxfehler")
    func rejectsBrokenFiles() {
        #expect(throws: TagRulesError.unsupportedVersion(2)) {
            try parse(#"{"version": 2, "rules": []}"#)
        }
        #expect(throws: TagRulesError.invalidRule(
            index: 0, line: 1, reason: "\"from\" (source field) is required for action \"copy\"")) {
            try parse(#"{"version": 1, "rules": [{"action": "copy", "field": "album"}]}"#)
        }
        #expect(throws: TagRulesError.invalidRule(
            index: 0, line: 1, reason: "\"search\" is not a valid regular expression: (")) {
            try parse(#"{"version": 1, "rules": [{"action": "replace", "field": "title", "search": "(", "replacement": "", "regex": true}]}"#)
        }
        #expect(throws: TagRulesError.invalidRule(
            index: 0, line: 1, reason: "field \"*\" is only allowed for replace, case and trim")) {
            try parse(#"{"version": 1, "rules": [{"action": "remove", "field": "*"}]}"#)
        }
        #expect(throws: TagRulesError.invalidRule(
            index: 0, line: 1,
            reason: "key \"is\": unknown condition \"blank\" (expected one of empty, notEmpty, equals, contains, matches)")) {
            try parse(#"{"version": 1, "rules": [{"action": "trim", "field": "*", "when": {"field": "title", "is": "blank"}}]}"#)
        }
        #expect(throws: TagRulesError.invalidRule(index: 0, line: 1, reason: "missing key \"action\"")) {
            try parse(#"{"version": 1, "rules": [{"field": "title"}]}"#)
        }
        // Kein JSON: Syntaxfehler mit Zeile (Foundation nennt sie).
        do {
            _ = try parse("{\n  \"version\": 1,\n  \"rules\": [\n")
            Issue.record("Syntaxfehler wurde nicht gemeldet")
        } catch TagRulesError.invalidJSON(let line, _) {
            // Die Zeile stammt aus Foundations Fehlertext; Linux-Foundation
            // nennt keine, dort bleibt sie erlaubt nil.
            #if canImport(Darwin)
            #expect(line != nil)
            #else
            _ = line
            #endif
        } catch {
            Issue.record("Unerwarteter Fehler: \(error)")
        }
    }

    @Test("Zeilensuche überspringt Strings mit Klammern")
    func lineOfRuleSkipsStrings() {
        let json = """
        {
          "_comment": "{ not a rule [",
          "version": 1,
          "rules": [
            { "action": "trim", "field": "*", "_comment": "}]" },
            { "action": "trim",
              "field": "*" }
          ]
        }
        """
        #expect(TagRulesIO.lineOfRule(0, in: json) == 5)
        #expect(TagRulesIO.lineOfRule(1, in: json) == 6)
        #expect(TagRulesIO.lineOfRule(2, in: json) == nil)
    }

    @Test("Vorlagen sind gültige Regelsätze")
    func templatesAreValid() throws {
        for template in TagRuleTemplate.allCases {
            try template.document.validate()
        }
        let result = try TagRuleEngine.apply(
            TagRuleTemplate.albumArtistFromArtist.document, to: ["ARTIST": "Duo"])
        #expect(result["ALBUMARTIST"] == "Duo")
    }
}

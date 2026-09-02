// Markdown (.md/.markdown): Metadaten im YAML-Frontmatter (Parser in
// MarkdownFrontmatter). Bekannte Schlüssel werden auf den gemeinsamen Feldsatz
// abgebildet, alle übrigen einfachen Schlüssel erscheinen als Zusatzfelder;
// komplexe Einträge bleiben unsichtbar, aber erhalten.
//
// Feldzuordnung (Lesen und Schreiben):
//   title ↔ title · authors ↔ authors (Liste) bzw. author (Skalar oder Liste)
//   description ↔ description · keywords ↔ tags · created ↔ date
// Kein Speicherort: subject, publisher, language, category, modified — solche
// Angaben lassen sich als Zusatzfeld unter beliebigem Schlüssel ablegen.
//
// Beim Schreiben bleibt die Reihenfolge der Einträge erhalten; neue Schlüssel
// kommen ans Ende. Ein leerer Wert entfernt den Eintrag. Der Body wird
// byte-identisch übernommen. Fehlt der Block, entsteht er am Dateianfang.
import Foundation

enum MarkdownDocumentFile: DocumentBackend {

    static let supportedFields: Set<DocumentField> = [
        .title, .authors, .description, .keywords, .created,
    ]
    /// nil: beliebige Schlüssel — außer den fest zugeordneten oben.
    static let customKeys: [String]? = nil

    /// Schlüssel mit fester Zuordnung; sie erscheinen nie als Zusatzfeld.
    private static let mappedKeys: Set<String> = [
        "title", "author", "authors", "description", "tags", "date",
    ]

    // MARK: - Lesen

    static func read(url: URL) throws -> (DocumentCoreFields, [DocumentInfoItem]) {
        let document = try load(url: url)
        var fields = DocumentCoreFields()
        var info: [DocumentInfoItem] = []
        guard let entries = document.entries else {
            info.append(DocumentInfoItem(label: "frontmatter", value: "none"))
            return (fields, info)
        }
        info.append(DocumentInfoItem(label: "frontmatter", value: "yes"))
        fields.title = document.entry("title")?.displayValue ?? ""
        // `authors` (Liste) gewinnt gegen `author`.
        if let authors = document.entry("authors") {
            fields.authors = authors.listValue
        } else if let author = document.entry("author") {
            fields.authors = author.listValue
        }
        fields.description = document.entry("description")?.displayValue ?? ""
        fields.keywords = document.entry("tags")?.listValue ?? []
        fields.created = document.entry("date")?.displayValue ?? ""
        var complexKeys: [String] = []
        for entry in entries where !entry.key.isEmpty && !mappedKeys.contains(entry.key) {
            if let value = entry.displayValue {
                // Doppelte Schlüssel: der erste zählt (setCustom überschreibt
                // nicht).
                if fields.custom.contains(where: { $0.key == entry.key }) { continue }
                fields.custom.append(DocumentCustomField(key: entry.key, value: value))
            } else {
                complexKeys.append(entry.key)
            }
        }
        if !complexKeys.isEmpty {
            info.append(DocumentInfoItem(label: "preserved (not editable)",
                                         value: complexKeys.joined(separator: ", ")))
        }
        return (fields, info)
    }

    private static func load(url: URL) throws -> MarkdownDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TagError.cannotOpen(path: url.path)
        }
        return try MarkdownFrontmatter.parse(data, path: url.path)
    }

    // MARK: - Schreiben

    static func validate(_ fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        for entry in fields.custom {
            // Ein Zusatzschlüssel muss als YAML-Schlüssel am Zeilenanfang
            // lesbar bleiben.
            guard entry.key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }),
                  let first = entry.key.first, first != "-" else {
                throw TagError.invalidDocumentValue(
                    field: entry.key, reason: "custom keys may contain letters, digits, '_', '-' and '.'")
            }
            guard !mappedKeys.contains(entry.key) else {
                throw TagError.invalidDocumentValue(
                    field: entry.key, reason: "this key is a core field, not a custom field")
            }
        }
        // Ein komplexer Eintrag (verschachtelt, Blockskalar) kann nicht
        // durch einen einfachen Wert ersetzt werden, ohne ihn zu zerstören.
        // Das prüft `mutate` gegen die Datei; hier reicht die Schlüsselform.
    }

    static func mutate(url: URL, fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        var document = try load(url: url)
        var entries = document.entries ?? []

        func replace(_ key: String, with entry: FrontmatterEntry?) throws {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if case .complex = entries[index].value {
                    throw TagError.invalidDocumentValue(
                        field: key, reason: "the existing value is a nested structure and stays untouched")
                }
                if let entry {
                    entries[index] = entry
                } else {
                    entries.remove(at: index)
                }
                // Weitere gleichnamige Einträge wären nach dem Schreiben
                // mehrdeutig — sie gehen mit.
                entries.removeAll { $0.key == key && $0 != entry }
            } else if let entry {
                entries.append(entry)
            }
        }
        func scalarEntry(_ key: String, _ value: String) -> FrontmatterEntry? {
            value.isEmpty ? nil : .scalar(key, value)
        }

        if fields.title != original.title {
            try replace("title", with: scalarEntry("title", fields.title))
        }
        if fields.description != original.description {
            try replace("description", with: scalarEntry("description", fields.description))
        }
        if fields.created != original.created {
            try replace("date", with: scalarEntry("date", fields.created))
        }
        if fields.keywords != original.keywords {
            try replace("tags", with: fields.keywords.isEmpty ? nil : .list("tags", fields.keywords))
        }
        if fields.authors != original.authors {
            try writeAuthors(fields.authors,
                             hasAuthors: entries.contains { $0.key == "authors" },
                             hasAuthor: entries.contains { $0.key == "author" },
                             replace: replace)
        }

        let originalCustom = Dictionary(original.custom.map { ($0.key, $0.value) },
                                        uniquingKeysWith: { first, _ in first })
        let newCustom = Dictionary(fields.custom.map { ($0.key, $0.value) },
                                   uniquingKeysWith: { first, _ in first })
        // Entfernte Schlüssel zuerst, dann geänderte/neue in Feldreihenfolge.
        for key in originalCustom.keys.sorted() where newCustom[key] == nil {
            try replace(key, with: nil)
        }
        for entry in fields.custom where originalCustom[entry.key] != entry.value {
            try replace(entry.key, with: scalarEntry(entry.key, entry.value))
        }

        document.entries = entries
        let output = MarkdownFrontmatter.serialize(document)
        do {
            try output.write(to: url)
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
    }

    /// Autoren landen im Schlüssel, der schon da ist (`authors` vor `author`);
    /// sonst `author` für eine Person, `authors` für mehrere.
    private static func writeAuthors(
        _ authors: [String], hasAuthors: Bool, hasAuthor: Bool,
        replace: (String, FrontmatterEntry?) throws -> Void
    ) throws {
        if authors.isEmpty {
            if hasAuthors { try replace("authors", nil) }
            if hasAuthor { try replace("author", nil) }
            return
        }
        if hasAuthors || (!hasAuthor && authors.count > 1) {
            try replace("authors", .list("authors", authors))
        } else if authors.count == 1 {
            try replace("author", .scalar("author", authors[0]))
        } else {
            try replace("author", .list("author", authors))
        }
    }

    static func validateContainer(url: URL) throws {
        _ = try load(url: url)
    }
}

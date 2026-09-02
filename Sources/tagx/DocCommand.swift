// tagx doc — Dokument-Metadaten anzeigen und setzen: Office (docx/xlsx/pptx),
// OpenDocument (odt/ods/odp), Comic-Archive (cbz) und Markdown-Frontmatter.
// Alles nativ im Core, ohne externe Programme.
import ArgumentParser
import Foundation
import TagExplosionCore

struct Doc: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doc",
        abstract: "Show and edit document metadata (docx, xlsx, pptx, odt, ods, odp, cbz, md).",
        subcommands: [DocShow.self, DocSet.self],
        defaultSubcommand: DocShow.self
    )
}

struct DocShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show core fields, custom fields, and document info.")

    @Argument(help: "Document file (docx, xlsx, pptx, odt, ods, odp, cbz, md)") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var file: String
        var core: DocumentCoreFields
        /// Felder, die dieses Format speichern kann (sortiert).
        var supportedFields: [String]
        /// Erlaubte Zusatzschlüssel; nil = beliebige (Markdown).
        var customKeys: [String]?
        /// Anzeigeinformationen (Anwendung, Seiten, Wörter …).
        var info: [DocumentInfoItem]
        /// MIME-Type und Größe des Covers (nur cbz; nil = keins).
        var coverMimeType: String?
        var coverBytes: Int?
    }

    func run() throws {
        let url = try resolveFile(file)
        let snapshot = try DocumentTool.readSnapshot(
            url: url, includeCover: DocumentTool.supportsCover(url: url))
        let contents = snapshot.value
        let core = contents.fields
        if json {
            try printJSON(Report(
                file: url.path, core: core,
                supportedFields: DocumentTool.supportedFields(url: url).map(\.rawValue).sorted(),
                customKeys: DocumentTool.customKeys(url: url),
                info: contents.info,
                coverMimeType: contents.cover?.resolvedMimeType,
                coverBytes: contents.cover.map(\.data.count)))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        line("TITLE", core.title)
        line("AUTHORS", core.authors.joined(separator: ", "))
        line("SUBJECT", core.subject)
        line("DESCRIPTION", core.description)
        line("KEYWORDS", core.keywords.joined(separator: ", "))
        line("PUBLISHER", core.publisher)
        line("LANGUAGE", core.language)
        line("CATEGORY", core.category)
        line("CREATED", core.created)
        line("MODIFIED", core.modified)
        for field in core.custom {
            print("CUSTOM.\(field.key)=\(field.value)")
        }
        for item in contents.info {
            print("INFO.\(item.label)=\(item.value)")
        }
        if let cover = contents.cover {
            print("COVER=\(cover.resolvedMimeType) (\(cover.data.count) bytes)")
        }
    }
}

struct DocSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set core fields (an empty value deletes the field). Fields the format cannot store are rejected.")

    @Argument(help: "Document file (docx, xlsx, pptx, odt, ods, odp, cbz, md)") var file: String
    @Option(help: "Title") var title: String?
    @Option(help: "Author(s), comma-separated") var authors: String?
    @Option(help: "Subject") var subject: String?
    @Option(help: "Description/summary") var description: String?
    @Option(help: "Keywords/tags, comma-separated") var keywords: String?
    @Option(help: "Publisher") var publisher: String?
    @Option(help: "Language code, e.g. de or de-DE") var language: String?
    @Option(help: "Category") var category: String?
    @Option(help: "Creation date (ISO 8601)") var created: String?
    @Option(help: "Modification date (ISO 8601)") var modified: String?
    @Option(name: .customLong("custom"), parsing: .upToNextOption,
            help: "Custom field KEY=VALUE (e.g. Series=Foo for cbz, any key for Markdown); an empty value deletes it")
    var custom: [String] = []
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try DocumentTool.readSnapshot(url: url, includeCover: false)
        let original = snapshot.value.fields
        var fields = original
        if let title { fields.title = title }
        if let authors { fields.authors = authors.splitCommaList() }
        if let subject { fields.subject = subject }
        if let description { fields.description = description }
        if let keywords { fields.keywords = keywords.splitCommaList() }
        if let publisher { fields.publisher = publisher }
        if let language { fields.language = language }
        if let category { fields.category = category }
        if let created { fields.created = created }
        if let modified { fields.modified = modified }
        for assignment in custom {
            guard let eq = assignment.firstIndex(of: "=") else {
                throw ValidationError("Invalid custom assignment (expected KEY=VALUE): \(assignment)")
            }
            let key = String(assignment[..<eq])
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("Invalid custom assignment (the key must not be empty): \(assignment)")
            }
            fields.setCustom(key, String(assignment[assignment.index(after: eq)...]))
        }

        // Was das Format nicht speichern kann, wird vor Sicherung und
        // Schreibweg abgelehnt — mit dem Feldnamen in der Meldung.
        do {
            try DocumentTool.requireWritable(fields, original: original, url: url)
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
        try DocumentTool.write(url: url, fields: fields, original: original,
                               expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent)")
    }
}

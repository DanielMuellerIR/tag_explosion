// tagx ebook — E-Book-/Dokument-Metadaten anzeigen und setzen.
// EPUB nativ, PDF via exiftool, mobi/azw3/fb2 via Calibre (falls installiert).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Ebook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ebook",
        abstract: "E-Book-Metadaten anzeigen und bearbeiten (epub, pdf; mit Calibre: mobi, azw3, fb2).",
        subcommands: [EbookShow.self, EbookSet.self],
        defaultSubcommand: EbookShow.self
    )
}

struct EbookShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Kernfelder anzeigen.")

    @Argument(help: "E-Book-Datei (epub, pdf, mobi, azw3, fb2)") var file: String
    @Flag(name: .long, help: "Ausgabe als JSON") var json = false

    struct Report: Codable {
        var file: String
        var core: EbookCoreFields
        /// MIME-Type und Größe des Covers (nil = keins).
        var coverMimeType: String?
        var coverBytes: Int?
    }

    func run() throws {
        let url = try resolveFile(file)
        let core = try EbookTool.readCoreFields(url: url)
        let cover = try? EbookTool.readCover(url: url)
        if json {
            try printJSON(Report(file: url.path, core: core,
                                 coverMimeType: cover?.resolvedMimeType,
                                 coverBytes: cover.map(\.data.count)))
            return
        }
        func line(_ label: String, _ value: String) {
            if !value.isEmpty { print("\(label)=\(value)") }
        }
        line("TITLE", core.title)
        line("AUTHORS", core.authors.joined(separator: ", "))
        line("SERIES", core.series)
        line("SERIESINDEX", core.seriesIndex)
        line("DESCRIPTION", core.description)
        line("ISBN", core.isbn)
        line("PUBLISHER", core.publisher)
        line("LANGUAGE", core.language)
        line("DATE", core.date)
        line("SUBJECTS", core.subjects.joined(separator: ", "))
        if let cover {
            print("COVER=\(cover.resolvedMimeType) (\(cover.data.count) Bytes)")
        }
    }
}

struct EbookSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Kernfelder setzen (leerer Wert löscht das Feld).")

    @Argument(help: "E-Book-Datei (epub, pdf, mobi, azw3, fb2)") var file: String
    @Option(help: "Titel") var title: String?
    @Option(help: "Autor(en), kommagetrennt") var authors: String?
    @Option(help: "Serie") var series: String?
    @Option(name: .customLong("series-index"), help: "Serienindex, z.B. 2 oder 2.5") var seriesIndex: String?
    @Option(help: "Klappentext/Beschreibung") var description: String?
    @Option(help: "ISBN") var isbn: String?
    @Option(help: "Verlag") var publisher: String?
    @Option(help: "Sprachcode, z.B. de") var language: String?
    @Option(help: "Veröffentlichungsdatum (ISO 8601)") var date: String?
    @Option(help: "Schlagwörter, kommagetrennt") var subjects: String?
    @Option(help: "Cover aus Bilddatei setzen (jpg/png)") var cover: String?

    func run() throws {
        let url = try resolveFile(file)
        let original = try EbookTool.readCoreFields(url: url)
        var fields = original
        if let title { fields.title = title }
        if let authors { fields.authors = splitList(authors) }
        if let series { fields.series = series }
        if let seriesIndex { fields.seriesIndex = seriesIndex }
        if let description { fields.description = description }
        if let isbn { fields.isbn = isbn }
        if let publisher { fields.publisher = publisher }
        if let language { fields.language = language }
        if let date { fields.date = date }
        if let subjects { fields.subjects = splitList(subjects) }

        if !EbookTool.supportsSeries(url: url),
           fields.series != original.series || fields.seriesIndex != original.seriesIndex {
            throw ValidationError("Dieses Format kann keine Serie speichern (PDF).")
        }

        var changed = false
        if fields != original {
            try EbookTool.writeCoreFields(url: url, fields: fields, original: original)
            changed = true
        }
        if let cover {
            guard EbookTool.supportsCover(url: url) else {
                throw ValidationError("Dieses Format kann kein Cover speichern (PDF).")
            }
            let coverURL = try resolveFile(cover)
            let data = try Data(contentsOf: coverURL)
            try EbookTool.writeCover(url: url, data: data)
            changed = true
        }
        print(changed ? "OK \(url.lastPathComponent)" : "Keine Änderungen")
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

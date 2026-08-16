// tagx ebook — E-Book-/Dokument-Metadaten anzeigen und setzen.
// EPUB nativ, PDF via exiftool, mobi/azw3/fb2 via Calibre (falls installiert).
import ArgumentParser
import Foundation
import TagExplosionCore

struct Ebook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ebook",
        abstract: "Show and edit e-book metadata (epub, pdf; with Calibre: mobi, azw3, fb2).",
        subcommands: [EbookShow.self, EbookSet.self],
        defaultSubcommand: EbookShow.self
    )
}

struct EbookShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show core fields.")

    @Argument(help: "E-book file (epub, pdf, mobi, azw3, fb2)") var file: String
    @Flag(name: .long, help: "Output as JSON") var json = false

    struct Report: Codable {
        var file: String
        var core: EbookCoreFields
        /// MIME-Type und Größe des Covers (nil = keins).
        var coverMimeType: String?
        var coverBytes: Int?
    }

    func run() throws {
        let url = try resolveFile(file)
        // Felder und Cover sind zwei Backend-Aufrufe. Nur gemeinsam unter einem
        // Dateistempel gelesen beschreiben sie garantiert dieselbe Fassung —
        // sonst könnte die Ausgabe einen Zustand melden, den es nie gab.
        // Ein Cover-Lesefehler wird weitergereicht: "kein Cover" ist eine
        // Aussage über die Datei, kein Platzhalter für einen Fehler.
        let snapshot = try EbookTool.readSnapshot(
            url: url, includeCover: EbookTool.supportsCover(url: url))
        let core = snapshot.value.fields
        let cover = snapshot.value.cover
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
            print("COVER=\(cover.resolvedMimeType) (\(cover.data.count) bytes)")
        }
    }
}

struct EbookSet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Set core fields (an empty value deletes the field).")

    @Argument(help: "E-book file (epub, pdf, mobi, azw3, fb2)") var file: String
    @Option(help: "Title") var title: String?
    @Option(help: "Author(s), comma-separated") var authors: String?
    @Option(help: "Series") var series: String?
    @Option(name: .customLong("series-index"), help: "Series index, e.g. 2 or 2.5") var seriesIndex: String?
    @Option(help: "Description/blurb") var description: String?
    @Option(help: "ISBN") var isbn: String?
    @Option(help: "Publisher") var publisher: String?
    @Option(help: "Language code, e.g. en") var language: String?
    @Option(help: "Publication date (ISO 8601)") var date: String?
    @Option(help: "Tags/subjects, comma-separated") var subjects: String?
    @Option(help: "Set cover from image file (jpg/png)") var cover: String?
    @OptionGroup var safeMode: SafeModeOptions

    func run() throws {
        safeMode.apply()
        let url = try resolveFile(file)
        let snapshot = try EbookTool.readSnapshot(
            // Felder und Cover bilden genau dann einen gemeinsamen Snapshot,
            // wenn --cover den bestehenden Cover-Stand wirklich vergleicht.
            // Reine Feldänderungen dürfen nicht von einem unnötigen
            // ebook-meta --get-cover-Aufruf abhängen.
            url: url, includeCover: cover != nil && EbookTool.supportsCover(url: url))
        let original = snapshot.value.fields
        var fields = original
        if let title { fields.title = title }
        if let authors { fields.authors = authors.splitCommaList() }
        if let series { fields.series = series }
        if let seriesIndex { fields.seriesIndex = seriesIndex }
        if let description { fields.description = description }
        if let isbn { fields.isbn = isbn }
        if let publisher { fields.publisher = publisher }
        if let language { fields.language = language }
        if let date { fields.date = date }
        if let subjects { fields.subjects = subjects.splitCommaList() }

        if !EbookTool.supportsSeries(url: url),
           fields.series != original.series || fields.seriesIndex != original.seriesIndex {
            throw ValidationError("This format cannot store a series (PDF).")
        }
        // Ein Index ohne Serie hätte außerhalb von EPUB keinen Speicherort —
        // vor Sicherung und Schreibweg ablehnen statt hinterher "OK" zu melden.
        do {
            try EbookTool.requireStorableSeries(fields, original: original, url: url)
        } catch TagError.seriesIndexWithoutSeries {
            throw ValidationError("A series index needs a series name (--series).")
        }

        var coverUpdate = EbookCoverUpdate.unchanged
        if let cover {
            guard EbookTool.supportsCover(url: url) else {
                throw ValidationError("This format cannot store a cover (PDF).")
            }
            let coverURL = try resolveFile(cover)
            let data = try Data(contentsOf: coverURL)
            // Nur Bilddaten, die das Ziel-Backend setzen kann
            // (Signaturprüfung, nicht Endung).
            do {
                try EbookTool.requireSupportedCover(data, for: url)
            } catch TagError.unsupportedCoverData {
                let formats = EbookTool.backend(for: url) == .epub
                    ? "JPEG, PNG, GIF, or WebP" : "JPEG or PNG"
                throw ValidationError("Cover must be a \(formats) image: \(coverURL.path)")
            }
            // Auch das Lesen der externen Cover-Datei öffnet ein Zeitfenster.
            // Vor Vergleich/Schreiben muss das E-Book noch der Ausgangsfassung
            // entsprechen. Identische Coverdaten bleiben ein echter No-op.
            try snapshot.requireCurrent(at: url)
            if data != snapshot.value.cover?.data {
                coverUpdate = .set(data)
            }
        }
        let coverChanged: Bool
        switch coverUpdate {
        case .unchanged: coverChanged = false
        case .set, .remove: coverChanged = true
        }
        let changed = fields != original || coverChanged
        guard changed else {
            try snapshot.requireCurrent(at: url)
            print("No changes")
            return
        }
        try snapshot.requireCurrent(at: url)
        try TrashBackup.shared.backUp(url)
        try EbookTool.write(
            url: url, fields: fields, original: original,
            coverUpdate: coverUpdate, expecting: snapshot.stamp)
        print("OK \(url.lastPathComponent)")
    }
}

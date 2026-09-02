// Comic-Archive (cbz): ZIP mit Bildseiten und optional `ComicInfo.xml`
// (ComicRack-Schema, von Komga, Kavita, YACReader … gelesen). Cover = erste
// Bildseite in natürlicher Sortierung (nur Anzeige — die Seitenbilder werden
// nie verändert). Fehlt ComicInfo.xml, legt der erste Schreibvorgang es im
// Archivwurzelverzeichnis an.
//
// cbr (RAR) fehlt bewusst: RAR ist ohne fremde Bibliothek (unrar, proprietäre
// Lizenz) nicht lesbar und ohne das RAR-Programm nicht schreibbar.
//
// Feldzuordnung (Lesen und Schreiben):
//   title ↔ Title · authors ↔ Writer ("A, B") · description ↔ Summary
//   publisher ↔ Publisher · language ↔ LanguageISO
//   created ↔ Year/Month/Day ("2020", "2020-03" oder "2020-03-05")
//   Zusatzfelder: Series, Number, Volume, Penciller, Genre, PageCount
// Kein Speicherort: subject, keywords, category, modified.
import Foundation
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum ComicArchiveFile: DocumentBackend {

    static let supportedFields: Set<DocumentField> = [
        .title, .authors, .description, .publisher, .language, .created,
    ]
    static let customKeys: [String]? = [
        "Series", "Number", "Volume", "Penciller", "Genre", "PageCount",
    ]

    /// Elementreihenfolge des ComicInfo-Schemas (xs:sequence). Neue Elemente
    /// werden an der schemagerechten Stelle eingefügt, damit strenge Leser
    /// die Datei weiterhin annehmen.
    private static let schemaOrder: [String] = [
        "Title", "Series", "Number", "Count", "Volume", "AlternateSeries",
        "AlternateNumber", "AlternateCount", "Summary", "Notes", "Year", "Month",
        "Day", "Writer", "Penciller", "Inker", "Colorist", "Letterer", "CoverArtist",
        "Editor", "Publisher", "Imprint", "Genre", "Web", "PageCount", "LanguageISO",
        "Format", "BlackAndWhite", "Manga", "Characters", "Teams", "Locations",
        "ScanInformation", "StoryArc", "SeriesGroup", "AgeRating", "Pages",
        "CommunityRating",
    ]

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    // MARK: - Lesen

    static func read(url: URL) throws -> (DocumentCoreFields, [DocumentInfoItem]) {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        var fields = DocumentCoreFields()
        var info: [DocumentInfoItem] = []
        let pages = imagePages(in: archive)
        info.append(DocumentInfoItem(label: "Pages", value: String(pages.count)))
        if let path = comicInfoPath(in: archive),
           let data = try ZipContainer.data(at: path, in: archive) {
            let document = try XMLTools.document(from: data, path: url.path)
            guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
            fields.title = XMLTools.text(of: "Title", in: root)
            fields.authors = DocumentTool.splitList(
                XMLTools.text(of: "Writer", in: root), separators: [","])
            fields.description = XMLTools.text(of: "Summary", in: root)
            fields.publisher = XMLTools.text(of: "Publisher", in: root)
            fields.language = XMLTools.text(of: "LanguageISO", in: root)
            fields.created = isoDate(
                year: XMLTools.text(of: "Year", in: root),
                month: XMLTools.text(of: "Month", in: root),
                day: XMLTools.text(of: "Day", in: root))
            for key in customKeys ?? [] {
                fields.setCustom(key, XMLTools.text(of: key, in: root))
            }
            info.append(DocumentInfoItem(label: "ComicInfo.xml", value: path))
        } else {
            info.append(DocumentInfoItem(label: "ComicInfo.xml", value: "missing"))
        }
        return (fields, info)
    }

    static func readCover(url: URL) throws -> Artwork? {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        guard let first = imagePages(in: archive).first,
              let entry = archive[first] else { return nil }
        let data = try ZipContainer.data(of: entry, in: archive)
        return Artwork(data: data, mimeType: Artwork.sniffMimeType(from: data) ?? "",
                       pictureType: "Front Cover")
    }

    /// Bildseiten in natürlicher Sortierung ("page-2" vor "page-10"),
    /// ohne Finder-Reste (`__MACOSX/`) und versteckte Dateien.
    private static func imagePages(in archive: Archive) -> [String] {
        archive
            .filter { $0.type == .file }
            .map(\.path)
            .filter { path in
                let name = (path as NSString).lastPathComponent
                return !path.hasPrefix("__MACOSX/") && !name.hasPrefix(".")
                    && imageExtensions.contains((name as NSString).pathExtension.lowercased())
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// ComicInfo.xml liegt üblicherweise in der Wurzel; manche Archive tragen
    /// es in einem Unterordner. Groß-/Kleinschreibung ist nicht verlässlich.
    private static func comicInfoPath(in archive: Archive) -> String? {
        let candidates = archive.map(\.path).filter {
            ($0 as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
        }
        return candidates.first { !$0.contains("/") } ?? candidates.first
    }

    /// Year/Month/Day → "2020-03-05"; fehlende Teile kürzen das Datum.
    private static func isoDate(year: String, month: String, day: String) -> String {
        guard let y = Int(year), y > 0 else { return "" }
        var result = String(format: "%04d", y)
        guard let m = Int(month), m > 0 else { return result }
        result += String(format: "-%02d", m)
        guard let d = Int(day), d > 0 else { return result }
        return result + String(format: "-%02d", d)
    }

    // MARK: - Schreiben

    static func validate(_ fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        if fields.authors != original.authors {
            try DocumentTool.requireValues(fields.authors, free: [","], field: .authors)
        }
        if fields.created != original.created, !fields.created.isEmpty,
           fields.created.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?$"#, options: .regularExpression) == nil {
            throw TagError.invalidDocumentValue(
                field: DocumentField.created.rawValue,
                reason: "expected YYYY, YYYY-MM or YYYY-MM-DD")
        }
        for key in ["Volume", "PageCount"] {
            let value = fields.customValue(for: key)
            if value != original.customValue(for: key), !value.isEmpty, Int(value) == nil {
                throw TagError.invalidDocumentValue(field: key, reason: "expected a whole number")
            }
        }
    }

    static func mutate(url: URL, fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let path = comicInfoPath(in: archive) ?? "ComicInfo.xml"
        let document: XMLDocument
        if let existing = try ZipContainer.data(at: path, in: archive) {
            document = try XMLTools.document(from: existing, path: url.path)
        } else {
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" \
            xmlns:xsd="http://www.w3.org/2001/XMLSchema"></ComicInfo>
            """
            document = try XMLDocument(data: Data(xml.utf8))
        }
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }

        func set(_ name: String, _ new: String, _ old: String) {
            guard new != old else { return }
            XMLTools.setSingle(root, name, prefix: "", value: new) { created in
                insert(created, into: root)
            }
        }
        set("Title", fields.title, original.title)
        set("Writer", fields.authors.joined(separator: ", "), original.authors.joined(separator: ", "))
        set("Summary", fields.description, original.description)
        set("Publisher", fields.publisher, original.publisher)
        set("LanguageISO", fields.language, original.language)
        if fields.created != original.created {
            let parts = fields.created.split(separator: "-").map(String.init)
            set("Year", parts.count > 0 ? String(Int(parts[0]) ?? 0) : "", "-")
            set("Month", parts.count > 1 ? String(Int(parts[1]) ?? 0) : "", "-")
            set("Day", parts.count > 2 ? String(Int(parts[2]) ?? 0) : "", "-")
        }
        for key in customKeys ?? [] {
            set(key, fields.customValue(for: key), original.customValue(for: key))
        }
        try ZipContainer.rewrite(url: url, replacing: [path: XMLTools.serialize(document)])
    }

    /// Fügt ein neues Element vor dem ersten Geschwister ein, das laut Schema
    /// später kommt; unbekannte oder letzte Elemente landen am Ende.
    private static func insert(_ element: XMLElement, into root: XMLElement) {
        let name = XMLTools.localName(element)
        guard let position = schemaOrder.firstIndex(of: name) else {
            root.addChild(element)
            return
        }
        let children = (root.children ?? []).compactMap { $0 as? XMLElement }
        for child in children {
            if let childPosition = schemaOrder.firstIndex(of: XMLTools.localName(child)),
               childPosition > position {
                root.insertChild(element, at: child.index)
                return
            }
        }
        root.addChild(element)
    }

    static func validateContainer(url: URL) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        guard let path = comicInfoPath(in: archive),
              let data = try ZipContainer.data(at: path, in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        _ = try XMLTools.document(from: data, path: url.path)
    }
}

// Nativer EPUB-Zugriff: EPUB ist ein ZIP-Container (ZIPFoundation) mit einer
// OPF-XML-Datei für die Metadaten. Wir lesen und schreiben die Kernfelder
// (Dublin Core + Calibre-/EPUB3-Serienangaben) und das Cover — ohne externe
// Programme, damit EPUB auch ohne exiftool/Calibre funktioniert.
//
// Unterstützt EPUB 2 und EPUB 3:
// - Serie: EPUB 3 `belongs-to-collection`/`group-position` UND die verbreiteten
//   Calibre-Metas (`calibre:series`, `calibre:series_index`) — gelesen wird
//   beides (EPUB 3 gewinnt), geschrieben werden beide Formen.
// - Cover: EPUB 3 Manifest-Property `cover-image`, EPUB 2 `<meta name="cover">`.
import Foundation
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum EpubFile {

    // MARK: - Lesen

    static func readCoreFields(url: URL) throws -> EbookCoreFields {
        let (document, _, _) = try loadOpf(url: url, accessMode: .read)
        guard let metadata = firstElement(named: "metadata", in: document.rootElement()) else {
            return EbookCoreFields()
        }

        var fields = EbookCoreFields()
        fields.title = textOfFirst("title", in: metadata)
        fields.authors = elements(named: "creator", in: metadata)
            // EPUB 2 markiert Rollen über opf:role; ohne Attribut gilt Autor.
            .filter { attribute($0, "role") == nil || attribute($0, "role") == "aut" }
            .map { $0.stringValue ?? "" }
            .filter { !$0.isEmpty }
        fields.description = textOfFirst("description", in: metadata)
        fields.publisher = textOfFirst("publisher", in: metadata)
        fields.language = textOfFirst("language", in: metadata)
        // dc:date kann mehrfach vorkommen (EPUB 2 mit opf:event) — erster Wert,
        // auf das reine Datum gekürzt, falls ein voller Zeitstempel drinsteht.
        fields.date = textOfFirst("date", in: metadata)
        fields.subjects = elements(named: "subject", in: metadata)
            .compactMap { $0.stringValue }
            .filter { !$0.isEmpty }
        fields.isbn = isbnFromIdentifiers(in: metadata)

        // Serie: EPUB 3 belongs-to-collection (mit group-position) vor Calibre-Metas.
        let metas = elements(named: "meta", in: metadata)
        if let collection = metas.first(where: { attribute($0, "property") == "belongs-to-collection" }) {
            fields.series = collection.stringValue ?? ""
            if let id = attribute(collection, "id"),
               let position = metas.first(where: {
                   attribute($0, "refines") == "#\(id)" && attribute($0, "property") == "group-position"
               }) {
                fields.seriesIndex = normalizedSeriesIndex(position.stringValue ?? "")
            }
        } else {
            for meta in metas {
                switch attribute(meta, "name") {
                case "calibre:series": fields.series = attribute(meta, "content") ?? ""
                case "calibre:series_index":
                    fields.seriesIndex = normalizedSeriesIndex(attribute(meta, "content") ?? "")
                default: break
                }
            }
        }
        return fields
    }

    /// Cover als Artwork (nil, wenn das EPUB keins deklariert).
    static func readCover(url: URL) throws -> Artwork? {
        let (document, opfPath, archive) = try loadOpf(url: url, accessMode: .read)
        guard let coverHref = coverHref(in: document) else { return nil }
        let coverPath = resolve(href: coverHref, relativeTo: opfPath)
        guard let entry = archive[coverPath] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let mime = Artwork.sniffMimeType(from: data) ?? ""
        return Artwork(data: data, mimeType: mime, pictureType: "Front Cover")
    }

    // MARK: - Schreiben

    /// Schreibt geänderte Kernfelder in die OPF (nur bei Differenz zu `original`).
    static func writeCoreFields(url: URL, fields: EbookCoreFields, original: EbookCoreFields) throws {
        guard fields != original else { return }
        try mapWriteError(url: url) {
            try AtomicFileRewrite.run(url: url) { temp in
                try writeCoreFieldsContents(
                    url: temp, fields: fields, original: original)
            } validate: { temp in
                try validateContainer(url: temp)
            }
        }
    }

    private static func writeCoreFieldsContents(
        url: URL, fields: EbookCoreFields, original: EbookCoreFields
    ) throws {
        let (document, opfPath, archive) = try loadOpf(url: url, accessMode: .update)
        guard let root = document.rootElement(),
              let metadata = firstElement(named: "metadata", in: root) else {
            throw TagError.cannotOpen(path: url.path)
        }

        // Dublin-Core-Namespace für neu angelegte Elemente; bestehende EPUBs
        // deklarieren "dc" auf <metadata> oder <package>.
        setSingle(metadata, "title", fields.title, fields.title != original.title)
        setSingle(metadata, "description", fields.description, fields.description != original.description)
        setSingle(metadata, "publisher", fields.publisher, fields.publisher != original.publisher)
        setSingle(metadata, "language", fields.language, fields.language != original.language)
        setSingle(metadata, "date", fields.date, fields.date != original.date)

        if fields.authors != original.authors {
            setList(metadata, "creator", fields.authors)
        }
        if fields.subjects != original.subjects {
            setList(metadata, "subject", fields.subjects)
        }
        if fields.isbn != original.isbn {
            writeIsbn(fields.isbn, in: metadata)
        }
        if fields.series != original.series || fields.seriesIndex != original.seriesIndex {
            writeSeries(fields, in: metadata)
        }

        try replaceEntry(path: opfPath, data: document.xmlData(options: .nodePrettyPrint), in: archive)
    }

    /// Ersetzt das Cover (bzw. legt eines an, wenn keins deklariert ist).
    static func writeCover(url: URL, data: Data) throws {
        try mapWriteError(url: url) {
            try AtomicFileRewrite.run(url: url) { temp in
                try writeCoverContents(url: temp, data: data)
            } validate: { temp in
                try validateContainer(url: temp)
            }
        }
    }

    /// Implementierungsdetail von writeCover; die Fehlerumsetzung bleibt am
    /// öffentlichen Schreibrand, damit alle ZIP-Schreibfehler gleich aussehen.
    private static func writeCoverContents(url: URL, data: Data) throws {
        let (document, opfPath, archive) = try loadOpf(url: url, accessMode: .update)
        let mime = Artwork.sniffMimeType(from: data) ?? "image/jpeg"

        if let href = coverHref(in: document) {
            // Vorhandenes Cover: Bytes ersetzen, Manifest-media-type aktualisieren
            // (Pfad/Endung bleiben — Reader richten sich nach dem media-type).
            let coverPath = resolve(href: href, relativeTo: opfPath)
            try replaceEntry(path: coverPath, data: data, in: archive)
            if let item = manifestItems(in: document).first(where: { attribute($0, "href") == href }),
               attribute(item, "media-type") != mime {
                setAttribute(item, "media-type", mime)
                try replaceEntry(path: opfPath, data: document.xmlData(options: .nodePrettyPrint), in: archive)
            }
            return
        }

        // Kein Cover deklariert: Datei neben die OPF legen und in Manifest +
        // beiden Cover-Konventionen (EPUB 2 meta + EPUB 3 property) eintragen.
        guard let root = document.rootElement(),
              let metadata = firstElement(named: "metadata", in: root),
              let manifest = firstElement(named: "manifest", in: root) else {
            throw TagError.cannotOpen(path: url.path)
        }
        let ext = mime == "image/png" ? "png" : "jpg"
        let items = manifestItems(in: document)
        let usedIDs = Set(items.compactMap { attribute($0, "id") })
        let usedHrefs = Set(items.compactMap { attribute($0, "href") })
        var suffix = 1
        var id = "cover-tagx"
        var href = "cover-tagx.\(ext)"
        var coverPath = resolve(href: href, relativeTo: opfPath)
        while usedIDs.contains(id) || usedHrefs.contains(href) || archive[coverPath] != nil {
            suffix += 1
            id = "cover-tagx-\(suffix)"
            href = "cover-tagx-\(suffix).\(ext)"
            coverPath = resolve(href: href, relativeTo: opfPath)
        }

        let item = XMLElement(name: "item")
        setAttribute(item, "id", id)
        setAttribute(item, "href", href)
        setAttribute(item, "media-type", mime)
        setAttribute(item, "properties", "cover-image")
        manifest.addChild(item)

        let meta = XMLElement(name: "meta")
        setAttribute(meta, "name", "cover")
        setAttribute(meta, "content", id)
        metadata.addChild(meta)

        try replaceEntry(path: coverPath, data: data, in: archive)
        try replaceEntry(path: opfPath, data: document.xmlData(options: .nodePrettyPrint), in: archive)
    }

    /// Entfernt die EPUB-2- und EPUB-3-Deklarationen eines Covers. Die
    /// Bildressource bleibt bewusst im Container: Sie könnte auch im Inhalt
    /// verlinkt sein; ein blindes Löschen würde das Buch beschädigen.
    static func removeCover(url: URL) throws {
        try mapWriteError(url: url) {
            try AtomicFileRewrite.run(url: url) { temp in
                try removeCoverContents(url: temp)
            } validate: { temp in
                try validateContainer(url: temp)
            }
        }
    }

    private static func removeCoverContents(url: URL) throws {
        let (document, opfPath, archive) = try loadOpf(url: url, accessMode: .update)
        guard let root = document.rootElement(),
              let metadata = firstElement(named: "metadata", in: root) else {
            throw TagError.cannotOpen(path: url.path)
        }

        // EPUB 2: <meta name="cover" content="manifest-id">.
        elements(named: "meta", in: metadata)
            .filter { attribute($0, "name") == "cover" }
            .forEach { $0.detach() }

        // EPUB 3: Das Token kann neben weiteren Eigenschaften stehen.
        for item in manifestItems(in: document) {
            let properties = (attribute(item, "properties") ?? "")
                .split(separator: " ").map(String.init)
            guard properties.contains("cover-image") else { continue }
            let remaining = properties.filter { $0 != "cover-image" }
            if remaining.isEmpty {
                if let attribute = (item.attributes ?? []).first(where: {
                    localName($0) == "properties"
                }) {
                    attribute.detach()
                }
            } else {
                setAttribute(item, "properties", remaining.joined(separator: " "))
            }
        }
        try replaceEntry(path: opfPath, data: document.xmlData(options: .nodePrettyPrint), in: archive)
    }

    // MARK: - Container/OPF

    /// Öffnet das Archiv, findet die OPF über META-INF/container.xml und
    /// liefert das geparste XML samt Pfad und Archiv zurück.
    private static func loadOpf(url: URL, accessMode: Archive.AccessMode) throws -> (XMLDocument, String, Archive) {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: accessMode)
        } catch {
            // Ein Read-Open scheitert beim Lesen, ein Update-Open dagegen beim
            // Schreiben (z.B. 0444 oder ein schreibgeschütztes Volume).
            switch accessMode {
            case .read: throw TagError.cannotOpen(path: url.path)
            case .update, .create: throw TagError.saveFailed(path: url.path)
            }
        }
        guard let containerEntry = archive["META-INF/container.xml"] else {
            throw TagError.cannotOpen(path: url.path)
        }
        var containerData = Data()
        _ = try archive.extract(containerEntry) { containerData.append($0) }
        let container = try XMLDocument(data: containerData)
        guard let rootfile = descendants(named: "rootfile", in: container.rootElement()).first,
              let opfPath = attribute(rootfile, "full-path"),
              let opfEntry = archive[opfPath] else {
            throw TagError.cannotOpen(path: url.path)
        }
        var opfData = Data()
        _ = try archive.extract(opfEntry) { opfData.append($0) }
        return (try XMLDocument(data: opfData), opfPath, archive)
    }

    /// Prüft die EPUB-Invarianten der vollständig geschriebenen Temp-Datei,
    /// bevor sie das Original atomar ersetzt.
    private static func validateContainer(url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        guard let first = archive.first(where: { _ in true }),
              first.path == "mimetype", !first.isCompressed else {
            throw TagError.cannotOpen(path: url.path)
        }
        var mimetype = Data()
        _ = try archive.extract(first) { mimetype.append($0) }
        guard String(decoding: mimetype, as: UTF8.self) == "application/epub+zip" else {
            throw TagError.cannotOpen(path: url.path)
        }

        let (document, opfPath, validatedArchive) = try loadOpf(url: url, accessMode: .read)
        if let href = coverHref(in: document) {
            guard validatedArchive[resolve(href: href, relativeTo: opfPath)] != nil else {
                throw TagError.cannotOpen(path: url.path)
            }
        }
    }

    /// ZIPFoundation kann beim Umschreiben unterschiedliche Detailfehler
    /// liefern. Nach außen ist jeder davon ein einheitlicher Speicherversuch.
    private static func mapWriteError(url: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
    }

    /// Cover-href aus dem Manifest: EPUB 3 `properties="cover-image"`,
    /// sonst EPUB 2 `<meta name="cover" content="<item-id>">`.
    private static func coverHref(in document: XMLDocument) -> String? {
        let items = manifestItems(in: document)
        if let item = items.first(where: {
            (attribute($0, "properties") ?? "").split(separator: " ").contains("cover-image")
        }) {
            return attribute(item, "href")
        }
        guard let root = document.rootElement(),
              let metadata = firstElement(named: "metadata", in: root),
              let meta = elements(named: "meta", in: metadata)
                  .first(where: { attribute($0, "name") == "cover" }),
              let coverId = attribute(meta, "content") else { return nil }
        return items.first(where: { attribute($0, "id") == coverId })
            .flatMap { attribute($0, "href") }
    }

    private static func manifestItems(in document: XMLDocument) -> [XMLElement] {
        guard let root = document.rootElement(),
              let manifest = firstElement(named: "manifest", in: root) else { return [] }
        return elements(named: "item", in: manifest)
    }

    /// href relativ zum OPF-Verzeichnis in einen Archiv-Pfad auflösen.
    private static func resolve(href: String, relativeTo opfPath: String) -> String {
        let dir = (opfPath as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return href }
        // Einfache Normalisierung reicht: EPUB-hrefs sind relative POSIX-Pfade.
        var parts = dir.split(separator: "/").map(String.init)
        for component in href.split(separator: "/").map(String.init) {
            if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(component) }
        }
        return parts.joined(separator: "/")
    }

    /// Ersetzt einen Archiv-Eintrag (bzw. legt ihn neu an). ZIPFoundation
    /// schreibt das Archiv dabei um; der `mimetype`-Eintrag bleibt an Position 1.
    private static func replaceEntry(path: String, data: Data, in archive: Archive) throws {
        if let existing = archive[path] {
            try archive.remove(existing)
        }
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(data.count),
                             compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    // MARK: - Metadaten-Helfer

    private static func isbnFromIdentifiers(in metadata: XMLElement) -> String {
        for identifier in elements(named: "identifier", in: metadata) {
            let value = (identifier.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if attribute(identifier, "scheme")?.uppercased() == "ISBN" {
                return value
            }
            if value.lowercased().hasPrefix("urn:isbn:") {
                return String(value.dropFirst("urn:isbn:".count))
            }
            if value.lowercased().hasPrefix("isbn:") {
                return String(value.dropFirst("isbn:".count))
            }
        }
        return ""
    }

    private static func writeIsbn(_ isbn: String, in metadata: XMLElement) {
        // Bestehende ISBN-Identifier entfernen (andere Identifier wie die
        // Paket-UUID bleiben unangetastet), dann ggf. neu anlegen.
        for identifier in elements(named: "identifier", in: metadata) {
            let value = (identifier.stringValue ?? "").lowercased()
            if attribute(identifier, "scheme")?.uppercased() == "ISBN"
                || value.hasPrefix("urn:isbn:") || value.hasPrefix("isbn:") {
                identifier.detach()
            }
        }
        guard !isbn.isEmpty else { return }
        let element = dcElement("identifier", value: "urn:isbn:\(isbn)", in: metadata)
        metadata.addChild(element)
    }

    private static func writeSeries(_ fields: EbookCoreFields, in metadata: XMLElement) {
        // Alle bisherigen Serien-Angaben (beide Konventionen) entfernen …
        var refinedIds: [String] = []
        for meta in elements(named: "meta", in: metadata) {
            let name = attribute(meta, "name")
            let property = attribute(meta, "property")
            if name == "calibre:series" || name == "calibre:series_index" {
                meta.detach()
            } else if property == "belongs-to-collection" {
                if let id = attribute(meta, "id") { refinedIds.append(id) }
                meta.detach()
            }
        }
        for meta in elements(named: "meta", in: metadata) {
            if let refines = attribute(meta, "refines"),
               refinedIds.contains(String(refines.dropFirst())) {
                meta.detach()
            }
        }
        guard !fields.series.isEmpty else { return }

        // … und in beiden Formen neu schreiben (EPUB 3 + Calibre-kompatibel).
        let collection = XMLElement(name: "meta")
        setAttribute(collection, "property", "belongs-to-collection")
        setAttribute(collection, "id", "series-tagx")
        collection.stringValue = fields.series
        metadata.addChild(collection)
        if !fields.seriesIndex.isEmpty {
            let position = XMLElement(name: "meta")
            setAttribute(position, "refines", "#series-tagx")
            setAttribute(position, "property", "group-position")
            position.stringValue = fields.seriesIndex
            metadata.addChild(position)
        }
        let calibreSeries = XMLElement(name: "meta")
        setAttribute(calibreSeries, "name", "calibre:series")
        setAttribute(calibreSeries, "content", fields.series)
        metadata.addChild(calibreSeries)
        if !fields.seriesIndex.isEmpty {
            let calibreIndex = XMLElement(name: "meta")
            setAttribute(calibreIndex, "name", "calibre:series_index")
            setAttribute(calibreIndex, "content", fields.seriesIndex)
            metadata.addChild(calibreIndex)
        }
    }

    /// Setzt ein einwertiges dc-Element (leerer Wert entfernt es).
    private static func setSingle(_ metadata: XMLElement, _ name: String, _ value: String, _ changed: Bool) {
        guard changed else { return }
        let existing = elements(named: name, in: metadata)
        if value.isEmpty {
            existing.forEach { $0.detach() }
            return
        }
        if let first = existing.first {
            first.stringValue = value
            existing.dropFirst().forEach { $0.detach() }
        } else {
            metadata.addChild(dcElement(name, value: value, in: metadata))
        }
    }

    /// Ersetzt alle Werte eines mehrwertigen dc-Elements (creator/subject).
    private static func setList(_ metadata: XMLElement, _ name: String, _ values: [String]) {
        elements(named: name, in: metadata).forEach { $0.detach() }
        for value in values where !value.isEmpty {
            metadata.addChild(dcElement(name, value: value, in: metadata))
        }
    }

    /// Neues Dublin-Core-Element mit dem im Dokument üblichen Präfix ("dc").
    private static func dcElement(_ name: String, value: String, in metadata: XMLElement) -> XMLElement {
        // Vorhandene dc-Elemente verraten das Präfix; Standard ist "dc".
        let prefix = (metadata.children ?? [])
            .compactMap { $0 as? XMLElement }
            .first { ["title", "language", "identifier"].contains(localName($0)) }?
            .name?.split(separator: ":").dropLast().first.map(String.init) ?? "dc"
        let element = XMLElement(name: "\(prefix):\(name)")
        element.stringValue = value
        return element
    }

    /// Gemeinsame Calibre-Konvention, siehe EbookTool.
    private static func normalizedSeriesIndex(_ raw: String) -> String {
        EbookTool.normalizedSeriesIndex(raw)
    }

    // MARK: - XML-Helfer (namespace-tolerant über lokale Namen)

    /// Lokaler Name ohne Präfix ("dc:title" → "title").
    private static func localName(_ node: XMLNode) -> String {
        guard let name = node.name else { return "" }
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    private static func elements(named name: String, in parent: XMLElement) -> [XMLElement] {
        (parent.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { localName($0) == name }
    }

    private static func firstElement(named name: String, in parent: XMLElement?) -> XMLElement? {
        guard let parent else { return nil }
        return elements(named: name, in: parent).first
    }

    /// Text des ersten Elements mit diesem lokalen Namen ("" wenn keins).
    private static func textOfFirst(_ name: String, in parent: XMLElement) -> String {
        elements(named: name, in: parent).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Rekursive Suche (für container.xml, wo die Tiefe egal ist).
    private static func descendants(named name: String, in parent: XMLElement?) -> [XMLElement] {
        guard let parent else { return [] }
        var result: [XMLElement] = []
        for child in (parent.children ?? []).compactMap({ $0 as? XMLElement }) {
            if localName(child) == name { result.append(child) }
            result.append(contentsOf: descendants(named: name, in: child))
        }
        return result
    }

    /// Attributwert namespace-tolerant (auch "opf:role" findet "role" nicht —
    /// deshalb über lokale Namen vergleichen).
    private static func attribute(_ element: XMLElement, _ name: String) -> String? {
        (element.attributes ?? [])
            .first { localName($0) == name }?
            .stringValue
    }

    private static func setAttribute(_ element: XMLElement, _ name: String, _ value: String) {
        if let existing = (element.attributes ?? []).first(where: { localName($0) == name }) {
            existing.stringValue = value
            return
        }
        let node = XMLNode(kind: .attribute)
        node.name = name
        node.stringValue = value
        element.addAttribute(node)
    }
}

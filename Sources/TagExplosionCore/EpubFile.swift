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
            .filter { isAuthor($0, in: metadata) }
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

        // Serie: EPUB 3 belongs-to-collection (mit group-position) vor Calibre-
        // Metas. Nur als Serie klassifizierte Sammlungen zählen — ein Buch kann
        // daneben weiteren Sammlungen (z.B. collection-type="set") angehören.
        let metas = elements(named: "meta", in: metadata)
        if let collection = metas.first(where: { isSeriesCollection($0, in: metadata) }) {
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
            replaceAuthors(metadata, with: fields.authors)
        }
        if fields.subjects != original.subjects {
            setList(metadata, "subject", fields.subjects)
        }
        if fields.isbn != original.isbn {
            writeIsbn(fields.isbn, in: metadata, package: root)
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
        // XML-IDs gelten im gesamten OPF-Dokument. Auch dc:creator,
        // dc:identifier oder ein anderer Knoten außerhalb des Manifests kann
        // den bevorzugten Namen bereits belegen.
        let usedIDs = allIds(in: document)
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

    /// Ändert Kernfelder und Cover DIREKT in der übergebenen Datei — ohne
    /// eigene Kopie und ohne eigenen atomaren Austausch.
    ///
    /// Gedacht für `EbookTool.write`, das bereits auf einer Geschwisterkopie
    /// arbeitet: Über `writeCoreFields`/`writeCover` entstünde dort eine ZWEITE
    /// Vollkopie (doppelter Platzbedarf auf Datenträgern ohne Klonen), und ein
    /// Platzmangel nennte den versteckten Temp-Pfad statt der gewählten Datei.
    /// Für Einzelaufrufe bleiben die atomaren Wege oben zuständig.
    static func mutateContents(url: URL, fields: EbookCoreFields,
                               original: EbookCoreFields,
                               coverUpdate: EbookCoverUpdate) throws {
        if fields != original {
            try writeCoreFieldsContents(url: url, fields: fields, original: original)
        }
        switch coverUpdate {
        case .unchanged: break
        case .set(let data): try writeCoverContents(url: url, data: data)
        case .remove: try removeCoverContents(url: url)
        }
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
    /// bevor sie das Original atomar ersetzt. Auch `EbookTool.write` prüft
    /// damit seine Geschwisterkopie, seit dort kein verschachtelter
    /// EPUB-Austausch mehr läuft.
    static func validateContainer(url: URL) throws {
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
    /// Ausnahme: Platzmangel bleibt als `notEnoughSpace` sichtbar — CLI und
    /// App melden ihn gezielt; er trägt außerdem bereits den Originalpfad.
    /// Andere typisierte Fehler (z.B. `cannotOpen` aus der Temp-Prüfung)
    /// werden weiter vereinheitlicht, weil sie den Pfad der versteckten
    /// Geschwisterkopie nennen würden.
    private static func mapWriteError(url: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as TagError {
            if case .notEnoughSpace = error { throw error }
            throw TagError.saveFailed(path: url.path)
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
        // Manifest-hrefs sind URLs, ZIPFoundation adressiert dagegen den
        // dekodierten Eintragsnamen. Query und Fragment gehören ebenfalls
        // nicht zum Pfad im Archiv.
        let suffix = href.firstIndex { $0 == "?" || $0 == "#" } ?? href.endIndex
        let encodedPath = String(href[..<suffix])
        let hrefPath = encodedPath.removingPercentEncoding ?? encodedPath
        let dir = (opfPath as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return hrefPath }
        // Einfache Normalisierung reicht: EPUB-hrefs sind relative POSIX-Pfade.
        var parts = dir.split(separator: "/").map(String.init)
        for component in hrefPath.split(separator: "/").map(String.init) {
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

    /// `package` ist das Wurzelelement der OPF. Sein Attribut
    /// `unique-identifier` nennt die id des Identifiers, der das Buch
    /// eindeutig macht — sehr oft ist das genau der ISBN-Knoten. Ein OPF, in
    /// dem dieser Verweis ins Leere zeigt, ist kein gültiges EPUB mehr.
    private static func writeIsbn(_ isbn: String, in metadata: XMLElement, package: XMLElement) {
        let packageId = attribute(package, "unique-identifier")
        // Bestehende ISBN-Identifier entfernen (andere Identifier wie die
        // Paket-UUID bleiben unangetastet), dann ggf. neu anlegen.
        var removedIds: [String] = []
        var packageIdentifierWasIsbn = false
        for identifier in elements(named: "identifier", in: metadata) {
            let value = (identifier.stringValue ?? "").lowercased()
            guard attribute(identifier, "scheme")?.uppercased() == "ISBN"
                || value.hasPrefix("urn:isbn:") || value.hasPrefix("isbn:") else { continue }
            if let id = attribute(identifier, "id") {
                if id == packageId { packageIdentifierWasIsbn = true } else { removedIds.append(id) }
            }
            identifier.detach()
        }
        // Verfeinerungen (z.B. identifier-type) eines entfernten Identifiers
        // zeigten sonst auf einen nicht mehr vorhandenen Knoten.
        detachRefinements(of: removedIds, in: metadata)

        if !isbn.isEmpty {
            let element = dcElement("identifier", value: "urn:isbn:\(isbn)", in: metadata)
            // War die alte ISBN der Paket-Identifier, übernimmt die neue seine
            // id: Der Paketverweis und vorhandene refines ("identifier-type:
            // ISBN") bleiben damit richtig.
            if packageIdentifierWasIsbn, let packageId {
                setAttribute(element, "id", packageId)
            }
            metadata.addChild(element)
            return
        }

        guard packageIdentifierWasIsbn, let packageId else { return }
        // ISBN gelöscht, obwohl sie das Buch identifizierte: Der Verweis
        // braucht ein Ziel. Eine neutrale UUID unter derselben id erhält die
        // Gültigkeit; die alte identifier-type-Verfeinerung beschrieb die ISBN
        // und passt nicht mehr.
        detachRefinements(of: [packageId], in: metadata)
        let replacement = dcElement(
            "identifier", value: "urn:uuid:\(UUID().uuidString.lowercased())", in: metadata)
        setAttribute(replacement, "id", packageId)
        metadata.addChild(replacement)
    }

    private static func writeSeries(_ fields: EbookCoreFields, in metadata: XMLElement) {
        // Nur die bisherigen SERIEN-Angaben entfernen (beide Konventionen).
        // Andere Sammlungen des Buchs (z.B. collection-type="set") sind
        // eigenständige Metadaten und bleiben samt Verfeinerungen erhalten.
        var refinedIds: [String] = []
        for meta in elements(named: "meta", in: metadata) {
            let name = attribute(meta, "name")
            if name == "calibre:series" || name == "calibre:series_index" {
                meta.detach()
            } else if isSeriesCollection(meta, in: metadata) {
                if let id = attribute(meta, "id") { refinedIds.append(id) }
                meta.detach()
            }
        }
        detachRefinements(of: refinedIds, in: metadata)
        guard !fields.series.isEmpty else { return }

        // … und in beiden Formen neu schreiben (EPUB 3 + Calibre-kompatibel).
        // Die id muss im GESAMTEN OPF-Dokument eindeutig sein, nicht nur unter
        // den <meta>-Elementen: Auch dc:creator, dc:identifier oder ein
        // Manifest-Eintrag kann "series-tagx" schon tragen. Eine doppelte
        // XML-ID machte die neuen refines-Verweise mehrdeutig.
        let scope: XMLNode = metadata.rootDocument ?? metadata
        let usedIds = allIds(in: scope)
        var seriesId = "series-tagx"
        var suffix = 2
        while usedIds.contains(seriesId) {
            seriesId = "series-tagx-\(suffix)"
            suffix += 1
        }
        let collection = XMLElement(name: "meta")
        setAttribute(collection, "property", "belongs-to-collection")
        setAttribute(collection, "id", seriesId)
        collection.stringValue = fields.series
        metadata.addChild(collection)
        // Der explizite Sammlungstyp macht die eigene Serie beim Wiederlesen
        // (auch durch andere Programme) eindeutig als Serie erkennbar.
        let collectionType = XMLElement(name: "meta")
        setAttribute(collectionType, "refines", "#\(seriesId)")
        setAttribute(collectionType, "property", "collection-type")
        collectionType.stringValue = "series"
        metadata.addChild(collectionType)
        if !fields.seriesIndex.isEmpty {
            let position = XMLElement(name: "meta")
            setAttribute(position, "refines", "#\(seriesId)")
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

    /// Ist dieses `meta` eine als Serie zu behandelnde Sammlung? Eine
    /// `belongs-to-collection` zählt als Serie, wenn ihre `collection-type`-
    /// Verfeinerung "series" lautet ODER ganz fehlt (verbreitete Praxis, auch
    /// unser eigenes Format vor dieser Ergänzung). Andere Typen ("set" …)
    /// sind eigenständige Sammlungen.
    private static func isSeriesCollection(_ meta: XMLElement, in metadata: XMLElement) -> Bool {
        guard attribute(meta, "property") == "belongs-to-collection" else { return false }
        guard let id = attribute(meta, "id"),
              let type = elements(named: "meta", in: metadata).first(where: {
                  attribute($0, "refines") == "#\(id)"
                      && attribute($0, "property") == "collection-type"
              })?.stringValue
        else { return true }
        return type == "series"
    }

    /// Rolle eines Creators: EPUB 2 als Inline-Attribut (`opf:role`), EPUB 3
    /// als Verfeinerung (`<meta refines="#id" property="role">`).
    private static func creatorRole(_ creator: XMLElement, in metadata: XMLElement) -> String? {
        if let role = attribute(creator, "role") { return role }
        guard let id = attribute(creator, "id") else { return nil }
        return elements(named: "meta", in: metadata).first(where: {
            attribute($0, "refines") == "#\(id)" && attribute($0, "property") == "role"
        })?.stringValue
    }

    /// Ohne Rolle gilt ein Creator als Autor; sonst zählt nur "aut".
    /// Editoren, Übersetzer usw. sind eigenständige Metadaten.
    private static func isAuthor(_ creator: XMLElement, in metadata: XMLElement) -> Bool {
        let role = creatorRole(creator, in: metadata)
        return role == nil || role == "aut"
    }

    /// Ersetzt ausschließlich die als Autoren klassifizierten Creator.
    /// Creator mit anderer Rolle bleiben samt ihrer Verfeinerungen erhalten —
    /// eine reine Autorenänderung darf keine fremden Mitwirkenden löschen.
    private static func replaceAuthors(_ metadata: XMLElement, with authors: [String]) {
        var removedIds: [String] = []
        for creator in elements(named: "creator", in: metadata)
        where isAuthor(creator, in: metadata) {
            if let id = attribute(creator, "id") { removedIds.append(id) }
            creator.detach()
        }
        detachRefinements(of: removedIds, in: metadata)
        for value in authors where !value.isEmpty {
            metadata.addChild(dcElement("creator", value: value, in: metadata))
        }
    }

    /// Entfernt alle Verfeinerungen (`refines="#id"`), deren Bezugselement
    /// gerade entfernt wurde — sonst blieben verwaiste Metas zurück.
    private static func detachRefinements(of ids: [String], in metadata: XMLElement) {
        guard !ids.isEmpty else { return }
        for meta in elements(named: "meta", in: metadata) {
            if let refines = attribute(meta, "refines"),
               ids.contains(String(refines.dropFirst())) {
                meta.detach()
            }
        }
    }

    /// Setzt ein einwertiges dc-Element (leerer Wert entfernt es).
    private static func setSingle(_ metadata: XMLElement, _ name: String, _ value: String, _ changed: Bool) {
        guard changed else { return }
        let existing = elements(named: name, in: metadata)
        if value.isEmpty {
            detachRefinements(of: existing.compactMap { attribute($0, "id") }, in: metadata)
            existing.forEach { $0.detach() }
            return
        }
        if let first = existing.first {
            first.stringValue = value
        } else {
            metadata.addChild(dcElement(name, value: value, in: metadata))
        }
    }

    /// Ersetzt alle Werte eines mehrwertigen dc-Elements (creator/subject).
    private static func setList(_ metadata: XMLElement, _ name: String, _ values: [String]) {
        let existing = elements(named: name, in: metadata)
        // Verfeinerungen der ersetzten Werte dürfen nicht als Verweise auf
        // nicht mehr vorhandene XML-IDs stehen bleiben.
        detachRefinements(of: existing.compactMap { attribute($0, "id") }, in: metadata)
        existing.forEach { $0.detach() }
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

    /// Alle `id`-Attribute unterhalb (und einschließlich) `node`. Eine neu
    /// vergebene XML-ID muss gegen ALLE bestehenden eindeutig sein, nicht nur
    /// gegen die der direkten Geschwister.
    private static func allIds(in node: XMLNode) -> Set<String> {
        var result: Set<String> = []
        if let element = node as? XMLElement, let id = attribute(element, "id") {
            result.insert(id)
        }
        for child in (node.children ?? []) {
            result.formUnion(allIds(in: child))
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

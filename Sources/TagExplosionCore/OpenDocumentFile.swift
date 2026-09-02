// OpenDocument (odt/ods/odp): Metadaten liegen in `meta.xml` unter
// `office:document-meta/office:meta`. Der ZIP-Container verlangt den
// `mimetype`-Eintrag unkomprimiert an erster Stelle — `ZipContainer.rewrite`
// hält Reihenfolge und Kompressionsart aller Einträge bei.
//
// Feldzuordnung (Lesen und Schreiben):
//   title ↔ dc:title · subject ↔ dc:subject · description ↔ dc:description
//   authors ↔ dc:creator ("A; B") · keywords ↔ meta:keyword (mehrere Elemente)
//   language ↔ dc:language · created ↔ meta:creation-date · modified ↔ dc:date
//   Zusatzfelder: initial-creator ↔ meta:initial-creator · generator ↔ meta:generator
// Kein Speicherort: publisher, category.
//
// Achtung Semantik: In ODF ist `dc:creator` die Person der LETZTEN Änderung,
// `meta:initial-creator` die ursprüngliche Autorin. Der Autoren-Feldsatz
// bleibt trotzdem auf dc:creator, damit OOXML und ODF gleich abgebildet sind
// (beide dc:creator); initial-creator ist als Zusatzfeld sichtbar und
// editierbar. Siehe knowledge/dokument-container-metadaten.md.
import Foundation
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum OpenDocumentFile: DocumentBackend {

    static let supportedFields: Set<DocumentField> = [
        .title, .authors, .subject, .description, .keywords, .language,
        .created, .modified,
    ]
    static let customKeys: [String]? = ["initial-creator", "generator"]

    private static let officeURI = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let metaURI = "urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
    private static let dcURI = "http://purl.org/dc/elements/1.1/"
    private static let manifestURI = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"
    private static let mimetypePrefix = "application/vnd.oasis.opendocument."

    // MARK: - Lesen

    static func read(url: URL) throws -> (DocumentCoreFields, [DocumentInfoItem]) {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        try requireOpenDocument(archive: archive, url: url)
        var fields = DocumentCoreFields()
        var info: [DocumentInfoItem] = []
        if let data = try ZipContainer.data(at: "meta.xml", in: archive) {
            let document = try XMLTools.document(from: data, path: url.path)
            guard let meta = XMLTools.firstElement(named: "meta", in: document.rootElement()) else {
                throw TagError.cannotOpen(path: url.path)
            }
            fields.title = XMLTools.text(of: "title", in: meta)
            fields.authors = DocumentTool.splitList(
                XMLTools.text(of: "creator", in: meta), separators: [";"])
            fields.subject = XMLTools.text(of: "subject", in: meta)
            fields.description = XMLTools.text(of: "description", in: meta)
            fields.keywords = XMLTools.elements(named: "keyword", in: meta)
                .map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            fields.language = XMLTools.text(of: "language", in: meta)
            fields.created = XMLTools.text(of: "creation-date", in: meta)
            fields.modified = XMLTools.text(of: "date", in: meta)
            fields.setCustom("initial-creator", XMLTools.text(of: "initial-creator", in: meta))
            fields.setCustom("generator", XMLTools.text(of: "generator", in: meta))

            // Anzeige: Bearbeitungszyklen/-dauer und die Dokumentstatistik
            // (Seiten, Wörter, Zeichen … als Attribute eines Elements).
            for name in ["editing-cycles", "editing-duration", "print-date", "printed-by"] {
                let value = XMLTools.text(of: name, in: meta)
                if !value.isEmpty { info.append(DocumentInfoItem(label: name, value: value)) }
            }
            if let statistic = XMLTools.firstElement(named: "document-statistic", in: meta) {
                for attribute in statistic.attributes ?? [] {
                    guard let value = attribute.stringValue, !value.isEmpty else { continue }
                    info.append(DocumentInfoItem(label: XMLTools.localName(attribute), value: value))
                }
            }
        }
        return (fields, info)
    }

    // MARK: - Schreiben

    static func validate(_ fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        if fields.authors != original.authors {
            try DocumentTool.requireValues(fields.authors, free: [";"], field: .authors)
        }
        if fields.created != original.created {
            try DocumentTool.requireW3CDateTime(fields.created, field: .created)
        }
        if fields.modified != original.modified {
            try DocumentTool.requireW3CDateTime(fields.modified, field: .modified)
        }
    }

    static func mutate(url: URL, fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        try requireOpenDocument(archive: archive, url: url)
        var replacements: [String: Data] = [:]

        let document: XMLDocument
        if let existing = try ZipContainer.data(at: "meta.xml", in: archive) {
            document = try XMLTools.document(from: existing, path: url.path)
        } else {
            document = try emptyMetaDocument()
            if let manifest = try registerInManifest(archive: archive, url: url) {
                replacements["META-INF/manifest.xml"] = manifest
            }
        }
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
        let office = XMLTools.prefix(for: officeURI, preferred: "office", in: root)
        let dc = XMLTools.prefix(for: dcURI, preferred: "dc", in: root)
        let metaPrefix = XMLTools.prefix(for: metaURI, preferred: "meta", in: root)
        let meta: XMLElement
        if let existing = XMLTools.firstElement(named: "meta", in: root) {
            meta = existing
        } else {
            meta = XMLElement(name: "\(office):meta")
            root.addChild(meta)
        }

        func set(_ name: String, prefix: String, _ new: String, _ old: String) {
            guard new != old else { return }
            XMLTools.setSingle(meta, name, prefix: prefix, value: new)
        }
        set("title", prefix: dc, fields.title, original.title)
        set("creator", prefix: dc, fields.authors.joined(separator: "; "),
            original.authors.joined(separator: "; "))
        set("subject", prefix: dc, fields.subject, original.subject)
        set("description", prefix: dc, fields.description, original.description)
        set("language", prefix: dc, fields.language, original.language)
        set("creation-date", prefix: metaPrefix, fields.created, original.created)
        set("date", prefix: dc, fields.modified, original.modified)
        set("initial-creator", prefix: metaPrefix, fields.customValue(for: "initial-creator"),
            original.customValue(for: "initial-creator"))
        set("generator", prefix: metaPrefix, fields.customValue(for: "generator"),
            original.customValue(for: "generator"))
        if fields.keywords != original.keywords {
            XMLTools.setList(meta, "keyword", prefix: metaPrefix, values: fields.keywords)
        }

        replacements["meta.xml"] = XMLTools.serialize(document)
        try ZipContainer.rewrite(url: url, replacing: replacements)
    }

    /// Nach dem Schreiben: mimetype weiterhin unkomprimiert an erster Stelle,
    /// meta.xml vorhanden und parsebar.
    static func validateContainer(url: URL) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        try requireOpenDocument(archive: archive, url: url)
        guard let data = try ZipContainer.data(at: "meta.xml", in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        _ = try XMLTools.document(from: data, path: url.path)
    }

    // MARK: - Container

    /// Erster Eintrag muss `mimetype` sein, unkomprimiert, mit ODF-MIME-Type.
    private static func requireOpenDocument(archive: Archive, url: URL) throws {
        guard let first = archive.first(where: { _ in true }),
              first.path == "mimetype", !first.isCompressed else {
            throw TagError.cannotOpen(path: url.path)
        }
        let mimetype = String(decoding: try ZipContainer.data(of: first, in: archive), as: UTF8.self)
        guard mimetype.hasPrefix(mimetypePrefix) else {
            throw TagError.cannotOpen(path: url.path)
        }
    }

    private static func emptyMetaDocument() throws -> XMLDocument {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta xmlns:office="\(officeURI)" xmlns:meta="\(metaURI)" \
        xmlns:dc="\(dcURI)" office:version="1.3"><office:meta/></office:document-meta>
        """
        return try XMLDocument(data: Data(xml.utf8))
    }

    /// Ein neues meta.xml gehört ins Manifest; nil, wenn es dort schon steht.
    private static func registerInManifest(archive: Archive, url: URL) throws -> Data? {
        guard let data = try ZipContainer.data(at: "META-INF/manifest.xml", in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        let document = try XMLTools.document(from: data, path: url.path)
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
        if XMLTools.elements(named: "file-entry", in: root)
            .contains(where: { XMLTools.attribute($0, "full-path") == "meta.xml" }) {
            return nil
        }
        let prefix = XMLTools.prefix(for: manifestURI, preferred: "manifest", in: root)
        let entry = XMLElement(name: "\(prefix):file-entry")
        XMLTools.setAttribute(entry, "\(prefix):full-path", "meta.xml")
        XMLTools.setAttribute(entry, "\(prefix):media-type", "text/xml")
        root.addChild(entry)
        return XMLTools.serialize(document)
    }
}

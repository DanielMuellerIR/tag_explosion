// Office Open XML (docx/xlsx/pptx): Metadaten liegen in `docProps/core.xml`
// (Dublin Core + cp-Namensraum), Anwendungsangaben wie Seiten- und Wortzahl in
// `docProps/app.xml` (nur Anzeige). Beide Pfade nennt `_rels/.rels`; fehlt die
// Beziehung, gelten die üblichen Standardpfade.
//
// Feldzuordnung (Lesen und Schreiben):
//   title ↔ dc:title · authors ↔ dc:creator ("A; B") · subject ↔ dc:subject
//   description ↔ dc:description · keywords ↔ cp:keywords ("a, b" / "a; b")
//   category ↔ cp:category · language ↔ dc:language
//   created ↔ dcterms:created · modified ↔ dcterms:modified (W3CDTF)
//   Zusatzfelder: lastModifiedBy ↔ cp:lastModifiedBy · revision ↔ cp:revision
// Kein Speicherort: publisher.
//
// Fehlt core.xml ganz (manche Generatoren lassen es weg), legt der Schreibweg
// es an und registriert es in `[Content_Types].xml` und `_rels/.rels` —
// ohne beide Einträge ignoriert Word die Datei.
import Foundation
import ZIPFoundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum OfficeDocumentFile: DocumentBackend {

    static let supportedFields: Set<DocumentField> = [
        .title, .authors, .subject, .description, .keywords, .language,
        .category, .created, .modified,
    ]
    static let customKeys: [String]? = ["lastModifiedBy", "revision"]

    // Namensräume von core.xml
    private static let cpURI = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    private static let dcURI = "http://purl.org/dc/elements/1.1/"
    private static let dctermsURI = "http://purl.org/dc/terms/"
    private static let xsiURI = "http://www.w3.org/2001/XMLSchema-instance"
    private static let coreRelationshipType =
        "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    private static let appRelationshipType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
    private static let coreContentType = "application/vnd.openxmlformats-package.core-properties+xml"
    private static let defaultCorePath = "docProps/core.xml"

    // MARK: - Lesen

    static func read(url: URL) throws -> (DocumentCoreFields, [DocumentInfoItem]) {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        guard archive["[Content_Types].xml"] != nil else {
            throw TagError.cannotOpen(path: url.path)
        }
        var fields = DocumentCoreFields()
        if let coreData = try ZipContainer.data(at: corePath(in: archive), in: archive) {
            let document = try XMLTools.document(from: coreData, path: url.path)
            guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
            fields.title = XMLTools.text(of: "title", in: root)
            fields.authors = DocumentTool.splitList(
                XMLTools.text(of: "creator", in: root), separators: [";"])
            fields.subject = XMLTools.text(of: "subject", in: root)
            fields.description = XMLTools.text(of: "description", in: root)
            fields.keywords = DocumentTool.splitList(
                XMLTools.text(of: "keywords", in: root), separators: [",", ";"])
            fields.language = XMLTools.text(of: "language", in: root)
            fields.category = XMLTools.text(of: "category", in: root)
            fields.created = XMLTools.text(of: "created", in: root)
            fields.modified = XMLTools.text(of: "modified", in: root)
            fields.setCustom("lastModifiedBy", XMLTools.text(of: "lastModifiedBy", in: root))
            fields.setCustom("revision", XMLTools.text(of: "revision", in: root))
        }
        return (fields, try readInfo(url: url, archive: archive))
    }

    /// app.xml: alle einfachen Textelemente (Application, Pages, Words, …).
    /// Verschachtelte Angaben (HeadingPairs, TitlesOfParts) bleiben außen vor.
    private static func readInfo(url: URL, archive: Archive) throws -> [DocumentInfoItem] {
        let path = relationshipTarget(ofType: appRelationshipType, in: archive) ?? "docProps/app.xml"
        guard let data = try ZipContainer.data(at: path, in: archive) else { return [] }
        let document = try XMLTools.document(from: data, path: url.path)
        guard let root = document.rootElement() else { return [] }
        return (root.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { element in
                (element.children ?? []).allSatisfy { $0.kind == .text }
            }
            .compactMap { element in
                let value = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return DocumentInfoItem(label: XMLTools.localName(element), value: value)
            }
    }

    // MARK: - Schreiben

    static func validate(_ fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        if fields.authors != original.authors {
            try DocumentTool.requireValues(fields.authors, free: [";"], field: .authors)
        }
        if fields.keywords != original.keywords {
            try DocumentTool.requireValues(fields.keywords, free: [",", ";"], field: .keywords)
        }
        if fields.created != original.created {
            try DocumentTool.requireW3CDateTime(fields.created, field: .created)
        }
        if fields.modified != original.modified {
            try DocumentTool.requireW3CDateTime(fields.modified, field: .modified)
        }
        let revision = fields.customValue(for: "revision")
        if revision != original.customValue(for: "revision"), !revision.isEmpty,
           Int(revision) == nil {
            throw TagError.invalidDocumentValue(field: "revision", reason: "expected a whole number")
        }
    }

    static func mutate(url: URL, fields: DocumentCoreFields, original: DocumentCoreFields) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let path = corePath(in: archive)
        var replacements: [String: Data] = [:]

        let document: XMLDocument
        if let existing = try ZipContainer.data(at: path, in: archive) {
            document = try XMLTools.document(from: existing, path: url.path)
        } else {
            document = try emptyCoreDocument()
            // Neu angelegte Teile müssen im Paket registriert sein.
            replacements["[Content_Types].xml"] = try registerContentType(
                archive: archive, url: url, partPath: path)
            replacements["_rels/.rels"] = try registerRelationship(
                archive: archive, url: url, partPath: path)
        }
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
        let dc = XMLTools.prefix(for: dcURI, preferred: "dc", in: root)
        let cp = XMLTools.prefix(for: cpURI, preferred: "cp", in: root)
        let dcterms = XMLTools.prefix(for: dctermsURI, preferred: "dcterms", in: root)

        func set(_ name: String, prefix: String, _ new: String, _ old: String) {
            guard new != old else { return }
            XMLTools.setSingle(root, name, prefix: prefix, value: new)
        }
        set("title", prefix: dc, fields.title, original.title)
        set("creator", prefix: dc, fields.authors.joined(separator: "; "),
            original.authors.joined(separator: "; "))
        set("subject", prefix: dc, fields.subject, original.subject)
        set("description", prefix: dc, fields.description, original.description)
        set("keywords", prefix: cp, fields.keywords.joined(separator: ", "),
            original.keywords.joined(separator: ", "))
        set("language", prefix: dc, fields.language, original.language)
        set("category", prefix: cp, fields.category, original.category)
        set("lastModifiedBy", prefix: cp, fields.customValue(for: "lastModifiedBy"),
            original.customValue(for: "lastModifiedBy"))
        set("revision", prefix: cp, fields.customValue(for: "revision"),
            original.customValue(for: "revision"))
        if fields.created != original.created {
            setDate("created", prefix: dcterms, fields.created, in: root)
        }
        if fields.modified != original.modified {
            setDate("modified", prefix: dcterms, fields.modified, in: root)
        }

        replacements[path] = XMLTools.serialize(document)
        try ZipContainer.rewrite(url: url, replacing: replacements)
    }

    /// dcterms-Daten tragen zwingend `xsi:type="dcterms:W3CDTF"`; ohne das
    /// Attribut lehnt Word das Dokument ab.
    private static func setDate(_ name: String, prefix: String, _ value: String, in root: XMLElement) {
        XMLTools.setSingle(root, name, prefix: prefix, value: value)
        guard !value.isEmpty, let element = XMLTools.firstElement(named: name, in: root) else { return }
        let xsi = XMLTools.prefix(for: xsiURI, preferred: "xsi", in: root)
        XMLTools.setAttribute(element, "\(xsi):type", "\(prefix):W3CDTF")
    }

    static func validateContainer(url: URL) throws {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        guard archive["[Content_Types].xml"] != nil,
              let data = try ZipContainer.data(at: corePath(in: archive), in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        _ = try XMLTools.document(from: data, path: url.path)
    }

    // MARK: - Paketstruktur

    /// Pfad von core.xml laut `_rels/.rels` (Standard: docProps/core.xml).
    private static func corePath(in archive: Archive) -> String {
        relationshipTarget(ofType: coreRelationshipType, in: archive) ?? defaultCorePath
    }

    private static func relationshipTarget(ofType type: String, in archive: Archive) -> String? {
        guard let data = try? ZipContainer.data(at: "_rels/.rels", in: archive),
              let document = try? XMLDocument(data: data),
              let root = document.rootElement() else { return nil }
        for relationship in XMLTools.elements(named: "Relationship", in: root)
        where XMLTools.attribute(relationship, "Type") == type {
            guard let target = XMLTools.attribute(relationship, "Target") else { continue }
            // Ziele sind paketrelativ; ein führender Schrägstrich ist erlaubt.
            return target.hasPrefix("/") ? String(target.dropFirst()) : target
        }
        return nil
    }

    private static func emptyCoreDocument() throws -> XMLDocument {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="\(cpURI)" xmlns:dc="\(dcURI)" xmlns:dcterms="\(dctermsURI)" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="\(xsiURI)"></cp:coreProperties>
        """
        return try XMLDocument(data: Data(xml.utf8))
    }

    /// `[Content_Types].xml` um den Override für core.xml ergänzen.
    private static func registerContentType(archive: Archive, url: URL, partPath: String) throws -> Data {
        guard let data = try ZipContainer.data(at: "[Content_Types].xml", in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        let document = try XMLTools.document(from: data, path: url.path)
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
        let partName = "/" + partPath
        if XMLTools.elements(named: "Override", in: root)
            .contains(where: { XMLTools.attribute($0, "PartName") == partName }) {
            return data
        }
        let override = XMLElement(name: "Override")
        XMLTools.setAttribute(override, "PartName", partName)
        XMLTools.setAttribute(override, "ContentType", coreContentType)
        root.addChild(override)
        return XMLTools.serialize(document)
    }

    /// `_rels/.rels` um die Beziehung zu core.xml ergänzen (eindeutige Id).
    private static func registerRelationship(archive: Archive, url: URL, partPath: String) throws -> Data {
        guard let data = try ZipContainer.data(at: "_rels/.rels", in: archive) else {
            throw TagError.cannotOpen(path: url.path)
        }
        let document = try XMLTools.document(from: data, path: url.path)
        guard let root = document.rootElement() else { throw TagError.cannotOpen(path: url.path) }
        let relationships = XMLTools.elements(named: "Relationship", in: root)
        if relationships.contains(where: { XMLTools.attribute($0, "Type") == coreRelationshipType }) {
            return data
        }
        let usedIds = Set(relationships.compactMap { XMLTools.attribute($0, "Id") })
        var counter = relationships.count + 1
        var id = "rId\(counter)"
        while usedIds.contains(id) {
            counter += 1
            id = "rId\(counter)"
        }
        let relationship = XMLElement(name: "Relationship")
        XMLTools.setAttribute(relationship, "Id", id)
        XMLTools.setAttribute(relationship, "Type", coreRelationshipType)
        XMLTools.setAttribute(relationship, "Target", partPath)
        root.addChild(relationship)
        return XMLTools.serialize(document)
    }
}

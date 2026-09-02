// Kleine, namespace-tolerante XML-Helfer für die Dokument-Backends (OOXML
// core.xml, OpenDocument meta.xml, ComicInfo.xml). Verglichen wird über den
// lokalen Namen ("dc:title" → "title"), damit ein abweichendes Präfix in
// fremden Dateien keine Rolle spielt. Zum Anlegen neuer Elemente wird das im
// Dokument deklarierte Präfix des Namensraums wiederverwendet.
//
// EpubFile hält aus historischen Gründen eigene, gleichartige Helfer; sie
// bleiben dort unangetastet (EPUB-Verhalten unverändert).
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum XMLTools {

    /// Lokaler Name ohne Präfix ("dc:title" → "title").
    static func localName(_ node: XMLNode) -> String {
        guard let name = node.name else { return "" }
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    /// Direkte Kindelemente mit diesem lokalen Namen.
    static func elements(named name: String, in parent: XMLElement) -> [XMLElement] {
        (parent.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { localName($0) == name }
    }

    static func firstElement(named name: String, in parent: XMLElement?) -> XMLElement? {
        guard let parent else { return nil }
        return elements(named: name, in: parent).first
    }

    /// Text des ersten Kindelements mit diesem Namen ("" wenn keins).
    static func text(of name: String, in parent: XMLElement) -> String {
        elements(named: name, in: parent).first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Rekursive Suche in beliebiger Tiefe.
    static func descendants(named name: String, in parent: XMLElement?) -> [XMLElement] {
        guard let parent else { return [] }
        var result: [XMLElement] = []
        for child in (parent.children ?? []).compactMap({ $0 as? XMLElement }) {
            if localName(child) == name { result.append(child) }
            result.append(contentsOf: descendants(named: name, in: child))
        }
        return result
    }

    /// Attributwert über den lokalen Namen ("meta:page-count" → "page-count").
    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        (element.attributes ?? [])
            .first { localName($0) == name }?
            .stringValue
    }

    static func setAttribute(_ element: XMLElement, _ name: String, _ value: String) {
        if let existing = (element.attributes ?? []).first(where: { localName($0) == name }) {
            existing.stringValue = value
            return
        }
        let node = XMLNode(kind: .attribute)
        node.name = name
        node.stringValue = value
        element.addAttribute(node)
    }

    /// Präfix eines Namensraums, wie ihn das Wurzelelement deklariert. Fehlt
    /// die Deklaration, wird `preferred` am Wurzelelement nachgetragen — so
    /// bleibt ein neu angelegtes Element auch für strenge Leser gültig.
    static func prefix(for namespaceURI: String, preferred: String,
                       in root: XMLElement) -> String {
        if let existing = root.resolvePrefix(forNamespaceURI: namespaceURI),
           !existing.isEmpty {
            return existing
        }
        // Ein leeres Präfix hieße Standard-Namensraum; für die Metadaten-
        // Dateien hier deklarieren alle Erzeuger die Präfixe ausdrücklich.
        var prefix = preferred
        var suffix = 2
        while root.namespace(forPrefix: prefix) != nil {
            prefix = "\(preferred)\(suffix)"
            suffix += 1
        }
        if let namespace = XMLNode.namespace(withName: prefix, stringValue: namespaceURI) as? XMLNode {
            root.addNamespace(namespace)
        }
        return prefix
    }

    /// Neues Element `prefix:name` mit Text.
    static func element(_ name: String, prefix: String, value: String) -> XMLElement {
        let element = XMLElement(name: prefix.isEmpty ? name : "\(prefix):\(name)")
        element.stringValue = value
        return element
    }

    /// Setzt ein einwertiges Element: leerer Wert entfernt alle gleichnamigen,
    /// sonst wird das erste geändert (weitere bleiben) oder eines angelegt.
    /// `insert` bestimmt, wo ein neues Element landet (Standard: am Ende).
    static func setSingle(_ parent: XMLElement, _ name: String, prefix: String,
                          value: String, insert: ((XMLElement) -> Void)? = nil) {
        let existing = elements(named: name, in: parent)
        if value.isEmpty {
            existing.forEach { $0.detach() }
            return
        }
        if let first = existing.first {
            first.stringValue = value
            return
        }
        let created = element(name, prefix: prefix, value: value)
        if let insert { insert(created) } else { parent.addChild(created) }
    }

    /// Ersetzt alle Werte eines mehrwertigen Elements (z.B. meta:keyword).
    static func setList(_ parent: XMLElement, _ name: String, prefix: String,
                        values: [String]) {
        elements(named: name, in: parent).forEach { $0.detach() }
        for value in values where !value.isEmpty {
            parent.addChild(element(name, prefix: prefix, value: value))
        }
    }

    /// Parst XML-Daten; jeder Fehler gilt als „Datei nicht lesbar“.
    static func document(from data: Data, path: String) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data)
        } catch {
            throw TagError.cannotOpen(path: path)
        }
    }

    /// Serialisiert lesbar eingerückt; die Dateien sind klein, und Word,
    /// LibreOffice und Comic-Reader lesen Leerraum zwischen Elementen anstandslos.
    static func serialize(_ document: XMLDocument) -> Data {
        document.xmlData(options: .nodePrettyPrint)
    }
}

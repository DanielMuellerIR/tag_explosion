// XML-Helfer für Dokument-Backends. Namensräume werden über ihre URI
// verglichen, damit abweichende Präfixe funktionieren und gleichnamige
// Fremdfelder beim Schreiben erhalten bleiben.
//
// EpubFile nutzt eigene, auf OPF und Dublin Core begrenzte Auswahlhelfer.
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

    /// Direkte Kinder im angegebenen Namensraum, sonst im Namensraum des Elternknotens.
    static func elements(named name: String, in parent: XMLElement, namespaceURI: String? = nil) -> [XMLElement] {
        (parent.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { localName($0) == name && ($0.uri ?? "") == (namespaceURI ?? parent.uri ?? "") }
    }

    static func firstElement(named name: String, in parent: XMLElement?, namespaceURI: String? = nil) -> XMLElement? {
        guard let parent else { return nil }
        return elements(named: name, in: parent, namespaceURI: namespaceURI).first
    }

    /// Text des ersten Kindelements mit diesem Namen ("" wenn keins).
    static func text(of name: String, in parent: XMLElement, namespaceURI: String? = nil) -> String {
        elements(named: name, in: parent, namespaceURI: namespaceURI).first?.stringValue?
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

    /// Attributwert nach lokalem Namen und URI; ohne Angabe nur namespacefreie Attribute.
    static func attribute(_ element: XMLElement, _ name: String, namespaceURI: String = "") -> String? {
        (element.attributes ?? [])
            .first { localName($0) == name && ($0.uri ?? "") == namespaceURI }?
            .stringValue
    }

    static func setAttribute(_ element: XMLElement, _ name: String, _ value: String) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let uri = name.contains(":") ? element.resolveNamespace(forName: name)?.stringValue ?? "" : ""
        if let existing = (element.attributes ?? []).first(where: { localName($0) == local && ($0.uri ?? "") == uri }) {
            existing.stringValue = value
            return
        }
        let node = XMLNode(kind: .attribute)
        node.name = name
        node.stringValue = value
        element.addAttribute(node)
    }

    /// Präfix eines Namensraums im Gültigkeitsbereich des Knotens. Fehlt
    /// die Deklaration, wird `preferred` am Knoten nachgetragen — so
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
        let qualified = prefix.isEmpty ? name : "\(prefix):\(name)"
        let uri = parent.resolveNamespace(forName: qualified)?.stringValue ?? ""
        let existing = elements(named: name, in: parent, namespaceURI: uri)
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
        let qualified = prefix.isEmpty ? name : "\(prefix):\(name)"
        let uri = parent.resolveNamespace(forName: qualified)?.stringValue ?? ""
        elements(named: name, in: parent, namespaceURI: uri).forEach { $0.detach() }
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

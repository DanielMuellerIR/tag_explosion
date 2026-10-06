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
            .filter { localName($0) == name && namespace(of: $0) == (namespaceURI ?? namespace(of: parent)) }
    }

    // FoundationXML liefert unter Linux über .uri teils nur die erste
    // Namespace-Deklaration und erkennt neu angelegte präfigierte Knoten nicht.
    static func namespace(of element: XMLElement) -> String {
        element.resolveNamespace(forName: element.name ?? "")?.stringValue ?? ""
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

    /// Attributwert nach lokalem Namen und URI; ohne Angabe nur namespacefreie Attribute.
    static func attribute(_ element: XMLElement, _ name: String, namespaceURI: String = "") -> String? {
        (element.attributes ?? [])
            .first { localName($0) == name && attributeNamespace($0.name ?? "", in: element) == namespaceURI }?
            .stringValue
    }

    // XMLNode.uri stürzt bei Attributen unter Linux/Swift 6.0 in FoundationXML
    // ab. Präfixe stattdessen am besitzenden Element auflösen; der Standard-
    // namensraum gilt nicht für unpräfigierte Attribute.
    private static func attributeNamespace(_ name: String, in element: XMLElement) -> String {
        name.contains(":") ? element.resolveNamespace(forName: name)?.stringValue ?? "" : ""
    }

    static func removeAttribute(_ element: XMLElement, _ name: String, namespaceURI: String = "") {
        (element.attributes ?? []).filter {
            localName($0) == name && attributeNamespace($0.name ?? "", in: element) == namespaceURI
        }.forEach { $0.detach() }
    }

    static func setAttribute(_ element: XMLElement, _ name: String, _ value: String) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let uri = attributeNamespace(name, in: element)
        if let existing = (element.attributes ?? []).first(where: {
            localName($0) == local && attributeNamespace($0.name ?? "", in: element) == uri
        }) {
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
           !existing.isEmpty,
           root.resolveNamespace(forName: "\(existing):placeholder")?.stringValue == namespaceURI {
            return existing
        }
        // Ein leeres Präfix hieße Standard-Namensraum; für die Metadaten-
        // Dateien hier deklarieren alle Erzeuger die Präfixe ausdrücklich.
        var prefix = preferred
        var suffix = 2
        while root.resolveNamespace(forName: "\(prefix):placeholder") != nil {
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
            // FoundationXML repariert unter Linux einige Syntaxfehler still.
            // Vor einer Bearbeitung muss der strengere SAX-Parser zustimmen.
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            guard parser.parse(), parser.parserError == nil else { throw TagError.cannotOpen(path: path) }
            let document = try XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever)
            // Externe Deklarationen dürfen auch nicht beim späteren Schreiben
            // zu leeren Feldwerten werden, wenn ihr Inhalt nicht geladen wurde.
            #if os(Linux)
            // XMLDocument.dtd dereferenziert unter Swift 6.0/Linux auch dann
            // einen Zeiger, wenn die Datei überhaupt keine DTD enthält.
            let declarations = (document.children ?? []).compactMap { $0 as? XMLDTD }
            #else
            let declarations = document.dtd.map { [$0] } ?? []
            #endif
            for dtd in declarations {
                guard dtd.systemID == nil, dtd.publicID == nil,
                      !hasExternalDeclarations(dtd.xmlString) else {
                    throw TagError.cannotOpen(path: path)
                }
            }
            return document
        } catch {
            throw TagError.cannotOpen(path: path)
        }
    }

    // XMLDTDNode.isExternal stürzt unter Swift 6.0/Linux auch bei internen
    // Entities ab. Die Serialisierung ist portabel und liefert UTF-8-Text.
    // Literale und Kommentare zählen nicht als Deklarationen. Parameter-
    // Entities bleiben gesperrt, weil sie weitere Deklarationen erzeugen können.
    private static func hasExternalDeclarations(_ declaration: String) -> Bool {
        var unquoted = ""
        var cursor = declaration.startIndex
        while cursor < declaration.endIndex {
            if declaration[cursor...].hasPrefix("<!--") {
                guard let end = declaration[cursor...].range(of: "-->") else { return true }
                cursor = end.upperBound
                unquoted.append(" ")
            } else if declaration[cursor...].hasPrefix("<?") {
                guard let end = declaration[cursor...].range(of: "?>") else { return true }
                cursor = end.upperBound
                unquoted.append(" ")
            } else if declaration[cursor] == "\"" || declaration[cursor] == "'" {
                let quote = declaration[cursor]
                cursor = declaration.index(after: cursor)
                guard let end = declaration[cursor...].firstIndex(of: quote) else { return true }
                cursor = declaration.index(after: end)
                unquoted.append(" ")
            } else {
                unquoted.append(declaration[cursor])
                cursor = declaration.index(after: cursor)
            }
        }
        if unquoted.contains("%") { return true }
        let external = #"<!DOCTYPE\s+[^\s>\[]+\s+(?:SYSTEM|PUBLIC)\b|<!ENTITY\s+[^\s>]+\s+(?:SYSTEM|PUBLIC)\b"#
        return unquoted.range(of: external, options: .regularExpression) != nil
    }

    /// Serialisiert lesbar eingerückt; die Dateien sind klein, und Word,
    /// LibreOffice und Comic-Reader lesen Leerraum zwischen Elementen anstandslos.
    static func serialize(_ document: XMLDocument) -> Data {
        document.xmlData(options: .nodePrettyPrint)
    }
}

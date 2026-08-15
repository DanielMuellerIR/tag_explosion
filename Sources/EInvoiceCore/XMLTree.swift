// Leichter XML-Baum für E-Rechnungen. Baut auf Foundations XMLParser (SAX)
// auf und normalisiert Namensraum-Präfixe: Egal, welches Präfix ein Dokument
// deklariert, im Baum heißen die Elemente immer kanonisch (rsm/ram/udt/qdt
// für CII, ubl/cac/cbc für UBL). Nur so funktionieren die Pfad-Tabellen der
// BT-Zuordnung dokumentunabhängig.
import Foundation
#if canImport(FoundationXML)
import FoundationXML // Linux: XMLParser liegt in einem eigenen Modul
#endif

/// Ein Attribut in Dokumentreihenfolge (Dictionary würde die Ordnung verlieren).
public struct XMLTreeAttribute: Sendable, Codable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Ein Element des Baums. `name` trägt das kanonische Präfix (z.B. "ram:ID").
public struct XMLTreeNode: Sendable {
    public var name: String
    /// Voller Namensraum-URI des Elements (für gezielte Suchen, z.B. XMP).
    public var namespaceURI: String
    public var attributes: [XMLTreeAttribute]
    /// Getrimmter Textinhalt (leer bei reinen Gruppen-Elementen).
    public var text: String
    public var children: [XMLTreeNode]
    /// An DIESEM Element deklarierte Namensräume (Präfix → URI). Nötig, um
    /// Attribut-Präfixe aufzulösen: XMLParser liefert Attribute nur mit ihrem
    /// qualifizierten Namen, nicht mit ihrem Namensraum.
    public var namespaceDeclarations: [String: String] = [:]
}

public enum XMLTreeError: Error, LocalizedError {
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let detail): return "XML nicht lesbar: \(detail)"
        }
    }
}

public enum XMLTree {

    /// Bekannte Namensräume → kanonisches Präfix. Vergleich über Präfix-Muster
    /// statt exakter Strings, damit Versionssuffixe (…:100, …:12, …:15) und
    /// künftige Revisionen nicht jedes Mal neue Einträge erzwingen.
    static func canonicalPrefix(for namespaceURI: String, qualifiedName: String?) -> String? {
        let uri = namespaceURI
        // UN/CEFACT CII (ZUGFeRD 2.x, Factur-X, XRechnung-CII)
        if uri.contains(":CrossIndustryInvoice:") { return "rsm" }
        // ZUGFeRD 1.0 (Vorgänger-Schema, eigener Wurzel-Namensraum)
        if uri.hasPrefix("urn:ferd:CrossIndustryDocument") { return "rsm" }
        if uri.contains(":ReusableAggregateBusinessInformationEntity:") { return "ram" }
        if uri.contains(":UnqualifiedDataType:") { return "udt" }
        if uri.contains(":QualifiedDataType:") { return "qdt" }
        // OASIS UBL (XRechnung-UBL, Peppol BIS)
        if uri.hasPrefix("urn:oasis:names:specification:ubl:schema:xsd:") {
            if uri.contains("CommonAggregateComponents") { return "cac" }
            if uri.contains("CommonBasicComponents") { return "cbc" }
            if uri.contains("CommonExtensionComponents") { return "ext" }
            // Wurzeldokumente (Invoice-2, CreditNote-2, …) einheitlich "ubl"
            return "ubl"
        }
        if uri == "http://www.w3.org/2001/XMLSchema-instance" { return "xsi" }
        // Unbekannter Namensraum: Dokument-Präfix aus dem qualifizierten Namen
        // übernehmen, damit die Anzeige dem Original entspricht.
        if let qualifiedName, let colon = qualifiedName.firstIndex(of: ":") {
            return String(qualifiedName[..<colon])
        }
        return nil
    }

    /// Parst `data` zu einem Baum. Wirft bei Syntaxfehlern.
    public static func parse(_ data: Data) throws -> XMLTreeNode {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        // Präfix-Deklarationen mitschneiden (didStartMappingPrefix), damit
        // Attribut-Namensräume auflösbar sind — Attribute kommen vom Parser
        // nur mit qualifiziertem Namen.
        parser.shouldReportNamespacePrefixes = true
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription
                ?? builder.abortReason ?? "unbekannter Parserfehler"
            throw XMLTreeError.parseFailed(reason)
        }
        return root
    }

    /// XML-Schema-Boolean lesen: erlaubt sind "true"/"1" und "false"/"0"
    /// (xs:boolean). Alles andere ist nil — Aufrufer entscheiden dann bewusst,
    /// statt einen unbekannten Wert still als false zu behandeln.
    public static func booleanText(_ text: String?) -> Bool? {
        switch text?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    /// Kind-Element entlang eines Pfads aus kanonischen Namen suchen
    /// (erstes Vorkommen je Ebene).
    public static func firstNode(in root: XMLTreeNode, path: [String]) -> XMLTreeNode? {
        var current = root
        for name in path {
            guard let next = current.children.first(where: { $0.name == name }) else {
                return nil
            }
            current = next
        }
        return current
    }
}

/// SAX-Delegate: baut den Baum über einen Elternstapel auf.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    var abortReason: String?
    private var stack: [XMLTreeNode] = []
    private var textBuffer = ""
    /// Zwischen didStartMappingPrefix und didStartElement gesammelte
    /// Deklarationen — sie gehören zum als Nächstes startenden Element.
    private var pendingNamespaces: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String,
                toURI namespaceURI: String) {
        pendingNamespaces[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        // Text, der VOR einem Kind-Element stand (gemischter Inhalt), gehört
        // zum Elternelement — bei E-Rechnungen praktisch nur Einrückungs-
        // Whitespace, der beim Trimmen verschwindet.
        flushText()
        let prefix = XMLTree.canonicalPrefix(for: namespaceURI ?? "", qualifiedName: qName)
        let name = prefix.map { "\($0):\(elementName)" } ?? elementName
        // xmlns-Deklarationen tauchen mit shouldProcessNamespaces nicht als
        // Attribute auf; alles Übrige (unitCode, currencyID, schemeID, format,
        // mimeCode, …) bleibt erhalten. XMLParser liefert Attribute als
        // ungeordnetes Dictionary — alphabetisch sortiert ist die Ausgabe
        // wenigstens deterministisch.
        let attributes = attributeDict
            .sorted { $0.key < $1.key }
            .map { XMLTreeAttribute(name: $0.key, value: $0.value) }
        stack.append(XMLTreeNode(name: name, namespaceURI: namespaceURI ?? "",
                                 attributes: attributes, text: "", children: [],
                                 namespaceDeclarations: pendingNamespaces))
        pendingNamespaces = [:]
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        textBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        flushText()
        guard let finished = stack.popLast() else {
            abortReason = "Elementstapel leer bei </\(elementName)>"
            parser.abortParsing()
            return
        }
        if var parent = stack.popLast() {
            parent.children.append(finished)
            stack.append(parent)
        } else {
            root = finished
        }
    }

    private func flushText() {
        let trimmed = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        guard !trimmed.isEmpty, var current = stack.popLast() else { return }
        // Mehrere Textstücke (durch Kind-Elemente oder CDATA getrennt) werden
        // mit Leerzeichen verbunden — Werte gehen nie verloren.
        current.text = current.text.isEmpty ? trimmed : current.text + " " + trimmed
        stack.append(current)
    }
}

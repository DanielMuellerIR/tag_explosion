// Einstiegspunkt des E-Rechnungs-Lesers: erkennt Syntax und Profil, läuft
// den kompletten XML-Baum ab und ordnet jedem Element — wo möglich — seine
// EN-16931-Feldbezeichnung zu. Ungemappte Elemente bleiben mit Rohpfad
// sichtbar: Die Anzeige verliert nie Inhalte, auch nicht bei
// EXTENDED-Zusatzfeldern oder exotischen Profilen.
import Foundation
#if canImport(FoundationXML)
import FoundationXML // Linux: XMLParser liegt in einem eigenen Modul
#endif

public enum EInvoiceReader {

    /// Schneller Inhaltstest ohne Baumaufbau: Ist das eine E-Rechnung?
    /// XMLParser läuft nur bis zum ersten Start-Element und liefert dessen
    /// aufgelösten Namensraum. Dadurch dürfen Prolog und Kommentare beliebig
    /// lang sein, während gleichnamige Elemente in fremden Namensräumen nicht
    /// als Rechnung zählen.
    public static func sniffXML(_ data: Data) -> Bool {
        sniffXML(using: XMLParser(data: data))
    }

    /// Datei-Variante für Ordner-Scans: XMLParser liest den Stream nur bis zur
    /// Wurzel, statt die gesamte möglicherweise große Fremd-XML zu laden.
    public static func sniffXML(url: URL) -> Bool {
        guard let stream = InputStream(url: url) else { return false }
        defer { stream.close() }
        return sniffXML(using: XMLParser(stream: stream))
    }

    private static func sniffXML(using parser: XMLParser) -> Bool {
        let sniffer = InvoiceRootSniffer()
        parser.delegate = sniffer
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        _ = parser.parse() // Der Delegate bricht absichtlich an der Wurzel ab.
        guard let root = sniffer.root else { return false }
        switch (root.localName, root.namespaceURI) {
        case ("CrossIndustryInvoice", let uri)
            where uri.hasPrefix(
                "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:"):
            return true
        case ("CrossIndustryDocument", let uri)
            where uri.hasPrefix("urn:ferd:CrossIndustryDocument"):
            return true
        case ("Invoice", "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"):
            return true
        case ("CreditNote", "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"):
            return true
        default:
            return false
        }
    }

    /// Merkt nur das erste Start-Element und stoppt den Parser sofort. Das ist
    /// deutlich billiger als ein vollständiger XML-Baum, nutzt aber dieselbe
    /// standardkonforme Namensraumauflösung.
    private final class InvoiceRootSniffer: NSObject, XMLParserDelegate {
        var root: (localName: String, namespaceURI: String)?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            root = (elementName, namespaceURI ?? "")
            parser.abortParsing()
        }
    }

    /// Datei-Einstieg: XML direkt lesen, PDF über die eingebettete Datei.
    public static func read(url: URL) throws -> EInvoiceDocument {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try readPDF(url: url)
        default:
            let data = try Data(contentsOf: url)
            return try document(fromXML: data, source: .xmlFile)
        }
    }

    /// Gibt es in dieser Datei eine E-Rechnung? (Billiger Vorab-Test für
    /// UI-Entscheidungen; bei XML ohne Parsen, bei PDF via Extraktion.)
    public static func containsInvoice(url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "xml":
            return sniffXML(url: url)
        case "pdf":
            return (try? readPDF(url: url)) != nil
        default:
            return false
        }
    }

    /// PDF: eingebettetes Rechnungs-XML finden und lesen.
    static func readPDF(url: URL) throws -> EInvoiceDocument {
        #if canImport(CoreGraphics)
        let extraction = try PDFEmbeddedInvoice.extract(url: url)
        // Die XMP-Deklaration benennt die maßgebliche Rechnungsdatei und hat
        // deshalb Vorrang. Danach folgen standardisierte Namen; sonst bleibt
        // die Reihenfolge des PDF-Namensbaums bzw. AF-Arrays erhalten.
        let declaredName = extraction.declaration?.documentFileName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredNames = ["factur-x.xml", "zugferd-invoice.xml", "xrechnung.xml"]
        func candidateRank(_ name: String) -> Int {
            if let declaredName, !declaredName.isEmpty,
               declaredName.caseInsensitiveCompare(name) == .orderedSame {
                return 0
            }
            if let index = preferredNames.firstIndex(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return index + 1
            }
            return preferredNames.count + 1
        }
        let candidates = extraction.files.enumerated().sorted { a, b in
            let aRank = candidateRank(a.element.name)
            let bRank = candidateRank(b.element.name)
            return aRank == bRank ? a.offset < b.offset : aRank < bRank
        }.map(\.element)
        for candidate in candidates where sniffXML(candidate.data) {
            var doc = try document(fromXML: candidate.data,
                                   source: .pdfEmbedded(fileName: candidate.name))
            if let declaration = extraction.declaration, !declaration.isEmpty {
                doc.pdfDeclaration = declaration
            }
            return doc
        }
        throw EInvoiceError.notAnInvoice
        #else
        // Linux-Build: PDF-Extraktion braucht CoreGraphics. XML-Rechnungen
        // funktionieren überall; für PDFs ist das hier ehrlich ein Fehler.
        throw EInvoiceError.pdfUnreadable(url.path)
        #endif
    }

    /// XML-Daten zu einem vollständigen Dokument verarbeiten.
    public static func document(fromXML data: Data,
                                source: EInvoiceSource) throws -> EInvoiceDocument {
        guard sniffXML(data) else { throw EInvoiceError.notAnInvoice }
        let root: XMLTreeNode
        do {
            root = try XMLTree.parse(data)
        } catch {
            throw EInvoiceError.xmlUnreadable(String(describing: error))
        }

        let syntax: EInvoiceSyntax
        switch root.name {
        case "rsm:CrossIndustryInvoice": syntax = .cii
        case "rsm:CrossIndustryDocument": syntax = .ciiZUGFeRD1
        case "ubl:Invoice": syntax = .ublInvoice
        case "ubl:CreditNote": syntax = .ublCreditNote
        default: throw EInvoiceError.notAnInvoice
        }

        let profile = extractProfile(root: root, syntax: syntax)
        let invoiceCurrency = extractCurrency(root: root, syntax: syntax)

        var fields: [EInvoiceField] = []
        walk(node: root, path: root.name, level: 0, ancestors: [], syntax: syntax,
             invoiceCurrency: invoiceCurrency, into: &fields)

        return EInvoiceDocument(
            source: source, syntax: syntax, profile: profile,
            pdfDeclaration: nil, fields: fields,
            summary: buildSummary(fields: fields))
    }

    // MARK: - Baum-Durchlauf

    private static func walk(node: XMLTreeNode, path: String, level: Int,
                             ancestors: [XMLTreeNode], syntax: EInvoiceSyntax,
                             invoiceCurrency: String?,
                             into fields: inout [EInvoiceField]) {
        let term: String?
        switch syntax {
        case .cii:
            term = CIIMapping.term(path: path, node: node, ancestors: ancestors,
                                   invoiceCurrency: invoiceCurrency)
        case .ublInvoice, .ublCreditNote:
            term = UBLMapping.term(path: path, node: node, ancestors: ancestors,
                                   invoiceCurrency: invoiceCurrency)
        case .ciiZUGFeRD1:
            // ZUGFeRD 1.0 stammt aus der Zeit vor EN 16931 — eine BT-Zuordnung
            // wäre bestenfalls sinngemäß und damit potenziell falsch.
            term = nil
        }

        let formatAttribute = node.attributes.first { $0.name == "format" }?.value
        let unitAttribute = node.attributes.first { $0.name == "unitCode" }?.value
        let valueNote = CodeLists.note(term: term, value: node.text)
            ?? CodeLists.isoDateNote(value: node.text, formatAttribute: formatAttribute)
            // Mengen tragen ihre Einheit als Attribut (BT-130/BT-150) —
            // die Lesehilfe entschlüsselt den Einheiten-Code.
            ?? unitAttribute.flatMap { CodeLists.unitCode[$0] }

        // Manche Business Terms liegen als Attribut am Element (z.B. die
        // Maßeinheit einer Menge) — sie bekommen ihre eigene Zuordnung.
        let rawAttributeTerms: [(attribute: String, term: String)]
        switch syntax {
        case .cii:
            rawAttributeTerms = CIIMapping.attributeTerms(for: term, node: node)
        case .ublInvoice, .ublCreditNote:
            rawAttributeTerms = UBLMapping.attributeTerms(for: term, node: node)
        case .ciiZUGFeRD1:
            rawAttributeTerms = []
        }

        fields.append(EInvoiceField(
            level: level, element: node.name, path: path, value: node.text,
            attributes: node.attributes, term: term,
            termName: term.flatMap { EN16931.name(for: $0) },
            valueNote: valueNote,
            attributeTerms: rawAttributeTerms.map {
                EInvoiceAttributeTerm(attribute: $0.attribute, term: $0.term,
                                      termName: EN16931.name(for: $0.term))
            }))

        for child in node.children {
            walk(node: child, path: "\(path)/\(child.name)", level: level + 1,
                 ancestors: ancestors + [node], syntax: syntax,
                 invoiceCurrency: invoiceCurrency, into: &fields)
        }
    }

    // MARK: - Profil und Kontext

    private static func extractProfile(root: XMLTreeNode,
                                       syntax: EInvoiceSyntax) -> EInvoiceProfile {
        let guideline: String?
        let process: String?
        switch syntax {
        case .cii:
            let ctx = ["rsm:ExchangedDocumentContext",
                       "ram:GuidelineSpecifiedDocumentContextParameter", "ram:ID"]
            guideline = XMLTree.firstNode(in: root, path: ctx)?.text
            process = XMLTree.firstNode(in: root, path:
                ["rsm:ExchangedDocumentContext",
                 "ram:BusinessProcessSpecifiedDocumentContextParameter", "ram:ID"])?.text
        case .ciiZUGFeRD1:
            guideline = XMLTree.firstNode(in: root, path:
                ["rsm:SpecifiedExchangedDocumentContext",
                 "ram:GuidelineSpecifiedDocumentContextParameter", "ram:ID"])?.text
            process = nil
        case .ublInvoice, .ublCreditNote:
            guideline = XMLTree.firstNode(in: root, path: ["cbc:CustomizationID"])?.text
            process = XMLTree.firstNode(in: root, path: ["cbc:ProfileID"])?.text
        }
        return EInvoiceProfile.resolve(guidelineID: guideline ?? "",
                                       businessProcessID: process?.isEmpty == false ? process : nil,
                                       syntax: syntax)
    }

    private static func extractCurrency(root: XMLTreeNode,
                                        syntax: EInvoiceSyntax) -> String? {
        switch syntax {
        case .cii:
            return XMLTree.firstNode(in: root, path:
                ["rsm:SupplyChainTradeTransaction", "ram:ApplicableHeaderTradeSettlement",
                 "ram:InvoiceCurrencyCode"])?.text
        case .ciiZUGFeRD1:
            return XMLTree.firstNode(in: root, path:
                ["rsm:SpecifiedSupplyChainTradeTransaction",
                 "ram:ApplicableSupplyChainTradeSettlement",
                 "ram:InvoiceCurrencyCode"])?.text
        case .ublInvoice, .ublCreditNote:
            return XMLTree.firstNode(in: root, path: ["cbc:DocumentCurrencyCode"])?.text
        }
    }

    private static func buildSummary(fields: [EInvoiceField]) -> EInvoiceSummary {
        func first(_ term: String) -> EInvoiceField? {
            fields.first { $0.term == term && !$0.value.isEmpty }
        }
        let issue = first("BT-2")
        return EInvoiceSummary(
            invoiceNumber: first("BT-1")?.value,
            // Lesehilfe bevorzugen: Bei CII steht dort das ISO-Datum.
            issueDate: issue.map { $0.valueNote ?? $0.value },
            sellerName: first("BT-27")?.value,
            buyerName: first("BT-44")?.value,
            currency: first("BT-5")?.value,
            payableAmount: first("BT-115")?.value)
    }
}

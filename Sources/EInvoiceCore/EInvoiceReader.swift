// Einstiegspunkt des E-Rechnungs-Lesers: erkennt Syntax und Profil, läuft
// den kompletten XML-Baum ab und ordnet jedem Element — wo möglich — seine
// EN-16931-Feldbezeichnung zu. Ungemappte Elemente bleiben mit Rohpfad
// sichtbar: Die Anzeige verliert nie Inhalte, auch nicht bei
// EXTENDED-Zusatzfeldern oder exotischen Profilen.
import Foundation

public enum EInvoiceReader {

    /// Schneller Inhaltstest ohne vollständiges Parsen: Ist das eine
    /// E-Rechnung? Es genügt, den Anfang der Datei zu prüfen — das
    /// Wurzelelement mit seinen Namensraum-Deklarationen steht dort immer.
    /// Geprüft wird das ERSTE Start-Element (Prolog, Kommentare und DOCTYPE
    /// werden übersprungen) — ein bloßes "CrossIndustryInvoice" in einem
    /// Kommentar oder Textwert eines Fremd-XML zählt nicht als Treffer.
    public static func sniffXML(_ data: Data) -> Bool {
        guard let head = decodeHead(data) else { return false }
        guard let rootName = firstStartElementName(in: head) else { return false }
        let local = rootName.components(separatedBy: ":").last ?? rootName
        switch local {
        case "CrossIndustryInvoice": return true                       // CII
        case "CrossIndustryDocument": return true                      // ZUGFeRD 1.0
        case "Invoice":
            return head.contains("urn:oasis:names:specification:ubl:schema:xsd:Invoice-2")
        case "CreditNote":
            return head.contains("urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2")
        default: return false
        }
    }

    /// Dateianfang als Text — UTF-8 und (per BOM oder Nullbyte-Muster
    /// erkanntes) UTF-16 werden unterstützt. Ein angeschnittenes letztes
    /// Zeichen ist unkritisch: Der Inhaltstest braucht nur den Anfang.
    private static func decodeHead(_ data: Data) -> String? {
        var head = data.prefix(8192)
        // UTF-16 (mit BOM oder am Nullbyte im ersten Zeichen erkennbar):
        // XML beginnt mit "<" oder Whitespace, also liegt in einem der ersten
        // beiden Bytes einer UTF-16-Datei immer ein Nullbyte.
        let bytes = [UInt8](head.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF]
            || bytes.first == 0x00 || (bytes.count == 2 && bytes[1] == 0x00) {
            if head.count % 2 != 0 { head = head.dropLast() }  // halbe Code-Unit
            let bigEndian = bytes == [0xFE, 0xFF] || bytes.first == 0x00
            return String(data: head, encoding: bigEndian ? .utf16BigEndian : .utf16LittleEndian)
        }
        return String(decoding: head, as: UTF8.self)
    }

    /// Name des ersten Start-Elements; Prolog (`<?…?>`), Kommentare
    /// (`<!--…-->`) und DOCTYPE (`<!…>`) davor werden übersprungen.
    private static func firstStartElementName(in head: String) -> String? {
        var rest = Substring(head)
        while let lt = rest.firstIndex(of: "<") {
            let afterLT = rest.index(after: lt)
            guard afterLT < rest.endIndex else { return nil }
            switch rest[afterLT] {
            case "?":  // XML-Deklaration / Processing Instruction
                guard let end = rest.range(of: "?>", range: afterLT..<rest.endIndex)
                else { return nil }
                rest = rest[end.upperBound...]
            case "!":  // Kommentar oder DOCTYPE — Kommentare können ">" enthalten
                if rest[afterLT...].hasPrefix("!--") {
                    guard let end = rest.range(of: "-->", range: afterLT..<rest.endIndex)
                    else { return nil }
                    rest = rest[end.upperBound...]
                } else {
                    guard let end = rest[afterLT...].firstIndex(of: ">") else { return nil }
                    rest = rest[rest.index(after: end)...]
                }
            case "/":  // schließendes Tag vor jedem Start-Element: kaputtes XML
                return nil
            default:   // Start-Element: Name endet an Whitespace, "/" oder ">"
                let name = rest[afterLT...].prefix {
                    !$0.isWhitespace && $0 != "/" && $0 != ">"
                }
                return name.isEmpty ? nil : String(name)
            }
        }
        return nil
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
            guard let data = try? Data(contentsOf: url) else { return false }
            return sniffXML(data)
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
        // Bevorzugt die standardisierten Dateinamen, sonst das erste
        // eingebettete XML, das der Inhaltstest als Rechnung erkennt.
        let preferredNames = ["factur-x.xml", "zugferd-invoice.xml",
                              "ZUGFeRD-invoice.xml", "xrechnung.xml"]
        let candidates = extraction.files.sorted { a, b in
            let ai = preferredNames.firstIndex { $0.caseInsensitiveCompare(a.name) == .orderedSame }
            let bi = preferredNames.firstIndex { $0.caseInsensitiveCompare(b.name) == .orderedSame }
            switch (ai, bi) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name < b.name
            }
        }
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

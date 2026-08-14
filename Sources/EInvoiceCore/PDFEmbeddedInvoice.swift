// Eingebettete Dateien und die Factur-X-/ZUGFeRD-Deklaration aus einem PDF
// lesen. Läuft über CoreGraphics (CGPDFDocument), also nur auf
// Apple-Plattformen — der einzige nicht Linux-portable Teil von EInvoiceCore,
// deshalb komplett in dieser Datei gekapselt.
//
// PDF-Struktur: Katalog → Names → EmbeddedFiles ist ein Namensbaum (direkt
// mit "Names" oder verschachtelt über "Kids"); jeder Eintrag ist ein
// Filespec-Dictionary mit "EF" → Stream. ZUGFeRD/Factur-X verlangen die
// Rechnung zusätzlich als "AF"-Array (Associated Files) im Katalog — beide
// Wege werden gelesen, doppelte Namen nur einmal übernommen.
#if canImport(CoreGraphics)
import Foundation
import CoreGraphics

enum PDFEmbeddedInvoice {

    struct EmbeddedFile {
        var name: String
        var data: Data
    }

    struct Extraction {
        var files: [EmbeddedFile]
        var declaration: EInvoicePDFDeclaration?
    }

    static func extract(url: URL) throws -> Extraction {
        guard let document = CGPDFDocument(url as CFURL),
              let catalog = document.catalog else {
            throw EInvoiceError.pdfUnreadable(url.path)
        }

        var files: [EmbeddedFile] = []
        var seenNames = Set<String>()

        func add(name: String, data: Data) {
            guard seenNames.insert(name).inserted else { return }
            files.append(EmbeddedFile(name: name, data: data))
        }

        // Weg 1: Namensbaum Names → EmbeddedFiles
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var embedded: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded {
                walkNameTree(embedded, depth: 0) { name, filespec in
                    if let file = readFilespec(filespec, fallbackName: name) {
                        add(name: file.name, data: file.data)
                    }
                }
            }
        }

        // Weg 2: AF-Array (Associated Files) im Katalog
        var af: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(catalog, "AF", &af), let af {
            for i in 0..<CGPDFArrayGetCount(af) {
                var filespec: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(af, i, &filespec), let filespec,
                   let file = readFilespec(filespec, fallbackName: nil) {
                    add(name: file.name, data: file.data)
                }
            }
        }

        return Extraction(files: files, declaration: readDeclaration(catalog: catalog))
    }

    // MARK: - Namensbaum

    /// Namensbaum rekursiv ablaufen. `depth` begrenzt die Rekursion — ein
    /// zyklischer Baum in einer kaputten Datei darf die App nicht aufhängen.
    private static func walkNameTree(_ node: CGPDFDictionaryRef, depth: Int,
                                     visit: (String?, CGPDFDictionaryRef) -> Void) {
        guard depth < 32 else { return }

        var names: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &names), let names {
            // Flaches Array: [Name1, Filespec1, Name2, Filespec2, …]
            let count = CGPDFArrayGetCount(names)
            var i = 0
            while i + 1 < count {
                var nameRef: CGPDFStringRef?
                var filespec: CGPDFDictionaryRef?
                let name = CGPDFArrayGetString(names, i, &nameRef)
                    ? nameRef.flatMap(pdfString) : nil
                if CGPDFArrayGetDictionary(names, i + 1, &filespec), let filespec {
                    visit(name, filespec)
                }
                i += 2
            }
        }

        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for i in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, i, &kid), let kid {
                    walkNameTree(kid, depth: depth + 1, visit: visit)
                }
            }
        }
    }

    /// Filespec-Dictionary → Name + entpackte Daten. "UF" (Unicode) hat
    /// Vorrang vor "F"; der Stream liegt unter EF/UF bzw. EF/F.
    private static func readFilespec(_ filespec: CGPDFDictionaryRef,
                                     fallbackName: String?) -> EmbeddedFile? {
        var name = fallbackName
        var nameRef: CGPDFStringRef?
        if CGPDFDictionaryGetString(filespec, "UF", &nameRef), let nameRef,
           let s = pdfString(nameRef) {
            name = s
        } else if CGPDFDictionaryGetString(filespec, "F", &nameRef), let nameRef,
                  let s = pdfString(nameRef) {
            name = s
        }

        var ef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(filespec, "EF", &ef), let ef else { return nil }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(ef, "UF", &stream) {
            _ = CGPDFDictionaryGetStream(ef, "F", &stream)
        }
        guard let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        return EmbeddedFile(name: name ?? "eingebettete-datei",
                            data: cfData as Data)
    }

    private static func pdfString(_ ref: CGPDFStringRef) -> String? {
        CGPDFStringCopyTextString(ref) as String?
    }

    // MARK: - XMP-Deklaration

    /// Factur-X-/ZUGFeRD-Deklaration aus dem XMP-Metadatenstrom des Katalogs.
    /// Erkennung über den Namensraum (…pdfa:CrossIndustryDocument…), nicht
    /// über das Präfix — das darf ein Erzeuger frei wählen.
    private static func readDeclaration(catalog: CGPDFDictionaryRef) -> EInvoicePDFDeclaration? {
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else {
            return nil
        }
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        guard let xmp = try? XMLTree.parse(cfData as Data) else { return nil }

        var declaration = EInvoicePDFDeclaration()
        collectDeclaration(node: xmp, into: &declaration)
        return declaration.isEmpty ? nil : declaration
    }

    private static func collectDeclaration(node: XMLTreeNode,
                                           into declaration: inout EInvoicePDFDeclaration) {
        let isInvoiceNamespace = node.namespaceURI.contains("pdfa:CrossIndustryDocument")
        if isInvoiceNamespace {
            let local = node.name.components(separatedBy: ":").last ?? node.name
            apply(local: local, value: node.text, to: &declaration)
        }
        // Kurzform: Werte als Attribute an rdf:Description. Attribut-
        // Namensräume sind hier nicht auflösbar (XMLParser liefert nur den
        // qualifizierten Namen), deshalb nur die konventionellen Präfixe der
        // Rechnungs-Schemata akzeptieren — sonst könnte z.B. ein fremdes
        // "Version"-Attribut aus einem anderen XMP-Schema hineinrutschen.
        let knownPrefixes = ["fx:", "zf:", "zugferd:", "facturx:"]
        for attribute in node.attributes
        where knownPrefixes.contains(where: { attribute.name.hasPrefix($0) }) {
            let local = attribute.name.components(separatedBy: ":").last ?? attribute.name
            apply(local: local, value: attribute.value, to: &declaration)
        }
        for child in node.children {
            collectDeclaration(node: child, into: &declaration)
        }
    }

    private static func apply(local: String, value: String,
                              to declaration: inout EInvoicePDFDeclaration) {
        guard !value.isEmpty else { return }
        switch local {
        case "DocumentType": declaration.documentType = declaration.documentType ?? value
        case "DocumentFileName": declaration.documentFileName = declaration.documentFileName ?? value
        case "Version": declaration.version = declaration.version ?? value
        case "ConformanceLevel": declaration.conformanceLevel = declaration.conformanceLevel ?? value
        default: break
        }
    }
}
#endif

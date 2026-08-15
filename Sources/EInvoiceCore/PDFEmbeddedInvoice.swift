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

    /// Obergrenzen der Extraktion: Ein PDF mit vielen oder stark komprimierten
    /// großen Anhängen darf die App beim Öffnen weder blockieren noch wegen
    /// Speichermangels beenden. Eine echte Rechnungsdatei ist klein und liegt
    /// unter den ersten Anhängen — die Grenzen sind großzügig gewählt.
    static let maxEmbeddedFiles = 32
    static let maxTotalBytes = 64 * 1024 * 1024

    static func extract(url: URL) throws -> Extraction {
        guard let document = CGPDFDocument(url as CFURL),
              let catalog = document.catalog else {
            throw EInvoiceError.pdfUnreadable(url.path)
        }

        var files: [EmbeddedFile] = []
        var seenNames = Set<String>()
        var totalBytes = 0

        // Vorauswahl über den Filespec-Namen, BEVOR der Stream dekomprimiert
        // wird: Nur XML-Kandidaten (Endung .xml oder ohne Endung) kommen als
        // Rechnung infrage — andere Anhänge werden gar nicht erst entpackt.
        func add(_ filespec: CGPDFDictionaryRef, fallbackName: String?) {
            guard files.count < maxEmbeddedFiles, totalBytes < maxTotalBytes else { return }
            let name = filespecName(filespec) ?? fallbackName ?? "eingebettete-datei"
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext.isEmpty || ext == "xml" else { return }
            guard !seenNames.contains(name) else { return }
            guard let data = filespecData(filespec) else { return }
            guard totalBytes + data.count <= maxTotalBytes else { return }
            seenNames.insert(name)
            totalBytes += data.count
            files.append(EmbeddedFile(name: name, data: data))
        }

        // Weg 1: Namensbaum Names → EmbeddedFiles
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
            var embedded: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded {
                walkNameTree(embedded, depth: 0) { name, filespec in
                    add(filespec, fallbackName: name)
                }
            }
        }

        // Weg 2: AF-Array (Associated Files) im Katalog
        var af: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(catalog, "AF", &af), let af {
            for i in 0..<CGPDFArrayGetCount(af) {
                var filespec: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(af, i, &filespec), let filespec {
                    add(filespec, fallbackName: nil)
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

    /// Name aus dem Filespec-Dictionary; "UF" (Unicode) hat Vorrang vor "F".
    private static func filespecName(_ filespec: CGPDFDictionaryRef) -> String? {
        var nameRef: CGPDFStringRef?
        if CGPDFDictionaryGetString(filespec, "UF", &nameRef), let nameRef,
           let s = pdfString(nameRef) {
            return s
        }
        if CGPDFDictionaryGetString(filespec, "F", &nameRef), let nameRef,
           let s = pdfString(nameRef) {
            return s
        }
        return nil
    }

    /// Entpackte Daten aus dem Filespec; der Stream liegt unter EF/UF bzw.
    /// EF/F. Getrennt vom Namen, damit die Vorauswahl über den Namen laufen
    /// kann, OHNE den Stream zu dekomprimieren.
    private static func filespecData(_ filespec: CGPDFDictionaryRef) -> Data? {
        var ef: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(filespec, "EF", &ef), let ef else { return nil }
        var stream: CGPDFStreamRef?
        if !CGPDFDictionaryGetStream(ef, "UF", &stream) {
            _ = CGPDFDictionaryGetStream(ef, "F", &stream)
        }
        guard let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        return cfData as Data
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
                                           inheritedNamespaces: [String: String] = [:],
                                           into declaration: inout EInvoicePDFDeclaration) {
        // Präfix→URI-Bindungen dieses Teilbaums: geerbte plus die am Element
        // selbst deklarierten (innere Deklarationen überschreiben äußere).
        var namespaces = inheritedNamespaces
        for (prefix, uri) in node.namespaceDeclarations { namespaces[prefix] = uri }

        let isInvoiceNamespace = node.namespaceURI.contains("pdfa:CrossIndustryDocument")
        if isInvoiceNamespace {
            let local = node.name.components(separatedBy: ":").last ?? node.name
            apply(local: local, value: node.text, to: &declaration)
        }
        // Kurzform: Werte als Attribute an rdf:Description. Entscheidend ist
        // der aufgelöste Namensraum des Attributs, nicht sein Präfix — ein
        // Erzeuger darf das Präfix frei wählen, und umgekehrt darf ein
        // fremdes, zufällig "fx" genanntes Schema keine Deklaration vortäuschen.
        for attribute in node.attributes {
            guard let colon = attribute.name.firstIndex(of: ":") else { continue }
            let prefix = String(attribute.name[..<colon])
            guard let uri = namespaces[prefix],
                  uri.contains("pdfa:CrossIndustryDocument") else { continue }
            let local = String(attribute.name[attribute.name.index(after: colon)...])
            apply(local: local, value: attribute.value, to: &declaration)
        }
        for child in node.children {
            collectDeclaration(node: child, inheritedNamespaces: namespaces,
                               into: &declaration)
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

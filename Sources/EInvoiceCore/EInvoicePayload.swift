import Foundation

/// Unveränderte Quelldaten für Anzeige und technische Prüfung. Das
/// Anzeigemodell darf niemals zurück in ein vermeintliches Original-XML
/// serialisiert und anschließend als Rechnung geprüft werden.
public struct EInvoicePayload: Sendable {
    public let xml: Data
    public let source: EInvoiceSource
    public let pdfDeclaration: EInvoicePDFDeclaration?

    public init(xml: Data, source: EInvoiceSource = .xmlFile,
                pdfDeclaration: EInvoicePDFDeclaration? = nil) {
        self.xml = xml
        self.source = source
        self.pdfDeclaration = pdfDeclaration
    }

    public func document() throws -> EInvoiceDocument {
        var document = try EInvoiceReader.document(fromXML: xml, source: source)
        document.pdfDeclaration = pdfDeclaration
        return document
    }
}

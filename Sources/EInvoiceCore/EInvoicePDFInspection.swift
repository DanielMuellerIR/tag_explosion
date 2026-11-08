import Foundation

public struct EInvoicePDFInspection: Sendable {
    public struct Attachment: Sendable {
        public let fileName: String?
        public let unicodeFileName: String?
        public let relationship: String?
        public let mimeType: String?
        public let inAssociatedFiles: Bool
        public let inNameTree: Bool
        public let isInvoice: Bool
        public let syntax: EInvoiceSyntax?
        public let matchesSelectedXML: Bool
    }
    public let attachments: [Attachment]
    public let metadata: Data?
    public let complete: Bool
}

extension EInvoiceReader {
    /// Begrenzte Strukturprüfung desselben PDF-Schnappschusses wie die Anzeige.
    public static func inspectPDF(_ data: Data, selectedXML: Data) throws -> EInvoicePDFInspection {
        #if canImport(CoreGraphics) || os(Linux)
        return try PDFEmbeddedInvoice.inspect(data: data, selectedXML: selectedXML)
        #else
        throw EInvoiceError.pdfUnreadable("PDF-Inspektion steht auf dieser Plattform nicht zur Verfügung")
        #endif
    }
}

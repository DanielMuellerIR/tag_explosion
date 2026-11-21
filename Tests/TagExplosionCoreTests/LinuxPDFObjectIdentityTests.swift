#if os(Linux)
import CPDFShim
import Foundation
import TagExplosionTestSupport
import Testing
@testable import EInvoiceCore

@Suite("QPDF-Objektidentität")
struct LinuxPDFObjectIdentityTests {
    @Test("Direkte Objekte behalten ihre Identität, auch wenn ihre Werte übereinstimmen")
    func directAndIndirectObjects() throws {
        let pdf = InvoiceValidationFixtures.pdf(attachments: [
            (name: "invoice.xml", xml: Data(InvoiceValidationFixtures.ubl.utf8)),
        ])
        let document = try #require(InvoicePDFDocument(data: pdf))
        defer { withExtendedLifetime(document) {} }
        let handle = document.handle
        let catalog = tagx_pdf_root(handle)
        let associatedFiles = tagx_pdf_key(handle, catalog, "AF")
        let fileSpecInAF = tagx_pdf_item(handle, associatedFiles, 0)
        let names = tagx_pdf_key(handle, catalog, "Names")
        let embeddedFiles = tagx_pdf_key(handle, names, "EmbeddedFiles")
        let entries = tagx_pdf_key(handle, embeddedFiles, "Names")
        let fileSpecInNames = tagx_pdf_item(handle, entries, 1)

        try #require(fileSpecInAF != 0)
        #expect(fileSpecInAF == fileSpecInNames)
        #expect(associatedFiles == tagx_pdf_key(handle, catalog, "AF"))
        #expect(associatedFiles != entries)

        let fileName = tagx_pdf_key(handle, fileSpecInAF, "F")
        let entryName = tagx_pdf_item(handle, entries, 0)
        try #require(fileName != 0 && entryName != 0)
        #expect(fileName == tagx_pdf_key(handle, fileSpecInNames, "F"))
        #expect(fileName != entryName)
        #expect(tagx_pdf_text(handle, fileName).map { String(cString: $0) } == "invoice.xml")
        #expect(tagx_pdf_text(handle, entryName).map { String(cString: $0) } == "invoice.xml")

        let embedded = tagx_pdf_key(handle, fileSpecInNames, "EF")
        let stream = tagx_pdf_key(handle, embedded, "F")
        let streamDictionary = tagx_pdf_dictionary(handle, stream)
        try #require(streamDictionary != 0)
        #expect(streamDictionary == tagx_pdf_dictionary(handle, stream))
    }
}
#endif

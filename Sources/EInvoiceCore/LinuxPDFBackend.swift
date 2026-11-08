#if os(Linux)
import CPDFShim
import Foundation

// Kleine Objektadapter für denselben begrenzten PDF-Durchlauf wie auf macOS.
// Der Parser ist QPDF; die Auswahl- und Rechnungsregeln stehen nicht im Shim.
final class InvoicePDFDocument {
    let handle: UnsafeMutableRawPointer
    init?(data: Data) {
        guard let value = data.withUnsafeBytes({ tagx_pdf_open($0.bindMemory(to: UInt8.self).baseAddress, data.count) }) else { return nil }
        handle = value
    }
    deinit { tagx_pdf_close(handle) }
    var catalog: InvoicePDFNode? { node(tagx_pdf_root(handle)) }
    func node(_ id: UInt32) -> InvoicePDFNode? { id == 0 ? nil : InvoicePDFNode(document: self, id: id) }
}
struct InvoicePDFNode: Hashable {
    let document: InvoicePDFDocument
    let id: UInt32
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.document === rhs.document && lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(document)); hasher.combine(id) }
}
typealias CGPDFDictionaryRef = InvoicePDFNode
typealias CGPDFArrayRef = InvoicePDFNode
typealias CGPDFStringRef = InvoicePDFNode
typealias CGPDFStreamRef = InvoicePDFNode
typealias CGPDFInteger = Int64
enum CGPDFDataFormat { case raw }

private func key(_ node: InvoicePDFNode, _ name: String, type: Int32) -> InvoicePDFNode? {
    guard let value = node.document.node(tagx_pdf_key(node.document.handle, node.id, name)),
          tagx_pdf_type(node.document.handle, value.id) == type else { return nil }
    return value
}
func CGPDFDictionaryGetArray(_ node: InvoicePDFNode, _ name: String, _ value: inout InvoicePDFNode?) -> Bool { value = key(node, name, type: 4); return value != nil }
func CGPDFDictionaryGetDictionary(_ node: InvoicePDFNode, _ name: String, _ value: inout InvoicePDFNode?) -> Bool { value = key(node, name, type: 5); return value != nil }
func CGPDFDictionaryGetString(_ node: InvoicePDFNode, _ name: String, _ value: inout InvoicePDFNode?) -> Bool { value = key(node, name, type: 3); return value != nil }
func CGPDFDictionaryGetStream(_ node: InvoicePDFNode, _ name: String, _ value: inout InvoicePDFNode?) -> Bool { value = key(node, name, type: 6); return value != nil }
func CGPDFDictionaryGetInteger(_ node: InvoicePDFNode, _ name: String, _ value: inout Int64) -> Bool {
    guard let found = key(node, name, type: 1) else { return false }
    return tagx_pdf_integer(node.document.handle, found.id, &value) != 0
}
func CGPDFDictionaryGetName(_ node: InvoicePDFNode, _ name: String, _ value: inout UnsafePointer<CChar>?) -> Bool {
    guard let found = key(node, name, type: 2) else { return false }
    value = tagx_pdf_text(node.document.handle, found.id); return value != nil
}
func CGPDFArrayGetCount(_ node: InvoicePDFNode) -> Int { Int(tagx_pdf_count(node.document.handle, node.id)) }
private func arrayItem(_ node: InvoicePDFNode, _ index: Int, type: Int32) -> InvoicePDFNode? {
    guard index >= 0, let value = node.document.node(tagx_pdf_item(node.document.handle, node.id, index)),
          tagx_pdf_type(node.document.handle, value.id) == type else { return nil }
    return value
}
func CGPDFArrayGetDictionary(_ node: InvoicePDFNode, _ index: Int, _ value: inout InvoicePDFNode?) -> Bool { value = arrayItem(node, index, type: 5); return value != nil }
func CGPDFArrayGetString(_ node: InvoicePDFNode, _ index: Int, _ value: inout InvoicePDFNode?) -> Bool { value = arrayItem(node, index, type: 3); return value != nil }
func CGPDFStringCopyTextString(_ node: InvoicePDFNode) -> String? { tagx_pdf_text(node.document.handle, node.id).map { String(cString: $0) } }
func CGPDFStreamGetDictionary(_ node: InvoicePDFNode) -> InvoicePDFNode? { node.document.node(tagx_pdf_dictionary(node.document.handle, node.id)) }
func CGPDFStreamCopyData(_ node: InvoicePDFNode, _ format: inout CGPDFDataFormat) -> Data? {
    var bytes: UnsafeMutablePointer<UInt8>?
    var length = 0
    guard tagx_pdf_stream(node.document.handle, node.id, &bytes, &length) != 0, let bytes else { return nil }
    defer { tagx_pdf_free(bytes) }
    return Data(bytes: bytes, count: length)
}
#endif

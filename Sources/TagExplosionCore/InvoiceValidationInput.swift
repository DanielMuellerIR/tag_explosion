import EInvoiceCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InvoiceValidationSource: Codable, Sendable, Equatable {
    public let url: URL
    public let stamp: FileStamp
    public let fileSHA256: String
    public let xmlSHA256: String
    public let origin: EInvoiceSource

    /// Auch gleich große Änderungen mit zurückgesetzter Änderungszeit
    /// erkennen. Die Oberfläche prüft dies zusätzlich an ihrer Übergabegrenze.
    public func isCurrent(at url: URL) -> Bool {
        guard url.standardizedFileURL == self.url,
              FileStamp.current(of: url) == stamp,
              let bytes = try? InvoiceValidationInput.readBytes(at: url, limit: InvoiceValidationInput.limit(for: url)),
              validationDigest(bytes) == fileSHA256 else { return false }
        return FileStamp.current(of: url) == stamp
    }
}

public struct InvoiceValidationInput: Sendable {
    public static let maximumXMLBytes = 16 * 1024 * 1024
    public static let maximumPDFBytes = 64 * 1024 * 1024
    public let payload: EInvoicePayload
    public let source: InvoiceValidationSource

    public enum Failure: Error, LocalizedError {
        case notRegularFile, tooLarge, changed

        public var errorDescription: String? {
            switch self {
            case .notRegularFile: "Nur reguläre Dateien können geprüft werden."
            case .tooLarge: "Die Prüfung unterstützt XML bis 16 MiB und Träger-PDFs bis 64 MiB."
            case .changed: "Die Datei wurde seit dem Einlesen verändert. Bitte erneut prüfen."
            }
        }
    }

    public static func capture(at url: URL, cancellation: ExternalToolRunner.Cancellation? = nil) throws -> Self {
        try cancellation?.check()
        let url = url.standardizedFileURL
        let snapshot = try FileSnapshot.capture(at: url) {
            try readBytes(at: url, limit: limit(for: url), cancellation: cancellation)
        }
        let payload = url.pathExtension.lowercased() == "pdf"
            ? try EInvoiceReader.payload(fromPDF: snapshot.value)
            : EInvoicePayload(xml: snapshot.value)
        guard payload.xml.count <= maximumXMLBytes else { throw Failure.tooLarge }
        try XRechnungValidator.checkInput(payload.xml)
        try snapshot.requireCurrent(at: url)
        try cancellation?.check()
        return Self(payload: payload, source: .init(url: url, stamp: snapshot.stamp,
            fileSHA256: validationDigest(snapshot.value), xmlSHA256: validationDigest(payload.xml), origin: payload.source))
    }

    static func limit(for url: URL) -> Int {
        url.pathExtension.lowercased() == "pdf" ? maximumPDFBytes : maximumXMLBytes
    }

    static func readBytes(at url: URL, limit: Int,
                          cancellation: ExternalToolRunner.Cancellation? = nil) throws -> Data {
        // O_NONBLOCK verhindert ein Hängen auf FIFOs, auch wenn der Pfad
        // zwischen Vorprüfung und open ausgetauscht wird. fstat prüft den
        // tatsächlich geöffneten Deskriptor statt erneut den Dateinamen.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.notRegularFile }
        guard attributes.st_size <= limit else { throw Failure.tooLarge }
        var data = Data()
        while data.count <= limit {
            try cancellation?.check()
            let chunk = try handle.read(upToCount: min(1024 * 1024, limit + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw Failure.tooLarge }
        return data
    }
}

func validationDigest(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
    var hasher = PortableSHA256()
    hasher.update(data: data)
    return hasher.finalizeHex()
    #endif
}

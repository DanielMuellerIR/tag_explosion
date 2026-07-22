// Hilfsrahmen fuer dateibasierte Backends: Aenderungen entstehen an einer
// Geschwisterkopie und ersetzen das Original erst nach erfolgreicher Pruefung.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AtomicFileRewrite {
    static func run(
        url: URL,
        mutate: (URL) throws -> Void,
        validate: (URL) throws -> Void
    ) throws {
        let destination = MediaFormats.canonicalFileURL(url)
        let temp = siblingTempURL(for: destination)
        let fileManager = FileManager.default

        // Ein schreibgeschuetztes Original darf durch die beschreibbare
        // Verzeichnis-Kopie nicht unbemerkt doch veraendert werden.
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o222 == 0 {
            throw TagError.saveFailed(path: url.path)
        }

        do {
            try fileManager.copyItem(at: destination, to: temp)
            defer { try? fileManager.removeItem(at: temp) }
            try mutate(temp)
            try validate(temp)

            // Beide Pfade liegen im selben Verzeichnis. POSIX rename ersetzt
            // das Ziel in genau einem atomaren Dateisystem-Schritt.
            guard rename(temp.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
    }

    private static func siblingTempURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var name = ".\(stem).tagx-\(UUID().uuidString)"
        if !ext.isEmpty { name += ".\(ext)" }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}

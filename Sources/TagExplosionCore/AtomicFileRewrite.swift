// Hilfsrahmen fuer dateibasierte Backends: Aenderungen entstehen an einer
// Geschwisterkopie und ersetzen das Original erst nach erfolgreicher Pruefung.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AtomicFileRewrite {
    /// `expecting` traegt den beim Lesen erhobenen `FileStamp` bis unmittelbar
    /// vor den Austausch: Hat ein anderes Programm das Original waehrend
    /// Kopieren/Mutieren/Pruefen veraendert, wird abgebrochen statt dessen
    /// Aenderung per rename zu verwerfen. nil = keine Pruefung (Aufrufer ohne
    /// bekannten Ausgangsstand).
    static func run(
        url: URL,
        expecting stamp: FileStamp? = nil,
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

        // Die Kopie braucht Platz. Auf Dateisystemen mit Copy-on-Write (APFS)
        // kostet sie zunaechst nichts, sonst die volle Dateigroesse.
        try VolumeSpace.requireRoom(for: destination)

        do {
            try fileManager.copyItem(at: destination, to: temp)
        } catch {
            throw TagError.saveFailed(path: url.path)
        }
        defer { try? fileManager.removeItem(at: temp) }

        do {
            try mutate(temp)
            try validate(temp)
        } catch let error as TagError {
            // Den echten Grund erhalten — er unterscheidet ein nicht
            // unterstuetztes Feld von einem kaputten Schreibvorgang.
            throw error
        } catch {
            throw TagError.saveFailed(path: url.path)
        }

        // Letzte Kontrolle direkt vor dem Austausch: Die Kopie entstand aus dem
        // Stand von vor Mutation und Pruefung. Hat sich das Original seither
        // geaendert, wuerde rename genau diese fremde Aenderung ueberschreiben.
        try FileStamp.requireUnchanged(stamp, at: destination)

        // Beide Pfade liegen im selben Verzeichnis. POSIX rename ersetzt
        // das Ziel in genau einem atomaren Dateisystem-Schritt.
        guard rename(temp.path, destination.path) == 0 else {
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

/// Platzpruefung vor jeder Kopie. Ohne sie endet ein voller Datentraeger
/// mitten im Schreibvorgang — genau der Fall, den der atomare Rahmen
/// verhindern soll.
enum VolumeSpace {

    /// Reserve fuer Dateisystem-Metadaten, damit die Kopie nicht am
    /// allerletzten Block scheitert.
    static let margin: Int64 = 8 * 1024 * 1024

    /// Wirft `notEnoughSpace`, wenn eine Kopie der Datei nicht mehr sicher
    /// auf ihren eigenen Datentraeger passt. Kann der Datentraeger klonen
    /// (APFS), belegt die Kopie anfangs keine zusaetzlichen Bloecke.
    static func requireRoom(for url: URL, extraFiles: [URL] = []) throws {
        let needed = try requiredBytes(for: [url] + extraFiles)
        guard needed > 0 else { return }
        guard let free = availableBytes(at: url) else { return }
        guard free >= needed + margin else {
            throw TagError.notEnoughSpace(path: url.path, needBytes: needed, freeBytes: free)
        }
    }

    /// Wie viele Bytes eine Kopie der Dateien tatsaechlich kostet.
    static func requiredBytes(for urls: [URL]) throws -> Int64 {
        guard let first = urls.first, !supportsCloning(at: first) else { return 0 }
        return urls.reduce(into: Int64(0)) { total, url in
            total += fileSize(of: url) ?? 0
        }
    }

    static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func availableBytes(at url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        guard let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        // "Important usage" ist ein APFS-Konzept (kennt purgeable Space).
        // Nicht-APFS-Volumes (HFS+, FAT, DMGs) melden hier 0, obwohl Platz
        // frei ist — 0 heisst deshalb "nicht unterstuetzt", nicht "voll",
        // sonst schluege JEDER Schreibvorgang auf solchen Datentraegern fehl.
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int64(important)
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    /// APFS klont Dateien blockweise (Copy-on-Write) — die Kopie kostet dann
    /// erst Platz, wenn sich eine der beiden Seiten aendert.
    static func supportsCloning(at url: URL) -> Bool {
        #if canImport(Darwin)
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        return values?.volumeSupportsFileCloning ?? false
        #else
        return false
        #endif
    }
}

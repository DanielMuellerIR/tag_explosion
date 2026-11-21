// Gemeinsamer ZIP-Unterbau der Dokument-Backends (Office/OOXML, OpenDocument,
// CBZ). Alle drei Formate sind ZIP-Container mit einer kleinen XML-Datei für
// die Metadaten. Gelesen wird ein einzelner Eintrag; geschrieben wird das
// Archiv komplett neu: Reihenfolge und Kompressionsart aller Einträge bleiben,
// nur die genannten Einträge bekommen neuen Inhalt.
//
// Warum neu aufbauen statt „Eintrag entfernen und anhängen“ (der EPUB-Weg in
// EpubFile)? OpenDocument verlangt den `mimetype`-Eintrag unkomprimiert an
// erster Stelle; ein Neuaufbau in Originalreihenfolge hält diese Regel ohne
// Sonderfall ein, und alle übrigen Einträge bleiben inhaltlich byte-identisch.
// EpubFile behält bewusst seinen eigenen, getesteten Weg.
import Foundation
import ZIPFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ZipContainer {
    static let metadataSizeLimit = 16 * 1024 * 1024
    static let artworkSizeLimit = 64 * 1024 * 1024

    /// Öffnet ein Archiv. Ein Lesefehler heißt „keine lesbare Datei“, ein
    /// Schreibfehler (z.B. schreibgeschützt) „nicht speicherbar“.
    static func open(url: URL, accessMode: Archive.AccessMode) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: accessMode)
        } catch {
            switch accessMode {
            case .read: throw TagError.cannotOpen(path: url.path)
            case .update, .create: throw TagError.saveFailed(path: url.path)
            }
        }
    }

    /// Die Grenze gilt auch für den tatsächlich entpackten Inhalt, nicht nur
    /// für die Größenangabe eines möglicherweise manipulierten ZIP-Headers.
    static func data(of entry: Entry, in archive: Archive,
                     maximumSize: Int = metadataSizeLimit) throws -> Data {
        guard entry.uncompressedSize <= maximumSize else {
            throw TagError.cannotOpen(path: archive.url.path)
        }
        var data = Data()
        try extract(entry, in: archive) { data.append($0) }
        return data
    }

    /// ZIPFoundation berechnet CRC32, vergleicht den Wert aber nicht selbst.
    /// Jeder gelesene Eintrag muss zur gespeicherten Prüfsumme passen — auch
    /// unveränderte Nutzdaten, die beim Neuaufbau eine neue Prüfsumme bekommen.
    private static func extract(_ entry: Entry, in archive: Archive,
                                consume: (Data) throws -> Void) throws {
        var remaining = entry.uncompressedSize
        let checksum = try archive.extract(entry, bufferSize: 256 * 1024) { chunk in
            // Die komprimierte Eingabelänge begrenzt die Ausgabe nicht.
            // Vor dem Puffern oder Schreiben jeden entpackten Block prüfen.
            let count = UInt64(chunk.count)
            guard count <= remaining else { throw TagError.cannotOpen(path: archive.url.path) }
            remaining -= count
            try consume(chunk)
        }
        guard remaining == 0, checksum == entry.checksum else {
            throw TagError.cannotOpen(path: archive.url.path)
        }
    }

    /// Inhalt des Eintrags unter `path`; nil, wenn es ihn nicht gibt.
    static func data(at path: String, in archive: Archive) throws -> Data? {
        guard let entry = archive[path] else { return nil }
        return try data(of: entry, in: archive)
    }

    /// Alle Einträge in Archivreihenfolge (Pfad + Kompressionsmerkmal). Für
    /// Tests und die Prüfung nach dem Schreiben.
    struct EntrySummary: Equatable {
        let path: String
        let isCompressed: Bool
    }

    static func entries(url: URL) throws -> [EntrySummary] {
        let archive = try open(url: url, accessMode: .read)
        return archive.map { EntrySummary(path: $0.path, isCompressed: $0.isCompressed) }
    }

    /// Baut das Archiv unter `url` neu auf. Einträge aus `replacements`
    /// bekommen den neuen Inhalt (an ihrer alten Position); Pfade, die es noch
    /// nicht gibt, werden am Ende angehängt (deflate-komprimiert). Alle
    /// anderen Einträge werden mit gleichem Inhalt, gleicher Kompressionsart,
    /// Änderungszeit und Rechten übernommen.
    ///
    /// Gedacht für die Geschwisterkopie aus `AtomicFileRewrite`: Das neue
    /// Archiv entsteht daneben und ersetzt die Kopie per `rename`. Der Aufrufer
    /// prüft das Ergebnis, bevor es das Original ersetzt.
    ///
    /// Große unveränderte Dateien werden blockweise über eine private
    /// Zwischendatei kopiert; kleine Einträge bleiben im Speicher.
    /// Erweiterungsfelder (z.B. Zeitstempel mit Zeitzone) gehen dabei verloren.
    static func rewrite(url: URL, replacing replacements: [String: Data]) throws {
        let workspace = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).zip-rebuild-\(UUID().uuidString)")
        // Das neue ZIP enthält schon vor der Metadatenübernahme private Daten.
        // Ein exklusiver Ordner schützt deshalb auch den gesamten Zwischenstand.
        guard mkdir(workspace.path, 0o700) == 0 else {
            throw AtomicFileRewrite.systemWriteError(at: url, code: errno)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }
        let content = workspace.appendingPathComponent("content.zip")
        let rebuilt = workspace.appendingPathComponent("replacement.zip")
        try build(from: url, to: content, replacing: replacements)
        // copyItem übernimmt wie AtomicFileRewrite die Außenrechte, ACLs und
        // erweiterten Attribute. Danach ändern wir nur die Bytes dieser Kopie;
        // eine neue Inode an ihrer Stelle würde die Metadaten wieder verlieren.
        try FileManager.default.copyItem(at: url, to: rebuilt)
        try replaceContents(of: rebuilt, from: content)
        // rename ist auf demselben Datenträger atomar; der alte Stand der
        // Kopie ist danach weg, das Original bleibt bis zum Ende von
        // AtomicFileRewrite unangetastet.
        guard rename(rebuilt.path, url.path) == 0 else {
            throw AtomicFileRewrite.systemWriteError(at: url, code: errno)
        }
    }

    private static func replaceContents(of target: URL, from source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        while let chunk = try readChunk(from: input, size: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
    }

    /// Foundation hält unter macOS sonst gelesene NSData-Blöcke bis zum
    /// nächsten äußeren Autorelease-Pool fest, auch innerhalb einer Schleife.
    private static func readChunk(from input: FileHandle, size: Int) throws -> Data? {
        #if canImport(Darwin)
        return try autoreleasepool { try input.read(upToCount: size) }
        #else
        return try input.read(upToCount: size)
        #endif
    }

    /// Eigene Funktion, damit das Zielarchiv (Dateihandle) sicher geschlossen
    /// ist, bevor `rewrite` es per rename an seinen Platz schiebt.
    private static func build(from sourceURL: URL, to targetURL: URL,
                              replacing replacements: [String: Data]) throws {
        let expectedEntries = try declaredEntryCount(at: sourceURL)
        let source = try open(url: sourceURL, accessMode: .read)
        let target = try open(url: targetURL, accessMode: .create)
        var pending = replacements
        var copiedEntries: UInt64 = 0
        for entry in source {
            copiedEntries += 1
            let path = entry.path
            if pending[path] == nil, entry.type == .file, entry.uncompressedSize > 1024 * 1024 {
                try copyLargeEntry(entry, from: source, to: target,
                    staging: targetURL.deletingLastPathComponent().appendingPathComponent("entry-content"))
                continue
            }
            let data: Data
            if let replacement = pending.removeValue(forKey: path) {
                data = replacement
            } else if entry.type == .directory {
                data = Data()
            } else {
                data = try self.data(of: entry, in: source)
            }
            try add(path: path, data: data, type: entry.type,
                    // Ein ersetzter Eintrag behält seine bisherige
                    // Kompressionsart — so bleibt ein unkomprimierter
                    // `mimetype` unkomprimiert.
                    compressed: entry.isCompressed,
                    attributes: entry.fileAttributes, to: target)
        }
        guard copiedEntries == expectedEntries else { throw TagError.cannotOpen(path: sourceURL.path) }
        // Neue Einträge in stabiler Reihenfolge anhängen.
        for path in pending.keys.sorted() {
            try add(path: path, data: pending[path]!, type: .file, compressed: true,
                    attributes: [:], to: target)
        }
    }

    // ZIPFoundation beendet die Iteration bei der deklarierten Anzahl oder
    // beim ersten nicht lesbaren Eintrag. Daher auch das tatsächliche Ende
    // der Verzeichnisliste prüfen (ZIP APPNOTE §§ 4.3.12–16).
    private static func declaredEntryCount(at url: URL) throws -> UInt64 {
        let archive = try FileHandle(forReadingFrom: url)
        defer { try? archive.close() }
        let length = try archive.seekToEnd()
        let endRecordSize = 22
        let locatorSize = 20
        let tailSize = Int(min(length, UInt64(endRecordSize + locatorSize + Int(UInt16.max))))
        let tailOffset = length - UInt64(tailSize)
        try archive.seek(toOffset: tailOffset)
        guard let tail = try archive.read(upToCount: tailSize), tail.count >= endRecordSize else {
            throw TagError.cannotOpen(path: url.path)
        }
        for end in stride(from: tail.count - endRecordSize, through: 0, by: -1) {
            guard number(UInt32.self, in: tail, at: end) == 0x06054b50,
                  Int(number(UInt16.self, in: tail, at: end + 20)) == tail.count - end - endRecordSize
            else { continue }
            let endOffset = tailOffset + UInt64(end)
            let entriesOnDisk = number(UInt16.self, in: tail, at: end + 8)
            let entries = number(UInt16.self, in: tail, at: end + 10)
            let disk = number(UInt16.self, in: tail, at: end + 4)
            let firstDisk = number(UInt16.self, in: tail, at: end + 6)
            let locator = end - locatorSize
            if locator >= 0, number(UInt32.self, in: tail, at: locator) == 0x07064b50 {
                let recordOffset = number(UInt64.self, in: tail, at: locator + 8)
                let locatorOffset = tailOffset + UInt64(locator)
                let zip64RecordSize = 56
                guard recordOffset <= locatorOffset, locatorOffset - recordOffset >= zip64RecordSize,
                      (disk == 0 || disk == .max), (firstDisk == 0 || firstDisk == .max),
                      number(UInt32.self, in: tail, at: locator + 4) == 0,
                      number(UInt32.self, in: tail, at: locator + 16) == 1 else {
                    throw TagError.cannotOpen(path: url.path)
                }
                try archive.seek(toOffset: recordOffset)
                guard let record = try archive.read(upToCount: zip64RecordSize), record.count == zip64RecordSize,
                      number(UInt32.self, in: record, at: 0) == 0x06064b50,
                      number(UInt64.self, in: record, at: 4) == locatorOffset - recordOffset - 12,
                      number(UInt64.self, in: record, at: 16) == 0 else {
                    throw TagError.cannotOpen(path: url.path)
                }
                let count = number(UInt64.self, in: record, at: 32)
                guard number(UInt64.self, in: record, at: 24) == count,
                      (entriesOnDisk == .max || UInt64(entriesOnDisk) == count),
                      (entries == .max || UInt64(entries) == count) else {
                    throw TagError.cannotOpen(path: url.path)
                }
                return try verifyDirectory(in: archive, url: url, count: count,
                    offset: number(UInt64.self, in: record, at: 48),
                    size: number(UInt64.self, in: record, at: 40), endsAt: recordOffset)
            }
            guard disk == 0, firstDisk == 0, entriesOnDisk == entries else {
                throw TagError.cannotOpen(path: url.path)
            }
            return try verifyDirectory(in: archive, url: url, count: UInt64(entries),
                offset: UInt64(number(UInt32.self, in: tail, at: end + 16)),
                size: UInt64(number(UInt32.self, in: tail, at: end + 12)), endsAt: endOffset)
        }
        throw TagError.cannotOpen(path: url.path)
    }

    private static func verifyDirectory(in archive: FileHandle, url: URL, count: UInt64,
                                        offset: UInt64, size: UInt64, endsAt end: UInt64) throws -> UInt64 {
        let headerSize = 46
        let invalid = TagError.cannotOpen(path: url.path)
        guard offset <= end, size <= end - offset, count <= size / UInt64(headerSize) else { throw invalid }
        let directoryEnd = offset + size
        var cursor = offset
        for _ in 0..<count {
            guard directoryEnd - cursor >= headerSize else { throw invalid }
            try archive.seek(toOffset: cursor)
            guard let header = try readChunk(from: archive, size: headerSize), header.count == headerSize,
                  number(UInt32.self, in: header, at: 0) == 0x02014b50,
                  number(UInt16.self, in: header, at: 34) == 0 else { throw invalid }
            let recordSize = UInt64(headerSize)
                + UInt64(number(UInt16.self, in: header, at: 28))
                + UInt64(number(UInt16.self, in: header, at: 30))
                + UInt64(number(UInt16.self, in: header, at: 32))
            guard recordSize <= directoryEnd - cursor else { throw invalid }
            cursor += recordSize
        }
        if cursor != end {
            // Die zentrale Signatur darf in der Verzeichnisgröße enthalten sein.
            let signatureSize = 6
            guard directoryEnd == cursor || directoryEnd == end, end - cursor >= signatureSize else {
                throw invalid
            }
            try archive.seek(toOffset: cursor)
            guard let signature = try readChunk(from: archive, size: signatureSize),
                  signature.count == signatureSize, number(UInt32.self, in: signature, at: 0) == 0x05054b50,
                  UInt64(number(UInt16.self, in: signature, at: 4)) == end - cursor - UInt64(signatureSize)
            else { throw invalid }
        }
        return count
    }

    private static func number<T: FixedWidthInteger>(_ type: T.Type, in bytes: Data, at position: Int) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: position, as: type)) }
    }

    /// ZIPFoundation stellt entpackte Daten als Push-Strom bereit, addEntry
    /// fordert sie dagegen blockweise an. Eine Datei verbindet beide APIs,
    /// ohne einen kompletten Medieninhalt im Arbeitsspeicher zu halten.
    private static func copyLargeEntry(_ entry: Entry, from source: Archive, to target: Archive,
                                       staging: URL) throws {
        guard let size = Int64(exactly: entry.uncompressedSize) else {
            throw TagError.cannotOpen(path: source.url.path)
        }
        // Nur ein großer Eintrag liegt gleichzeitig entpackt vor. Maßstab ist
        // der freie Platz nach den bisherigen Einträgen im Zielarchiv.
        try VolumeSpace.requireRoom(for: source.url, bytes: size)
        try Data().write(to: staging, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        try extract(entry, in: source) { try output.write(contentsOf: $0) }
        try output.close()
        let input = try FileHandle(forReadingFrom: staging)
        defer { try? input.close() }
        let attributes = entry.fileAttributes
        try target.addEntry(with: entry.path, type: entry.type, uncompressedSize: size,
            modificationDate: attributes[.modificationDate] as? Date ?? Date(),
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
            compressionMethod: entry.isCompressed ? .deflate : .none, bufferSize: 256 * 1024
        ) { position, requested in
            try input.seek(toOffset: UInt64(position))
            let chunk = try readChunk(from: input, size: requested) ?? Data()
            // Deflate darf zum Abschluss über das Dateiende hinaus anfragen.
            let expected = min(Int64(requested), max(0, size - position))
            guard Int64(chunk.count) == expected else { throw TagError.saveFailed(path: staging.path) }
            return chunk
        }
    }

    private static func add(path: String, data: Data, type: Entry.EntryType,
                            compressed: Bool, attributes: [FileAttributeKey: Any],
                            to archive: Archive) throws {
        let modified = attributes[.modificationDate] as? Date ?? Date()
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        try archive.addEntry(
            with: path, type: type, uncompressedSize: Int64(data.count),
            modificationDate: modified, permissions: permissions,
            compressionMethod: compressed ? .deflate : .none
        ) { position, size in
            data.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
}

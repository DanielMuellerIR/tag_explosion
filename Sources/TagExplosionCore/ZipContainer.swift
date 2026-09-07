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

    /// Vollständiger Inhalt eines Eintrags.
    static func data(of entry: Entry, in archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
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
    /// Grenze: Jeder Eintrag wird beim Kopieren einmal vollständig in den
    /// Speicher geladen (nacheinander, nicht alle zugleich). Erweiterungsfelder
    /// der Einträge (z.B. Zeitstempel mit Zeitzone) gehen dabei verloren.
    static func rewrite(url: URL, replacing replacements: [String: Data]) throws {
        let workspace = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).zip-rebuild-\(UUID().uuidString)")
        // Das neue ZIP enthält schon vor der Metadatenübernahme private Daten.
        // Ein exklusiver Ordner schützt deshalb auch den gesamten Zwischenstand.
        guard mkdir(workspace.path, 0o700) == 0 else {
            throw TagError.saveFailed(path: url.path)
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
            throw TagError.saveFailed(path: url.path)
        }
    }

    private static func replaceContents(of target: URL, from source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
    }

    /// Eigene Funktion, damit das Zielarchiv (Dateihandle) sicher geschlossen
    /// ist, bevor `rewrite` es per rename an seinen Platz schiebt.
    private static func build(from sourceURL: URL, to targetURL: URL,
                              replacing replacements: [String: Data]) throws {
        let source = try open(url: sourceURL, accessMode: .read)
        let target = try open(url: targetURL, accessMode: .create)
        var pending = replacements
        for entry in source {
            let path = entry.path
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
        // Neue Einträge in stabiler Reihenfolge anhängen.
        for path in pending.keys.sorted() {
            try add(path: path, data: pending[path]!, type: .file, compressed: true,
                    attributes: [:], to: target)
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

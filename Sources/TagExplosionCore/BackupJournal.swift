// Sicherungs-Journal: Welche Papierkorb-Kopie gehört zu welcher Originaldatei?
//
// Warum ein Journal? `TrashBackup` legt pro Sitzung und Datenträger EINEN
// Ordner im Papierkorb an und kopiert die Sicherungen direkt hinein
// (Unterordner = Name des Quellordners, Dubletten als "Name (2).ext"). Der
// exakte Ablageort ist nur im Moment der Sicherung bekannt: Der Papierkorb
// liegt je Datenträger woanders (`~/.Trash`, `/Volumes/X/.Trashes/<uid>`),
// gleichnamige Quellordner verschiedener Pfade teilen sich einen Unterordner-
// namen, und die Kopie trägt weder Zeitstempel noch Herkunftspfad im Namen.
// Vom Original zurück auf seine Sicherungen zu schließen, wäre deshalb Raten.
// Das Journal hält pro Sicherung fest: Originalpfad, Sicherungspfad, Zeit,
// Größe, Prüfsumme und Auslöser.
//
// Das Journal ist nur ein Index. Die Wahrheit sind die Kopien im Papierkorb:
// Ein Eintrag, dessen Kopie nicht mehr existiert (Papierkorb geleert), gilt
// als verfallen und wird beim Lesen ausgefiltert. Umgekehrt löscht das
// Journal NIE etwas aus dem Papierkorb.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Ein Eintrag im Sicherungs-Journal: eine Kopie im Papierkorb samt Herkunft.
public struct BackupJournalEntry: Codable, Sendable, Equatable, Identifiable {
    /// Eindeutige Kennung (UUID); stabil über Journal-Umbauten hinweg.
    public var id: String
    /// Kanonischer Pfad der Originaldatei (Symlinks aufgelöst).
    public var originalPath: String
    /// Pfad der Kopie im Papierkorb.
    public var backupPath: String
    /// Zeitpunkt der Sicherung.
    public var date: Date
    /// Größe der Kopie in Bytes.
    public var size: Int64
    /// SHA-256 der Kopie (hex, Kleinbuchstaben). nil, wenn die Datei größer als
    /// `BackupJournal.checksumSizeLimit` ist oder keine Hash-Bibliothek
    /// verfügbar war — dann prüft ein Restore nur die Größe.
    public var sha256: String?
    /// Auslöser der Sicherung (siehe `BackupReason`), frei erweiterbar.
    public var reason: String

    public init(id: String = UUID().uuidString, originalPath: String, backupPath: String,
                date: Date, size: Int64, sha256: String?, reason: String) {
        self.id = id
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.date = date
        self.size = size
        self.sha256 = sha256
        self.reason = reason
    }

    /// Existiert die Kopie noch im Papierkorb? Sonst ist der Eintrag verfallen.
    public var backupExists: Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }
}

/// Übliche Auslöser einer Sicherung. Bewusst Strings statt Enum: App und CLI
/// dürfen eigene Werte anfügen, ohne dass alte Journale unlesbar werden.
public enum BackupReason {
    /// Allgemeines Speichern (Standard, wenn der Aufrufer nichts angibt).
    public static let save = "save"
    public static let tags = "tags"
    public static let cover = "cover"
    public static let chapters = "chapters"
    public static let layers = "layers"
    public static let `import` = "import"
    public static let rename = "rename"
    public static let sidecar = "sidecar"
    public static let playlist = "playlist"
    /// Sicherung des Standes VOR einem Zurückspielen aus der Historie —
    /// so bleibt auch ein Undo selbst rückgängig machbar.
    public static let restore = "restore"
}

/// Das Journal als JSON-Datei. Mehrere Prozesse (App und CLI) schreiben
/// gleichzeitig hinein; deshalb läuft jedes Lesen-Anfügen-Schreiben unter
/// einer Dateisperre (`flock`) und der Austausch der Datei ist atomar
/// (Temp-Datei + rename).
public final class BackupJournal: @unchecked Sendable {

    /// Das Journal am Standardort — App und CLI teilen es sich.
    public static let standard = BackupJournal(url: defaultURL)

    /// Mehr Einträge behält das Journal nicht; die ältesten fliegen zuerst.
    public static let defaultMaxEntries = 5000

    /// Oberhalb dieser Größe wird keine Prüfsumme berechnet (das Hashen einer
    /// mehrere Gigabyte großen Videodatei würde jedes Speichern spürbar
    /// bremsen). Ein Restore prüft dann nur die Größe der Kopie.
    public static let checksumSizeLimit: Int64 = 512 * 1024 * 1024

    /// Dateiformat-Version des Journals.
    static let formatVersion = 1

    /// Speicherort der Journaldatei.
    public let url: URL
    /// Obergrenze dieses Journals (Tests setzen sie klein).
    public let maxEntries: Int

    private let lock = NSLock()

    public init(url: URL, maxEntries: Int = BackupJournal.defaultMaxEntries) {
        self.url = url
        self.maxEntries = maxEntries
    }

    /// Standardort: `TAGX_BACKUP_JOURNAL` (Umgebung, für Skripte und Tests),
    /// sonst unter macOS `~/Library/Application Support/TagExplosion/`, unter
    /// Linux das XDG-Datenverzeichnis (`$XDG_DATA_HOME` bzw. `~/.local/share`).
    public static var defaultURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["TAGX_BACKUP_JOURNAL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return defaultDirectory.appendingPathComponent("backup-journal.json")
    }

    private static var defaultDirectory: URL {
        let fileManager = FileManager.default
        #if os(macOS)
        if let support = try? fileManager.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask,
                                              appropriateFor: nil, create: false) {
            return support.appendingPathComponent("TagExplosion", isDirectory: true)
        }
        #endif
        let base = XDGTrash.defaultDataHome(environment: ProcessInfo.processInfo.environment)
        return base.appendingPathComponent("TagExplosion", isDirectory: true)
    }

    // MARK: - Lesen

    /// Alle Einträge, deren Kopie noch existiert — chronologisch, älteste zuerst.
    /// Verfallene Einträge bleiben in der Datei stehen, bis `prune` sie
    /// entfernt; nur die Anzeige filtert sie.
    public func liveEntries() -> [BackupJournalEntry] {
        rawEntries().filter(\.backupExists)
    }

    /// Alle Einträge ohne Existenzprüfung (für Tests und `prune`).
    public func rawEntries() -> [BackupJournalEntry] {
        lock.withLock { (try? withFileLock { try readUnlocked() }) ?? [] }
    }

    // MARK: - Schreiben

    /// Hängt einen Eintrag an und kürzt das Journal auf `maxEntries`.
    public func append(_ entry: BackupJournalEntry) throws {
        try lock.withLock {
            try withFileLock {
                var entries = try readUnlocked()
                entries.append(entry)
                if entries.count > maxEntries {
                    entries.removeFirst(entries.count - maxEntries)
                }
                try writeUnlocked(entries)
            }
        }
    }

    /// Bequemer Weg für `TrashBackup`: Prüfsumme der Kopie berechnen und
    /// den Eintrag anlegen. Die Kopie ist zu diesem Zeitpunkt byte-gleich mit
    /// dem Original, gehasht wird aber die Kopie — sie ist es, die später
    /// zurückgespielt wird.
    @discardableResult
    public func record(original: URL, backup: URL, size: Int64, reason: String,
                       date: Date = Date()) throws -> BackupJournalEntry {
        let checksum = size <= Self.checksumSizeLimit ? try Self.sha256(of: backup) : nil
        let entry = BackupJournalEntry(
            originalPath: MediaFormats.canonicalFileURL(original).path,
            backupPath: backup.path,
            date: date, size: size, sha256: checksum, reason: reason)
        try append(entry)
        return entry
    }

    /// Nach einer Umbenennung: Alle Einträge, deren Original `from` war,
    /// zeigen auf `to` — die Kopien im Papierkorb bleiben, wo sie sind.
    /// Liefert die Zahl der umgeschriebenen Einträge (0, wenn die Datei
    /// nie gesichert wurde; das ist kein Fehler).
    @discardableResult
    public func relocate(from: URL, to: URL) throws -> Int {
        let oldPath = MediaFormats.canonicalFileURL(from).path
        let newPath = MediaFormats.canonicalFileURL(to).path
        guard oldPath != newPath else { return 0 }
        return try lock.withLock {
            try withFileLock {
                var entries = try readUnlocked()
                var changed = 0
                for index in entries.indices where entries[index].originalPath == oldPath {
                    entries[index].originalPath = newPath
                    changed += 1
                }
                if changed > 0 { try writeUnlocked(entries) }
                return changed
            }
        }
    }

    /// Entfernt Journal-Einträge: verfallene (Kopie fehlt) immer, dazu alle,
    /// die älter als `olderThan` sind. Dateien im Papierkorb bleiben
    /// unangetastet. Liefert die Zahl der entfernten Einträge.
    @discardableResult
    public func prune(olderThan cutoff: Date? = nil) throws -> Int {
        try lock.withLock {
            try withFileLock {
                let entries = try readUnlocked()
                let kept = entries.filter { entry in
                    guard entry.backupExists else { return false }
                    if let cutoff, entry.date < cutoff { return false }
                    return true
                }
                if kept.count != entries.count {
                    try writeUnlocked(kept)
                }
                return entries.count - kept.count
            }
        }
    }

    // MARK: - Prüfsumme

    /// SHA-256 einer Datei als Hex-String. Unter macOS über CryptoKit, sonst
    /// über `PortableSHA256` (reines Swift, Linux). Liest die Datei
    /// stückweise, damit auch große Dateien nicht komplett in den Speicher
    /// müssen. Optional bleibt der Rückgabetyp für Aufrufer, die ohne
    /// Prüfsumme weiterarbeiten können.
    public static func sha256(of url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var hasher = SHA256()
        #else
        var hasher = PortableSHA256()
        #endif
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        #if canImport(CryptoKit)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return hasher.finalizeHex()
        #endif
    }

    // MARK: - Intern

    private struct UnsupportedVersion: Error { var version: Int }

    private struct Document: Codable {
        var version: Int
        var entries: [BackupJournalEntry]

        init(version: Int, entries: [BackupJournalEntry]) {
            self.version = version
            self.entries = entries
        }

        private enum CodingKeys: String, CodingKey { case version, entries }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            // Vor den Einträgen prüfen, deren Schema sich geändert haben kann.
            guard version == BackupJournal.formatVersion else {
                throw UnsupportedVersion(version: version)
            }
            entries = try container.decode([BackupJournalEntry].self, forKey: .entries)
        }
    }

    /// Zeiten als ISO 8601 MIT Sekundenbruchteilen: Zwei Sicherungen derselben
    /// Datei innerhalb einer Sekunde (Save, sofort Undo) müssen sich in der
    /// Reihenfolge noch unterscheiden lassen — auch prozessübergreifend.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day()
                .time(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day()
                .time(includingFractionalSeconds: true)) {
                return date
            }
            // Ältere/handgeschriebene Einträge ohne Bruchteile.
            return try Date(text, strategy: .iso8601)
        }
        return decoder
    }()

    /// Liest die Datei; fehlt sie, ist das Journal leer. Eine unlesbare Datei
    /// wird beiseitegelegt (`.corrupt`), statt still überschrieben zu werden —
    /// die Kopien im Papierkorb bleiben davon unberührt.
    private func readUnlocked() throws -> [BackupJournalEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(Document.self, from: data).entries
        } catch let error as UnsupportedVersion {
            throw TagError.backupFailed(path: url.path,
                reason: "unsupported journal version \(error.version)")
        } catch {
            var aside = url.appendingPathExtension("corrupt")
            if fileManager.fileExists(atPath: aside.path) {
                aside = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            }
            // Frühere Defekte bleiben erhalten. Scheitert das Beiseitelegen,
            // darf ein anschließendes append die Quelldatei nicht überschreiben.
            try fileManager.moveItem(at: url, to: aside)
            return []
        }
    }

    /// Schreibt atomar: erst eine Temp-Datei im selben Ordner, dann `rename`.
    private func writeUnlocked(_ entries: [BackupJournalEntry]) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Document(version: Self.formatVersion, entries: entries))
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temp)
            throw TagError.backupFailed(path: url.path, reason: "journal could not be written")
        }
    }

    /// Prozessübergreifende Sperre über eine Nachbardatei `<journal>.lock`.
    /// `flock` gibt die Sperre beim Schließen des Deskriptors automatisch
    /// frei — auch wenn der Prozess mittendrin stirbt.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let lockPath = url.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw TagError.backupFailed(path: url.path, reason: "journal lock not available")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw TagError.backupFailed(path: url.path, reason: "journal lock failed")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

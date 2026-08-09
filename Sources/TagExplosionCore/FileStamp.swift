// Erkennungsmerkmal einer Datei auf der Platte (Größe + Änderungszeit + Inode).
//
// Zweck: Wer eine Datei im Editor offen hat, schreibt beim Speichern den
// gepufferten Stand zurück. Hat in der Zwischenzeit ein anderes Programm die
// Datei geändert, würde das Speichern diese fremde Änderung stillschweigend
// überschreiben. Der Stempel macht das erkennbar.
import Foundation

public struct FileStamp: Sendable, Equatable, Codable {
    public let size: Int64
    /// Sekunden seit 1970, mit der Auflösung des Dateisystems (APFS liefert
    /// die Änderungszeit nanosekundengenau).
    public let modified: TimeInterval
    /// Datenträger- und Datei-Identität (st_dev/st_ino). Ein atomarer
    /// Austausch per rename erzeugt eine neue Inode — so fällt auch eine
    /// gleich große Ersetzung mit exakt erhaltener Änderungszeit auf, die
    /// Größe+Zeit allein nicht unterscheiden könnten. Die Statuszeit (ctime)
    /// bleibt bewusst draußen: macOS ändert sie schon bei xattr-Pflege
    /// (Finder-Tags, Quarantäne), das gäbe falsche Konfliktmeldungen.
    public let device: UInt64?
    public let inode: UInt64?

    public init(size: Int64, modified: TimeInterval,
                device: UInt64? = nil, inode: UInt64? = nil) {
        self.size = size
        self.modified = modified
        self.device = device
        self.inode = inode
    }

    /// Aktueller Stempel der Datei; nil, wenn sie nicht (mehr) lesbar ist.
    ///
    /// Bewusst über `attributesOfItem` statt über `URL.resourceValues`: Eine
    /// URL-Instanz merkt sich einmal abgefragte Werte. Genau die zweite,
    /// spätere Abfrage derselben URL soll hier aber den echten neuen Stand
    /// liefern — sonst bliebe eine fremde Änderung unsichtbar.
    ///
    /// Der Pfad wird vorher aufgelöst: `attributesOfItem` folgt einer
    /// Verknüpfung (Symlink) NICHT und lieferte sonst Größe und Inode der
    /// Verknüpfung selbst. Gelesen und geschrieben wird aber immer die
    /// Zieldatei — und der atomare Austausch prüft den Stempel am aufgelösten
    /// Pfad. Ohne die Auflösung hier meldete das Speichern einer verknüpften
    /// Datei deshalb jedes Mal einen Konflikt, den es gar nicht gibt.
    public static func current(of url: URL) -> FileStamp? {
        let path = MediaFormats.canonicalFileURL(url).path
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileStamp(size: size, modified: modified, device: device, inode: inode)
    }

    /// Wirft `fileChangedOnDisk`, wenn die Datei seit `expected` verändert
    /// wurde. Ohne bekannten Ausgangsstempel (nil) wird nicht geprüft.
    public static func requireUnchanged(_ expected: FileStamp?, at url: URL) throws {
        guard let expected else { return }
        guard let now = current(of: url) else {
            throw TagError.cannotOpen(path: url.path)
        }
        guard now == expected else {
            throw TagError.fileChangedOnDisk(path: url.path)
        }
    }

    /// Vergleicht ausschließlich die Dateisystem-Identität. Pfadgleichheit ist
    /// ausdrücklich kein Ersatz dafür: Nach einem atomaren Austausch zeigt
    /// derselbe Pfad auf eine andere Inode.
    public func hasSameFileIdentity(as other: FileStamp) -> Bool {
        device != nil && device == other.device && inode != nil && inode == other.inode
    }
}

/// Ein gelesener Wert zusammen mit exakt dem Plattenstand, aus dem er stammt.
/// `capture` prüft den Stempel vor und nach allen Leseoperationen; so können
/// mehrere Backend-Aufrufe keinen Mischzustand aus zwei Dateifassungen bilden.
public struct FileSnapshot<Value: Sendable>: Sendable {
    public let value: Value
    public let stamp: FileStamp

    public init(value: Value, stamp: FileStamp) {
        self.value = value
        self.stamp = stamp
    }

    public static func capture(
        at url: URL,
        expecting expected: FileStamp? = nil,
        read: () throws -> Value
    ) throws -> FileSnapshot<Value> {
        guard let stamp = expected ?? FileStamp.current(of: url) else {
            throw TagError.cannotOpen(path: url.path)
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        let value = try read()
        try FileStamp.requireUnchanged(stamp, at: url)
        return FileSnapshot(value: value, stamp: stamp)
    }

    /// Erneute Prüfung direkt an einer Entscheidungsgrenze, insbesondere vor
    /// einer No-op-Erfolgsmeldung oder bevor der Schreibweg beginnt.
    public func requireCurrent(at url: URL) throws {
        try FileStamp.requireUnchanged(stamp, at: url)
    }
}

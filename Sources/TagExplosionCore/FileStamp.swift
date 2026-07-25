// Erkennungsmerkmal einer Datei auf der Platte (Größe + Änderungszeit).
//
// Zweck: Wer eine Datei im Editor offen hat, schreibt beim Speichern den
// gepufferten Stand zurück. Hat in der Zwischenzeit ein anderes Programm die
// Datei geändert, würde das Speichern diese fremde Änderung stillschweigend
// überschreiben. Der Stempel macht das erkennbar.
import Foundation

public struct FileStamp: Sendable, Equatable, Codable {
    public let size: Int64
    /// Sekunden seit 1970. Reicht für den Zweck: APFS liefert die
    /// Änderungszeit nanosekundengenau, ein fremder Schreibvorgang verschiebt
    /// sie also praktisch immer.
    public let modified: TimeInterval

    public init(size: Int64, modified: TimeInterval) {
        self.size = size
        self.modified = modified
    }

    /// Aktueller Stempel der Datei; nil, wenn sie nicht (mehr) lesbar ist.
    ///
    /// Bewusst über `attributesOfItem` statt über `URL.resourceValues`: Eine
    /// URL-Instanz merkt sich einmal abgefragte Werte. Genau die zweite,
    /// spätere Abfrage derselben URL soll hier aber den echten neuen Stand
    /// liefern — sonst bliebe eine fremde Änderung unsichtbar.
    public static func current(of url: URL) -> FileStamp? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileStamp(size: size, modified: modified)
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
}

// Undo-Historie: Die Papierkorb-Sicherungen einer Datei als Versionsliste,
// mit Feld-Vergleich und Zurückspielen einer Version.
//
// Quelle der Liste ist das `BackupJournal`; ob eine Version wirklich noch
// existiert, entscheidet der Papierkorb (verfallene Einträge fallen weg).
// Das Zurückspielen ist selbst ein Schreibweg und folgt denselben Regeln wie
// jedes Speichern: Der jetzige Stand wandert vorher in den Papierkorb
// (Auslöser `restore`), die Kopie wird gegen ihre Journal-Prüfsumme geprüft
// und ersetzt das Original erst atomar über `AtomicFileRewrite`.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Eine Version aus der Historie. `number` zählt von der jüngsten Sicherung
/// (1) aus — so meint `--version 1` in der CLI immer "die letzte Änderung".
public struct BackupVersion: Sendable, Equatable, Identifiable, Codable {
    public var number: Int
    public var entry: BackupJournalEntry

    public var id: String { entry.id }

    public init(number: Int, entry: BackupJournalEntry) {
        self.number = number
        self.entry = entry
    }
}

/// Ein Feld, das sich zwischen der Datei von heute und einer Version
/// unterscheidet. nil = das Feld fehlt auf dieser Seite.
public struct BackupFieldChange: Sendable, Equatable, Codable, Identifiable {
    public var key: String
    /// Der Feldname ist innerhalb eines Vergleichs eindeutig.
    public var id: String { key }
    /// Wert in der gesicherten Version (das, was ein Restore zurückholt).
    public var version: String?
    /// Wert in der Datei, wie sie jetzt auf der Platte liegt.
    public var current: String?

    public init(key: String, version: String?, current: String?) {
        self.key = key
        self.version = version
        self.current = current
    }
}

public enum BackupHistory {

    // MARK: - Versionsliste

    /// Alle noch vorhandenen Sicherungen der Datei, jüngste zuerst. Dazu
    /// zählen die Sicherungen der namensgebundenen Sidecars, in die die
    /// Schreibwege ausweichen: `<name>.xmp` bei Bildern (RAW und auf
    /// Wunsch), `<name>.lrc` bei Audio ohne SYLT (synchronisierte Lyrics)
    /// und `<name>.nfo` bei Videos (Kodi-Felder). Ein Restore einer solchen
    /// Version schreibt die Sidecar zurück, nicht das Medium.
    public static func versions(of url: URL,
                                journal: BackupJournal = .standard) -> [BackupVersion] {
        let canonical = MediaFormats.canonicalFileURL(url)
        var paths: Set<String> = [canonical.path]
        let ext = canonical.pathExtension.lowercased()
        if MediaFormats.kind(of: canonical) == .image, !MediaFormats.isXMPSidecar(canonical) {
            paths.insert(MediaFormats.canonicalFileURL(MediaFormats.sidecarURL(for: canonical)).path)
        }
        if MediaFormats.audio.contains(ext) {
            paths.insert(MediaFormats.canonicalFileURL(LRC.sidecarURL(for: canonical)).path)
        }
        if MediaFormats.nfoVideo.contains(ext) {
            let nfo = canonical.deletingPathExtension().appendingPathExtension(SidecarTool.nfoExtension)
            paths.insert(MediaFormats.canonicalFileURL(nfo).path)
        }
        // Jüngste zuerst; bei gleicher Zeit entscheidet die Journal-Reihenfolge
        // (später angehängt = neuer).
        let entries = journal.liveEntries().enumerated()
            .filter { paths.contains($0.element.originalPath) }
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date
                    ? lhs.element.date > rhs.element.date
                    : lhs.offset > rhs.offset
            }
            .map(\.element)
        return entries.enumerated().map { BackupVersion(number: $0.offset + 1, entry: $0.element) }
    }

    /// Die Version mit dieser Nummer (1 = jüngste); nil, wenn es sie nicht gibt.
    public static func version(_ number: Int, of url: URL,
                               journal: BackupJournal = .standard) -> BackupVersion? {
        versions(of: url, journal: journal).first { $0.number == number }
    }

    // MARK: - Vergleich

    /// Unterschiede zwischen der Datei von heute und einer Version, sortiert
    /// nach Feldname. Fehlt die Originaldatei inzwischen, stehen alle Felder
    /// der Version als "neu" da.
    public static func diff(current url: URL, against version: BackupVersion) throws -> [BackupFieldChange] {
        let original = URL(fileURLWithPath: version.entry.originalPath)
        let backup = URL(fileURLWithPath: version.entry.backupPath)
        guard version.entry.backupExists else {
            throw TagError.cannotOpen(path: backup.path)
        }
        // Die Medienart kommt vom Original: Die Kopie trägt dieselbe Endung,
        // aber eine `.nfo` erkennt `MediaFormats.kind` nur am Inhalt.
        let kind = MediaFormats.kind(of: original) ?? MediaFormats.kind(of: url)
        let before = try fieldMap(of: backup, kind: kind)
        let after = FileManager.default.fileExists(atPath: original.path)
            ? try fieldMap(of: original, kind: kind) : [:]
        return diff(version: before, current: after)
    }

    /// Reiner Vergleich zweier Feldtabellen (testbar ohne Dateien).
    public static func diff(version before: [String: String],
                            current after: [String: String]) -> [BackupFieldChange] {
        Set(before.keys).union(after.keys).sorted().compactMap { key in
            let old = before[key]
            let new = after[key]
            guard old != new else { return nil }
            return BackupFieldChange(key: key, version: old, current: new)
        }
    }

    /// Alle Metadaten einer Datei als flache Tabelle "Feld → Text", je nach
    /// Medienart über den passenden Leser. Audio nutzt die Tag-Schlüssel
    /// direkt (mehrere Werte mit " / " verbunden); Cover und Kapitel werden
    /// als Kurzfassung (Anzahl, Größe) gezeigt, damit ein Cover-Tausch
    /// sichtbar wird. Die übrigen Medienarten werden aus ihren Kernfeldern
    /// generisch abgeflacht (`authors` → "A / B", `custom[1].key` …).
    public static func fieldMap(of url: URL, kind: MediaFormats.Kind?) throws -> [String: String] {
        // LRC-Sidecar (keine eigene Medienart): die Zeilen als ein Feld, damit
        // ein Vergleich zweier Lyrics-Stände etwas zeigt.
        if url.pathExtension.lowercased() == "lrc" {
            let lines = try LRC.load(from: url).lines
            return lines.isEmpty ? [:] : ["SYNCEDLYRICS": LRC.render(lines)]
        }
        switch kind {
        case .audio:
            let data = try TagFile.read(at: url)
            var map: [String: String] = [:]
            for property in data.properties {
                map[property.key] = map[property.key].map { "\($0) / \(property.value)" } ?? property.value
            }
            if !data.artworks.isEmpty {
                map["COVER"] = data.artworks.map {
                    "\($0.resolvedMimeType) \($0.data.count) bytes"
                }.joined(separator: " / ")
            }
            if data.supportsChapters, !data.chapters.isEmpty {
                map["CHAPTERS"] = data.chapters.map(\.title).joined(separator: " / ")
            }
            return map
        case .image:
            return try flatten(ExifTool.readCoreFields(url: url))
        case .ebook:
            var map = try flatten(EbookTool.readCoreFields(url: url))
            if let cover = try EbookTool.readCover(url: url) {
                map["cover"] = "\(cover.resolvedMimeType) \(cover.data.count) bytes"
            }
            return map
        case .document:
            return try flatten(DocumentTool.readCoreFields(url: url))
        case .sidecar:
            switch try SidecarTool.read(url: url).fields {
            case .nfo(let fields): return try flatten(fields)
            case .subtitle(let fields): return try flatten(fields)
            }
        case .playlist:
            return try flatten(PlaylistTool.read(url: url).fields)
        case .invoice, nil:
            // Reine Anzeige bzw. unbekannt: Es gibt keine Felder zu vergleichen;
            // die Historie zeigt dann nur Zeit und Größe.
            return [:]
        }
    }

    /// Macht aus einem Codable-Wert eine flache Tabelle: verschachtelte
    /// Objekte als `a.b`, Objekt-Listen als `a[1].b`, Listen aus Skalaren
    /// mit " / " verbunden, leere Werte weggelassen.
    static func flatten<T: Encodable>(_ value: T) throws -> [String: String] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        var map: [String: String] = [:]
        flatten(object, prefix: "", into: &map)
        return map
    }

    private static func flatten(_ value: Any, prefix: String, into map: inout [String: String]) {
        switch value {
        case let dictionary as [String: Any]:
            for (key, child) in dictionary {
                flatten(child, prefix: prefix.isEmpty ? key : "\(prefix).\(key)", into: &map)
            }
        case let array as [Any]:
            if array.allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
                let parts = array.map { scalarText($0) }.filter { !$0.isEmpty }
                if !parts.isEmpty { map[prefix] = parts.joined(separator: " / ") }
            } else {
                for (index, child) in array.enumerated() {
                    flatten(child, prefix: "\(prefix)[\(index + 1)]", into: &map)
                }
            }
        default:
            let text = scalarText(value)
            if !text.isEmpty, !(value is NSNull) { map[prefix] = text }
        }
    }

    private static func scalarText(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case is NSNull: return ""
        case let number as NSNumber: return number.stringValue
        default: return String(describing: value)
        }
    }

    // MARK: - Prüfen und Zurückspielen

    /// Prüft, ob die Kopie noch da ist und zum Journal passt (Größe, und
    /// falls verzeichnet die SHA-256-Prüfsumme). Wirft `backupFailed` mit
    /// Begründung, wenn nicht — dann darf nichts zurückgespielt werden.
    public static func verify(_ version: BackupVersion) throws {
        let entry = version.entry
        let backup = URL(fileURLWithPath: entry.backupPath)
        guard entry.backupExists else {
            throw TagError.backupFailed(path: entry.backupPath, reason: "backup copy no longer exists")
        }
        try verifyContents(at: backup, against: entry)
    }

    private static func verifyContents(at url: URL, against entry: BackupJournalEntry) throws {
        guard let size = VolumeSpace.fileSize(of: url), size == entry.size else {
            throw TagError.backupFailed(path: url.path, reason: "backup size differs from journal")
        }
        if let expected = entry.sha256, let actual = try BackupJournal.sha256(of: url),
           expected != actual {
            throw TagError.backupFailed(path: url.path, reason: "backup checksum differs from journal")
        }
    }

    /// Spielt die Version auf ihren Originalpfad zurück.
    ///
    /// Ablauf: Kopie prüfen → Original zur Geschwisterkopie klonen (Rahmen) →
    /// Geschwisterkopie durch die Sicherung ersetzen → erneut prüfen → den
    /// jetzigen Stand des Originals in den Papierkorb sichern (`backup`) →
    /// atomarer Austausch. Fehlt das Original inzwischen, wird es exklusiv
    /// neu angelegt. `expecting` schützt wie beim Speichern vor einer fremden
    /// Änderung zwischen Anzeige und Austausch.
    public static func restore(_ version: BackupVersion,
                               expecting stamp: FileStamp? = nil,
                               backup: TrashBackup = .shared) throws {
        try verify(version)
        let entry = version.entry
        let source = URL(fileURLWithPath: entry.backupPath)
        let destination = URL(fileURLWithPath: entry.originalPath)
        let fileManager = FileManager.default

        let mutate: (URL) throws -> Void = { temp in
            // Die Geschwisterkopie des jetzigen Stands wird durch die
            // Sicherung ersetzt — als Klon, wo das Dateisystem es kann.
            try? fileManager.removeItem(at: temp)
            try clone(source, to: temp)
        }
        let validate: (URL) throws -> Void = { temp in
            try verifyContents(at: temp, against: entry)
        }
        let beforeReplace: () throws -> Void = {
            try backup.backUp(destination, reason: BackupReason.restore)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try AtomicFileRewrite.run(url: destination, expecting: stamp, replacingOriginal: true,
                                      beforeReplace: beforeReplace,
                                      mutate: mutate, validate: validate)
        } else {
            try AtomicFileRewrite.create(url: destination, replacingOriginal: true,
                                         beforeReplace: {}, mutate: mutate, validate: validate)
        }
    }

    /// Entfernt Journal-Einträge ohne Kopie und — falls angegeben — alle,
    /// die älter als `days` Tage sind. Fasst den Papierkorb nie an.
    @discardableResult
    public static func prune(olderThanDays days: Int? = nil,
                             journal: BackupJournal = .standard) throws -> Int {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        return try journal.prune(olderThan: cutoff)
    }

    /// Kopie wie in `TrashBackup`: auf APFS als Klon, sonst byteweise.
    private static func clone(_ source: URL, to target: URL) throws {
        #if canImport(Darwin)
        if clonefile(source.path, target.path, 0) == 0 { return }
        #endif
        try FileManager.default.copyItem(at: source, to: target)
    }
}

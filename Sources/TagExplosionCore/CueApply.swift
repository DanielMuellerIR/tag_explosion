// `cue apply`: Titel, Interpreten und Tracknummern eines Cue-Sheets in die
// referenzierten Audiodateien schreiben. Das geht nur, wenn jeder Track seine
// eigene Datei hat (FILE je Track) — ein Cue-Sheet über EIN großes Image
// müsste die Datei erst zerschneiden, und das tut Tag Explosion nicht.
//
// Ablauf: erst der komplette Plan (welche Datei bekommt welche Felder, was
// ändert sich wirklich), dann — nur auf ausdrücklichen Wunsch — das
// Schreiben über den gewohnten Weg (Schnappschuss, Papierkorb-Sicherung,
// atomarer Austausch in `TagFile.write`).
import Foundation

public enum CueApply {

    /// Ein zu beschreibender Track.
    public struct Item: Sendable, Codable, Equatable {
        public var number: Int
        public var file: String
        /// Zielwerte (Schlüssel wie in `TagProperty`, z.B. TITLE, ARTIST).
        public var properties: [String: String]
        /// Schlüssel, deren Wert sich gegenüber der Datei ändert (sortiert).
        public var changedKeys: [String]
    }

    public struct Plan: Sendable, Codable, Equatable {
        public var cue: String
        public var items: [Item]

        /// Dateien, bei denen mindestens ein Feld wechselt.
        public var changingItems: [Item] { items.filter { !$0.changedKeys.isEmpty } }
    }

    public enum ApplyError: Error, LocalizedError, Equatable {
        case noTracks(String)
        case trackWithoutFile(Int)
        case missingFile(String)
        case sharedFile(String, tracks: [Int])

        public var errorDescription: String? {
            switch self {
            case .noTracks(let path):
                return "The cue sheet has no tracks: \(path)"
            case .trackWithoutFile(let number):
                return "Track \(number) has no FILE entry"
            case .missingFile(let path):
                return "Referenced audio file not found: \(path)"
            case .sharedFile(let path, let tracks):
                return "Tracks \(tracks.map(String.init).joined(separator: ", ")) share one audio file "
                    + "(\(path)); splitting an image is not supported"
            }
        }
    }

    // MARK: - Planen

    /// Zielwerte je Track: TITLE, ARTIST (Track-, sonst Album-Interpret),
    /// ALBUM, ALBUMARTIST, TRACKNUMBER (n/gesamt), DATE, GENRE, ISRC — nur
    /// die im Cue-Sheet belegten.
    static func targetProperties(for entry: PlaylistEntry, in contents: PlaylistContents)
        -> [String: String] {
        var target: [String: String] = [:]
        func put(_ key: String, _ value: String) { if !value.isEmpty { target[key] = value } }
        put("TITLE", entry.title)
        put("ARTIST", entry.performer.isEmpty ? contents.fields.performer : entry.performer)
        put("ALBUM", contents.fields.title)
        put("ALBUMARTIST", contents.fields.performer)
        put("TRACKNUMBER", "\(entry.number)/\(contents.entries.count)")
        put("DATE", contents.fields.date)
        put("GENRE", contents.fields.genre)
        put("ISRC", entry.isrc)
        return target
    }

    public static func plan(cueURL: URL) throws -> Plan {
        let contents = try PlaylistTool.read(url: cueURL)
        guard contents.format == .cue else { throw TagError.cannotOpen(path: cueURL.path) }
        guard !contents.entries.isEmpty else { throw ApplyError.noTracks(cueURL.path) }
        enum Identity: Hashable {
            case file(device: UInt64, inode: UInt64)
            case path(String)
        }
        var owners: [Identity: (path: String, tracks: [Int])] = [:]
        for entry in contents.entries {
            guard let path = entry.resolvedPath else { throw ApplyError.trackWithoutFile(entry.number) }
            guard entry.exists else { throw ApplyError.missingFile(path) }
            let url = MediaFormats.canonicalFileURL(URL(fileURLWithPath: path))
            let stamp = FileStamp.current(of: url)
            let identity: Identity
            if let device = stamp?.device, let inode = stamp?.inode {
                identity = .file(device: device, inode: inode)
            } else {
                identity = .path(url.path)
            }
            // Symlinks und Hardlinks dürfen dieselbe Audiodatei nicht für
            // mehrere Tracks zur vermeintlich getrennten Schreibdatei machen.
            owners[identity, default: (url.path, [])].tracks.append(entry.number)
        }
        for owner in owners.values.sorted(by: { $0.path < $1.path }) where owner.tracks.count > 1 {
            throw ApplyError.sharedFile(owner.path, tracks: owner.tracks)
        }
        var items: [Item] = []
        for entry in contents.entries {
            let url = URL(fileURLWithPath: entry.resolvedPath!)
            let existing = try TagFile.read(at: url)
            let target = targetProperties(for: entry, in: contents)
            let changed = target.keys.filter { existing.values(for: $0) != [target[$0]!] }.sorted()
            items.append(Item(number: entry.number, file: url.path,
                              properties: target, changedKeys: changed))
        }
        return Plan(cue: cueURL.path, items: items)
    }

    // MARK: - Schreiben

    /// Ein Fehler, nachdem schon Dateien geändert wurden. Ohne diese Angabe
    /// sähe der Aufrufer nur den Fehler zur abbrechenden Datei und erführe
    /// nicht, dass die vorherigen bereits geschrieben sind
    /// (Review-Fund 2026-09-10).
    public struct PartialApplyError: LocalizedError, Equatable {
        public let written: [String]
        public let failed: String
        public let reason: String

        public init(written: [String], failed: String, reason: String) {
            self.written = written
            self.failed = failed
            self.reason = reason
        }

        public var errorDescription: String? {
            "\(failed): \(reason)\nAlready changed before this file: "
                + written.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: ", ")
        }
    }

    /// Schreibt alle Dateien mit Änderungen; liefert deren Zahl. Jede Datei
    /// läuft einzeln über Schnappschuss, Sicherung und atomaren Austausch —
    /// ein Fehler stoppt vor der nächsten Datei und nennt die schon
    /// geschriebenen.
    @discardableResult
    public static func apply(_ plan: Plan) throws -> Int {
        var written: [String] = []
        for item in plan.changingItems {
            let url = URL(fileURLWithPath: item.file)
            do {
                let snapshot = try FileSnapshot.capture(at: url) { try TagFile.read(at: url) }
                var properties = snapshot.value.properties
                for (key, value) in item.properties.sorted(by: { $0.key < $1.key }) {
                    properties.removeAll { $0.key == key }
                    properties.append(TagProperty(key: key, value: value))
                }
                try snapshot.requireCurrent(at: url)
                try TrashBackup.shared.backUp(url)
                try TagFile.write(properties: properties, to: url, expecting: snapshot.stamp)
            } catch {
                guard !written.isEmpty else { throw error }
                throw PartialApplyError(written: written, failed: item.file,
                                        reason: error.localizedDescription)
            }
            written.append(item.file)
        }
        return written.count
    }
}

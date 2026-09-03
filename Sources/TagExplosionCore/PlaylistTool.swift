// Playlists und Cue-Sheets: `.cue` (Album-Kopf plus Trackliste), `.m3u`/
// `.m3u8` (EXTINF-Zeilen), `.pls` (INI-artig) und `.xspf` (XML). Alle vier
// haben einen gemeinsamen Feldsatz (`PlaylistCoreFields`): Titel und
// Interpret der Playlist, bei Cue-Sheets Datum und Genre, dazu je Eintrag
// Titel und Interpret. Was ein Format davon nicht speichern kann, meldet
// `supportedFields` — App und CLI blenden solche Felder aus, ein
// Schreibversuch darauf wird VOR jeder Mutation abgelehnt.
//
// Backends (je eine Datei):
// - CueSheetFile:  Standard-Cue-Format, zeilenweise (Rest bleibt erhalten)
// - M3UPlaylistFile: #EXTM3U/#PLAYLIST/#EXTINF, zeilenweise
// - PLSPlaylistFile: [playlist] mit FileN/TitleN/LengthN, zeilenweise
// - XSPFPlaylistFile: XML (title, creator, trackList/track/…)
//
// Pfade in Playlists sind meist relativ zur Playlist-Datei; `PlaylistTool`
// löst sie auf und prüft, ob die Datei existiert. Reihenfolge und Einträge
// selbst werden nicht bearbeitet, nur ihre Beschriftung.
import Foundation

/// Die Playlist-Formate; Rohwert = Dateiendung.
public enum PlaylistFormat: String, Sendable, Codable, CaseIterable {
    case cue, m3u, m3u8, pls, xspf

    public init?(url: URL) {
        self.init(rawValue: url.pathExtension.lowercased())
    }

    /// Alle Endungen (für MediaFormats).
    public static let extensions: Set<String> = Set(allCases.map(\.rawValue))
}

/// Die editierbaren Felder einer Playlist.
public enum PlaylistField: String, CaseIterable, Sendable, Codable {
    /// Titel der Playlist / des Albums (cue TITLE, m3u #PLAYLIST, xspf title).
    case title
    /// Interpret der Playlist / des Albums (cue PERFORMER, xspf creator).
    case performer
    /// Datum (cue `REM DATE`).
    case date
    /// Genre (cue `REM GENRE`).
    case genre
    /// Titel eines Eintrags (cue TITLE im Track, m3u EXTINF-Text, pls TitleN,
    /// xspf track/title).
    case entryTitle
    /// Interpret eines Eintrags (cue PERFORMER im Track, xspf track/creator).
    case entryPerformer
}

/// Beschriftung eines Eintrags, wie sie bearbeitet werden kann.
public struct PlaylistEntryFields: Sendable, Codable, Equatable, Hashable {
    public var title: String
    public var performer: String

    public init(title: String = "", performer: String = "") {
        self.title = title
        self.performer = performer
    }
}

/// Editierbare Kernfelder einer Playlist. `entries` hat genau einen Eintrag
/// je Playlist-Eintrag in Dateireihenfolge — Einträge kommen weder dazu
/// noch fallen sie weg.
public struct PlaylistCoreFields: Sendable, Codable, Equatable {
    public var title: String
    public var performer: String
    public var date: String
    public var genre: String
    public var entries: [PlaylistEntryFields]

    public init(title: String = "", performer: String = "", date: String = "",
                genre: String = "", entries: [PlaylistEntryFields] = []) {
        self.title = title
        self.performer = performer
        self.date = date
        self.genre = genre
        self.entries = entries
    }

    /// Wert eines Kopffelds (für die Feld-für-Feld-Prüfung).
    func value(of field: PlaylistField) -> [String] {
        switch field {
        case .title: return [title]
        case .performer: return [performer]
        case .date: return [date]
        case .genre: return [genre]
        case .entryTitle: return entries.map(\.title)
        case .entryPerformer: return entries.map(\.performer)
        }
    }
}

/// Ein Eintrag der Playlist, wie er angezeigt wird (nur lesend; die
/// bearbeitbare Beschriftung steht in `PlaylistCoreFields.entries`).
public struct PlaylistEntry: Sendable, Codable, Equatable {
    /// Laufende Nummer, 1-basiert: bei Cue-Sheets die Tracknummer, sonst die
    /// Position in der Datei.
    public var number: Int
    /// Pfad oder URI, wie er in der Datei steht ("" bei einem Cue-Track ohne
    /// FILE-Zeile).
    public var location: String
    /// Aufgelöster Dateipfad (relativ zur Playlist, `file://`-URIs entpackt);
    /// nil für Netzadressen und Einträge ohne Pfad.
    public var resolvedPath: String?
    /// Die aufgelöste Datei existiert.
    public var exists: Bool
    /// Netzadresse (http/https/…): wird nicht auf Existenz geprüft.
    public var isRemote: Bool
    public var title: String
    public var performer: String
    /// Album (nur xspf).
    public var album: String
    /// Spielzeit, wenn bekannt (m3u EXTINF, pls LengthN, xspf duration; bei
    /// Cue-Sheets aus den INDEX-Zeiten bzw. der Länge der Audiodatei).
    public var durationMilliseconds: Int?
    /// Beginn innerhalb der Audiodatei (cue INDEX 01), nil bei anderen Formaten.
    public var startMilliseconds: Int?
    /// ISRC (nur cue).
    public var isrc: String

    public init(number: Int, location: String = "", resolvedPath: String? = nil,
                exists: Bool = false, isRemote: Bool = false, title: String = "",
                performer: String = "", album: String = "", durationMilliseconds: Int? = nil,
                startMilliseconds: Int? = nil, isrc: String = "") {
        self.number = number
        self.location = location
        self.resolvedPath = resolvedPath
        self.exists = exists
        self.isRemote = isRemote
        self.title = title
        self.performer = performer
        self.album = album
        self.durationMilliseconds = durationMilliseconds
        self.startMilliseconds = startMilliseconds
        self.isrc = isrc
    }

    /// Die bearbeitbare Beschriftung dieses Eintrags.
    public var fields: PlaylistEntryFields {
        PlaylistEntryFields(title: title, performer: performer)
    }
}

/// Zusammengehöriger Inhalt einer Playlist aus einem Lesevorgang.
public struct PlaylistContents: Sendable, Codable, Equatable {
    public var format: PlaylistFormat
    public var fields: PlaylistCoreFields
    public var entries: [PlaylistEntry]
    /// Weitere Kopfangaben nur zur Anzeige (cue CATALOG, SONGWRITER, andere
    /// REM-Zeilen; xspf annotation …).
    public var info: [DocumentInfoItem]
    /// Datei war kein gültiges UTF-8 und wurde mit Latin1-/MacRoman-Fallback
    /// gelesen. Beim Schreiben entsteht daraus UTF-8.
    public var usedEncodingFallback: Bool

    public init(format: PlaylistFormat, fields: PlaylistCoreFields, entries: [PlaylistEntry],
                info: [DocumentInfoItem] = [], usedEncodingFallback: Bool = false) {
        self.format = format
        self.fields = fields
        self.entries = entries
        self.info = info
        self.usedEncodingFallback = usedEncodingFallback
    }

    /// Summe der bekannten Spielzeiten.
    public var totalDurationMilliseconds: Int {
        entries.compactMap(\.durationMilliseconds).reduce(0, +)
    }

    /// Einträge, deren Spielzeit unbekannt ist (die Summe ist dann unvollständig).
    public var unknownDurationCount: Int {
        entries.filter { $0.durationMilliseconds == nil }.count
    }

    /// Lokale Einträge, deren Datei fehlt.
    public var missingCount: Int {
        entries.filter { !$0.isRemote && $0.resolvedPath != nil && !$0.exists }.count
    }
}

/// Was ein Backend können muss. Die Backends arbeiten auf der Datei, die
/// ihnen genannt wird (beim Schreiben ist das die Geschwisterkopie).
protocol PlaylistBackend {
    static var supportedFields: Set<PlaylistField> { get }
    /// Liest die Datei; Pfade werden relativ zu `base` (Ordner der
    /// ORIGINAL-Playlist) aufgelöst.
    static func read(url: URL, base: URL) throws -> PlaylistContents
    /// Formatregeln für Werte (z.B. keine Anführungszeichen in cue-Werten).
    static func validate(_ fields: PlaylistCoreFields, original: PlaylistCoreFields) throws
    /// Ändert die Datei DIREKT (Aufrufer arbeitet auf der Geschwisterkopie).
    static func mutate(url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields) throws
}

public enum PlaylistTool {

    /// Alle Playlist-Endungen.
    public static let extensions: Set<String> = PlaylistFormat.extensions

    static func implementation(for url: URL) throws -> PlaylistBackend.Type {
        switch PlaylistFormat(url: url) {
        case .cue: return CueSheetFile.self
        case .m3u, .m3u8: return M3UPlaylistFile.self
        case .pls: return PLSPlaylistFile.self
        case .xspf: return XSPFPlaylistFile.self
        case nil: throw TagError.cannotOpen(path: url.path)
        }
    }

    // MARK: - Fähigkeiten

    /// Felder, die das Format der Datei speichern kann. Unbekannte Endung: leer.
    public static func supportedFields(url: URL) -> Set<PlaylistField> {
        (try? implementation(for: url))?.supportedFields ?? []
    }

    // MARK: - Lesen

    public static func read(url: URL) throws -> PlaylistContents {
        try implementation(for: url).read(url: url, base: url.deletingLastPathComponent())
    }

    /// Inhalt unter einem Dateistempel (gleiche Regel wie bei Dokumenten).
    public static func readSnapshot(url: URL, expecting stamp: FileStamp? = nil)
        throws -> FileSnapshot<PlaylistContents> {
        try FileSnapshot.capture(at: url, expecting: stamp) { try read(url: url) }
    }

    // MARK: - Schreiben

    /// Lehnt ab, was das Ziel nicht speichern kann — VOR Sicherung und
    /// Schreibweg: geänderte Felder außerhalb von `supportedFields`, eine
    /// veränderte Eintragszahl und Werte, die das Format so nicht ablegt.
    public static func requireWritable(
        _ fields: PlaylistCoreFields, original: PlaylistCoreFields, url: URL
    ) throws {
        let backend = try implementation(for: url)
        guard fields.entries.count == original.entries.count else {
            throw TagError.invalidDocumentValue(
                field: "entries", reason: "the number of entries cannot change")
        }
        for field in PlaylistField.allCases
        where fields.value(of: field) != original.value(of: field)
            && !backend.supportedFields.contains(field) {
            throw TagError.unsupportedDocumentField(name: field.rawValue)
        }
        for (index, entry) in fields.entries.enumerated() {
            for value in [entry.title, entry.performer]
            where value.contains("\n") || value.contains("\r") {
                throw TagError.invalidDocumentValue(
                    field: "entry \(index + 1)", reason: "values must be a single line")
            }
        }
        for (name, value) in [("title", fields.title), ("performer", fields.performer),
                              ("date", fields.date), ("genre", fields.genre)]
        where value.contains("\n") || value.contains("\r") {
            throw TagError.invalidDocumentValue(field: name, reason: "values must be a single line")
        }
        try backend.validate(fields, original: original)
    }

    /// Schreibt die Unterschiede zu `original` als eine Transaktion: Sicherung
    /// macht der Aufrufer (`TrashBackup`), der Austausch läuft atomar, und die
    /// fertige Kopie wird vor dem Austausch zurückgelesen — nur wenn sie
    /// exakt die Zielfelder liefert, ersetzt sie das Original.
    public static func write(
        url: URL, fields: PlaylistCoreFields, original: PlaylistCoreFields,
        expecting stamp: FileStamp? = nil
    ) throws {
        try requireWritable(fields, original: original, url: url)
        guard fields != original else {
            try FileStamp.requireUnchanged(stamp, at: url)
            return
        }
        try FileStamp.requireUnchanged(stamp, at: url)
        let backend = try implementation(for: url)
        let base = url.deletingLastPathComponent()
        try AtomicFileRewrite.run(url: url, expecting: stamp) { temp in
            try withOriginalPath(url) {
                try backend.mutate(url: temp, fields: fields, original: original)
            }
        } validate: { temp in
            try withOriginalPath(url) {
                let readBack = try backend.read(url: temp, base: base).fields
                guard readBack == fields else { throw TagError.saveFailed(path: temp.path) }
            }
        }
    }

    /// Fehler von der versteckten Geschwisterkopie auf die gewählte Datei
    /// umstellen (gleiche Begründung wie in DocumentTool).
    private static func withOriginalPath(_ url: URL, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as TagError {
            switch error {
            case .cannotOpen: throw TagError.cannotOpen(path: url.path)
            case .saveFailed: throw TagError.saveFailed(path: url.path)
            case .readOnly: throw TagError.readOnly(path: url.path)
            case .fileChangedOnDisk: throw TagError.fileChangedOnDisk(path: url.path)
            default: throw error
            }
        }
    }

    // MARK: - Gemeinsame Helfer der Backends

    /// Löst einen Playlist-Pfad auf: `file://`-URIs werden entpackt, Netz-
    /// adressen erkannt, relative Pfade an `base` gehängt. Rückschrägstriche
    /// (Windows-Playlists) gelten als Pfadtrenner.
    static func resolve(location: String, base: URL) -> (path: String?, isRemote: Bool) {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, false) }
        // Windows-Laufwerk (`C:\Musik\…`) oder UNC (`\\server\share\…`): ein
        // absoluter Fremdpfad. Ihn an den Playlist-Ordner zu hängen ergäbe
        // `<Ordner>/C:/Musik/…` — ein Pfad, den es nie gibt. Er bleibt als
        // absoluter Pfad stehen und gilt hier schlicht als nicht vorhanden.
        if isWindowsAbsolutePath(trimmed) {
            return (trimmed.replacingOccurrences(of: "\\", with: "/"), false)
        }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), !scheme.isEmpty,
           scheme.count > 1 {  // "C:" wäre sonst ein Schema
            if scheme == "file" {
                guard let url = URL(string: trimmed), url.isFileURL else { return (nil, true) }
                return (url.standardizedFileURL.path, false)
            }
            return (nil, true)
        }
        var path = trimmed.replacingOccurrences(of: "\\", with: "/")
        // Relative URIs (xspf) sind prozentkodiert; ein unkodierter Pfad mit
        // "%" bleibt so, wie er ist, wenn das Dekodieren nichts ändert.
        if path.contains("%"), let decoded = path.removingPercentEncoding { path = decoded }
        if path.hasPrefix("/") {
            return (URL(fileURLWithPath: path).standardizedFileURL.path, false)
        }
        return (base.appendingPathComponent(path).standardizedFileURL.path, false)
    }

    /// `C:\…`, `C:/…` (Laufwerksbuchstabe) oder `\\server\…` (UNC).
    static func isWindowsAbsolutePath(_ text: String) -> Bool {
        if text.hasPrefix("\\\\") { return true }
        let scalars = Array(text.unicodeScalars.prefix(3))
        guard scalars.count == 3 else { return false }
        return CharacterSet.letters.contains(scalars[0]) && scalars[1] == ":"
            && (scalars[2] == "\\" || scalars[2] == "/")
    }

    /// Größte Dauer, die als Millisekunden-`Int` übernommen wird (1e12 s,
    /// über 30 000 Jahre). Alles darüber, `inf` und `nan` sind zwar
    /// parsebare Doubles, aber keine Dauer — `Int(1e16 * 1000)` wäre ein
    /// Laufzeitabbruch mitten im Lesen einer sonst brauchbaren Playlist.
    static let maxDurationSeconds: Double = 1e12

    /// Sekunden aus einer Playlist-Angabe (`#EXTINF:`, PLS `Length`): nur
    /// endliche Werte von 0 bis `maxDurationSeconds`; sonst nil (= unbekannt).
    static func parseSeconds(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, value >= 0, value <= maxDurationSeconds else { return nil }
        return value
    }

    /// Sekunden → Millisekunden für Dauer-Felder (Eingabe vorher über
    /// `parseSeconds` begrenzt, damit die Umrechnung nicht überläuft).
    static func milliseconds(fromSeconds seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    /// Existenzprüfung als Teil des Lesens (nur reguläre Dateien zählen).
    static func fileExists(_ path: String?) -> Bool {
        guard let path else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Baut den Anzeige-Eintrag aus Rohwerten (Pfadauflösung inklusive).
    static func makeEntry(number: Int, location: String, base: URL, title: String,
                          performer: String, album: String = "",
                          durationMilliseconds: Int? = nil, startMilliseconds: Int? = nil,
                          isrc: String = "") -> PlaylistEntry {
        let resolved = resolve(location: location, base: base)
        return PlaylistEntry(
            number: number, location: location, resolvedPath: resolved.path,
            exists: fileExists(resolved.path), isRemote: resolved.isRemote,
            title: title, performer: performer, album: album,
            durationMilliseconds: durationMilliseconds, startMilliseconds: startMilliseconds,
            isrc: isrc)
    }

    /// Spielzeit als "m:ss" bzw. "h:mm:ss".
    public static func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = (milliseconds + 500) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

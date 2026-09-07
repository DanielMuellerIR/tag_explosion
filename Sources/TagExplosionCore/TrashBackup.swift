// Abgesicherter Modus: Vor jeder Änderung wandert eine unveränderte Kopie der
// Datei in den Papierkorb.
//
// Warum ausgerechnet der Papierkorb? Solange die App jung ist, soll ein Fehler
// keine Datei endgültig kosten. Ein eigener Sicherungsordner irgendwo im
// Benutzerordner würde unbemerkt volllaufen; der Papierkorb ist sichtbar, jeder
// weiß, wie man ihn leert, und macOS räumt ihn auf Wunsch selbst auf.
//
// Aufbau: Pro Sitzung und Datenträger entsteht genau EIN Papierkorb-Eintrag
// ("Tag Explosion Backup <Zeitstempel>"), in den alle Sicherungen dieser
// Sitzung hineinlaufen. Die Kopie entsteht immer auf demselben Datenträger wie
// das Original — auf APFS als Klon, der zunächst keinen zusätzlichen Platz
// belegt. Jede Kopie wird zusätzlich im `BackupJournal` verzeichnet; daraus
// entsteht die Undo-Historie (`BackupHistory`).
//
// Papierkorb je Plattform: macOS über `FileManager.trashItem`; Linux/BSD
// über die freedesktop.org-Konvention in `XDGTrash` (`~/.local/share/Trash`
// bzw. `<Einhängepunkt>/.Trash-<uid>`). Beide Wege ergeben denselben
// Ordneraufbau, den `BackupHistory` zurückliest.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class TrashBackup: @unchecked Sendable {

    /// Gemeinsame Instanz — App, CLI und Core-Schreibwege teilen sich einen
    /// Sicherungsordner pro Sitzung. Nur sie schreibt ins Standard-Journal
    /// (`BackupJournal.standard`), aus dem die Undo-Historie gespeist wird.
    public static let shared = TrashBackup(journal: .standard)

    /// Eigene Instanz mit eigenem Sicherungsordner. Tests benutzen sie, damit
    /// sie den gemeinsamen Zustand nicht anfassen müssen. Ohne `journal`
    /// werden die Sicherungen nirgends verzeichnet (kein Eintrag im Journal
    /// des Benutzers durch Testläufe).
    ///
    /// `xdgTrash` wählt den Papierkorb nach freedesktop-Konvention statt des
    /// System-Papierkorbs. Außerhalb von macOS ist das der einzige Weg und
    /// wird bei nil automatisch mit den Standardpfaden benutzt; unter macOS
    /// dient der Parameter den Tests, die den Linux-Weg mit einem
    /// Temp-Verzeichnis als Datenverzeichnis durchspielen.
    public convenience init(journal: BackupJournal? = nil, xdgTrash: XDGTrash? = nil) {
        self.init(journal: journal, xdgTrash: xdgTrash, copyFile: Self.clone)
    }

    /// Austauschbarer Kopierer für deterministische Tests fremder Änderungen
    /// während einer Sicherung. Der öffentliche Weg verwendet immer clone.
    init(journal: BackupJournal?, xdgTrash: XDGTrash?,
         copyFile: @escaping (URL, URL) throws -> Void) {
        self.journal = journal
        self.copyFile = copyFile
        #if os(macOS)
        self.xdgTrash = xdgTrash
        #else
        self.xdgTrash = xdgTrash ?? XDGTrash()
        #endif
    }

    /// Journal, in dem jede Sicherung verzeichnet wird (siehe `BackupJournal`).
    /// nil = keine Historie, nur die Kopie im Papierkorb.
    public let journal: BackupJournal?

    /// Papierkorb nach freedesktop-Konvention; nil = System-Papierkorb (macOS).
    public let xdgTrash: XDGTrash?
    private let copyFile: (URL, URL) throws -> Void

    private let lock = NSLock()
    /// Serialisiert komplette Sicherungsvorgänge: Zwei parallele `backUp`-
    /// Aufrufe dürfen weder doppelte Sitzungsordner anlegen noch denselben
    /// freien Zielnamen wählen (Prüfen und Kopieren wären sonst getrennte,
    /// nicht atomare Schritte). Bewusst ein zweites Lock neben `lock`, damit
    /// die kurzen Zustands-Zugriffe der Getter nicht hinter laufenden Kopien
    /// warten müssen.
    private let operationLock = NSLock()
    /// Standard aus: Eine Bibliothek darf nicht ungefragt in den Papierkorb
    /// schreiben. App und CLI schalten den Modus beim Start ausdrücklich ein
    /// (dort ist er standardmäßig aktiv), Tests lassen ihn aus.
    private var enabled = false
    private var label = "Tag Explosion Backup"
    private var stamp: String?
    /// Datenträger-Kennung → bereits im Papierkorb liegender Sicherungsordner.
    private var folders: [String: URL] = [:]
    /// Kanonischer Quellordner → Name seines Unterordners in der Sicherung.
    private var subfolderNames: [String: String] = [:]
    /// Bereits gesicherter Stand samt Ablageort der Kopie. Der Ort gehört
    /// dazu: Nur wenn die Kopie noch existiert (Papierkorb nicht geleert),
    /// darf ein unveränderter Stand übersprungen werden.
    private struct SavedState {
        var stamp: FileStamp
        var backupCopy: URL
    }
    /// Kanonischer Dateipfad → Stand, der bereits gesichert ist.
    private var savedStates: [String: SavedState] = [:]
    private var bytesWritten: Int64 = 0

    /// Ist der abgesicherte Modus aktiv? In App und CLI standardmäßig ja.
    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Name des Papierkorb-Eintrags ohne Zeitstempel. Die App setzt hier die
    /// übersetzte Fassung; die CLI belässt es beim englischen Standard.
    public var folderLabel: String {
        get { lock.withLock { label } }
        set { lock.withLock { label = newValue } }
    }

    /// Summe der in dieser Sitzung gesicherten Bytes (für die Anzeige in den
    /// Einstellungen).
    public var backedUpBytes: Int64 {
        lock.withLock { bytesWritten }
    }

    /// Der Sicherungsordner dieser Sitzung, falls schon einer angelegt wurde.
    public var currentFolders: [URL] {
        lock.withLock { Array(folders.values) }
    }

    /// Sichert die Dateien, bevor sie verändert werden. Schlägt das fehl, wirft
    /// die Methode — im abgesicherten Modus wird dann bewusst gar nicht
    /// geschrieben.
    ///
    /// Eine Datei wird höchstens einmal je Stand gesichert: Ändert sich nach
    /// der Sicherung nichts an Größe und Änderungszeit, ist die vorhandene
    /// Kopie bereits byte-gleich.
    ///
    /// `reason` benennt den Auslöser fürs Journal (Tag-Save, Cover, Import …,
    /// siehe `BackupReason`); die Historie zeigt ihn dem Nutzer an.
    public func backUp(_ urls: [URL], reason: String = BackupReason.save) throws {
        guard isEnabled else { return }
        // Ein Sicherungsvorgang nach dem anderen — siehe `operationLock`.
        try operationLock.withLock {
            try serializedBackUp(urls, reason: reason)
        }
    }

    /// Bequemer Einzelaufruf für die Schreibwege.
    public func backUp(_ url: URL, reason: String = BackupReason.save) throws {
        try backUp([url], reason: reason)
    }

    /// Eigentlicher Sicherungsvorgang; läuft immer unter `operationLock`.
    private func serializedBackUp(_ urls: [URL], reason: String) throws {
        let fileManager = FileManager.default
        var pending: [(url: URL, state: FileStamp)] = []
        var seen: Set<String> = []

        for url in urls {
            let canonical = MediaFormats.canonicalFileURL(url)
            guard seen.insert(canonical.path).inserted,
                  fileManager.fileExists(atPath: canonical.path),
                  let state = FileStamp.current(of: canonical) else { continue }
            // Überspringen nur, wenn der Stand gesichert ist UND die Kopie noch
            // existiert — nach einem geleerten Papierkorb muss neu gesichert
            // werden, sonst liefe ein zweiter Schreibversuch ohne Sicherung.
            if let saved = lock.withLock({ savedStates[canonical.path] }),
               saved.stamp == state,
               fileManager.fileExists(atPath: saved.backupCopy.path) {
                continue
            }
            pending.append((canonical, state))
        }
        guard !pending.isEmpty else { return }

        // Platz prüfen, bevor die erste Kopie entsteht: eine halb geschriebene
        // Sicherung ist schlimmer als gar keine. Pro Datenträger zählt der
        // GESAMTE Bedarf des Stapels — jede Datei einzeln gegen denselben
        // freien Platz zu prüfen, ließe einen zu großen Stapel erst mitten in
        // den Kopien scheitern.
        let byVolume = Dictionary(grouping: pending.map(\.url), by: volumeKey(for:))
        for volumeURLs in byVolume.values {
            try VolumeSpace.requireRoom(for: volumeURLs[0],
                                        extraFiles: Array(volumeURLs.dropFirst()))
        }

        for (url, state) in pending {
            do {
                let target = try destination(for: url)
                try FileStamp.requireUnchanged(state, at: url)
                try copyFile(url, target)
                // Größe und Journal müssen dieselbe Fassung wie die Kopie
                // beschreiben. Fremde Änderungen während des Kopierens dürfen
                // weder als Erfolg noch für die Deduplizierung verbucht werden.
                try FileStamp.requireUnchanged(state, at: url)
                lock.withLock {
                    savedStates[url.path] = SavedState(stamp: state, backupCopy: target)
                    bytesWritten += state.size
                }
                // Journal-Eintrag für die Undo-Historie. Bewusst NICHT
                // fehlerhart: Die Kopie liegt sicher im Papierkorb, ein
                // unschreibbares Journal darf das Speichern nicht verhindern —
                // die Datei bleibt dann nur aus der Versionsliste draußen.
                try? journal?.record(original: url, backup: target,
                                     size: state.size, reason: reason)
            } catch let error as TagError {
                throw error
            } catch {
                throw TagError.backupFailed(path: url.path,
                                            reason: error.localizedDescription)
            }
        }
    }

    /// Setzt die Sitzung zurück (Tests; danach entsteht ein neuer Ordner).
    public func resetSession() {
        lock.withLock {
            stamp = nil
            folders = [:]
            subfolderNames = [:]
            savedStates = [:]
            bytesWritten = 0
        }
    }

    // MARK: - Intern

    /// Zielpfad der Sicherungskopie: Sicherungsordner des Datenträgers, darin
    /// ein Unterordner mit dem Namen des Quellordners.
    private func destination(for url: URL) throws -> URL {
        let folder = try sessionFolder(for: url)
        let sourceDirectory = url.deletingLastPathComponent()
        let subfolder = lock.withLock { () -> String in
            if let existing = subfolderNames[sourceDirectory.path] { return existing }
            let base = sourceDirectory.lastPathComponent.isEmpty
                ? "Volume" : sourceDirectory.lastPathComponent
            var candidate = base
            var counter = 2
            let taken = Set(subfolderNames.values)
            while taken.contains(candidate) {
                candidate = "\(base) (\(counter))"
                counter += 1
            }
            subfolderNames[sourceDirectory.path] = candidate
            return candidate
        }
        let directory = folder.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return uniqueName(in: directory, for: url.lastPathComponent)
    }

    /// Zwei Sicherungen derselben Datei in einer Sitzung (mehrfaches Speichern)
    /// dürfen sich nicht gegenseitig überschreiben.
    private func uniqueName(in directory: URL, for name: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            var next = "\(base) (\(counter))"
            if !ext.isEmpty { next += ".\(ext)" }
            candidate = directory.appendingPathComponent(next)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }

    /// Legt den Sicherungsordner für den Datenträger dieser Datei an — einmal
    /// pro Sitzung. Unter macOS entsteht der Ordner in einem Temp-Verzeichnis
    /// desselben Datenträgers und wandert sofort in dessen Papierkorb; mit
    /// `XDGTrash` entsteht er direkt im passenden `files/`-Verzeichnis, als
    /// wäre er neben dem Ordner der ersten gesicherten Datei gelöscht worden.
    /// Danach wird er direkt weiterbefüllt.
    private func sessionFolder(for url: URL) throws -> URL {
        let fileManager = FileManager.default
        let key = volumeKey(for: url)
        if let existing = lock.withLock({ folders[key] }),
           fileManager.fileExists(atPath: existing.path) {
            return existing
        }
        let name = "\(folderLabel) \(sessionStamp())"

        if let xdgTrash {
            let result = try xdgTrash.createTrashedFolder(
                named: name, originalParent: url.deletingLastPathComponent())
            lock.withLock { folders[key] = result }
            return result
        }

        #if os(macOS)
        let staging = try fileManager.url(for: .itemReplacementDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: url,
                                          create: true)
        let candidate = staging.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)

        var trashed: NSURL?
        try fileManager.trashItem(at: candidate, resultingItemURL: &trashed)
        try? fileManager.removeItem(at: staging)
        guard let result = trashed as URL? else {
            throw TagError.backupFailed(path: url.path, reason: "trash folder not available")
        }
        lock.withLock { folders[key] = result }
        return result
        #else
        // Ohne System-Papierkorb gibt es hier nur den XDG-Weg oben.
        throw TagError.backupFailed(path: url.path, reason: "no trash available")
        #endif
    }

    /// Kennung des Datenträgers — externe Platten brauchen ihren eigenen
    /// Papierkorb, sonst würde die Kopie quer über Datenträger geschrieben.
    private func volumeKey(for url: URL) -> String {
        // Der XDG-Weg rechnet mit Einhängepunkten (Linux-Foundation kennt
        // `volumeURLKey` nicht).
        if xdgTrash != nil { return XDGTrash.mountPoint(of: url).path }
        if let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
           let volume = values.volume {
            return volume.path
        }
        return "/"
    }

    private func sessionStamp() -> String {
        lock.withLock {
            if let stamp { return stamp }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            let value = formatter.string(from: Date())
            stamp = value
            return value
        }
    }

    /// Kopiert die Datei — auf APFS als Klon, der zunächst keine zusätzlichen
    /// Blöcke belegt und erst beim Ändern des Originals real wird.
    private static func clone(_ source: URL, to target: URL) throws {
        #if canImport(Darwin)
        if clonefile(source.path, target.path, 0) == 0 { return }
        #endif
        try FileManager.default.copyItem(at: source, to: target)
    }
}

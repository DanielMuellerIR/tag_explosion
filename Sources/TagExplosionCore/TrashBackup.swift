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
// belegt.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class TrashBackup: @unchecked Sendable {

    /// Gemeinsame Instanz — App, CLI und Core-Schreibwege teilen sich einen
    /// Sicherungsordner pro Sitzung.
    public static let shared = TrashBackup()

    /// Eigene Instanz mit eigenem Sicherungsordner. Tests benutzen sie, damit
    /// sie den gemeinsamen Zustand nicht anfassen müssen.
    public init() {}

    private let lock = NSLock()
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
    /// Kanonischer Dateipfad → Stand, der bereits gesichert ist.
    private var savedStates: [String: FileStamp] = [:]
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
    public func backUp(_ urls: [URL]) throws {
        guard isEnabled else { return }
        #if os(macOS)
        let fileManager = FileManager.default
        var pending: [(url: URL, state: FileStamp)] = []
        var seen: Set<String> = []

        for url in urls {
            let canonical = MediaFormats.canonicalFileURL(url)
            guard seen.insert(canonical.path).inserted,
                  fileManager.fileExists(atPath: canonical.path),
                  let state = FileStamp.current(of: canonical) else { continue }
            if lock.withLock({ savedStates[canonical.path] }) == state { continue }
            pending.append((canonical, state))
        }
        guard !pending.isEmpty else { return }

        // Platz prüfen, bevor die erste Kopie entsteht: eine halb geschriebene
        // Sicherung ist schlimmer als gar keine.
        for (url, _) in pending {
            try VolumeSpace.requireRoom(for: url)
        }

        for (url, state) in pending {
            do {
                let target = try destination(for: url)
                try clone(url, to: target)
                lock.withLock {
                    savedStates[url.path] = state
                    bytesWritten += state.size
                }
            } catch let error as TagError {
                throw error
            } catch {
                throw TagError.backupFailed(path: url.path,
                                            reason: error.localizedDescription)
            }
        }
        #else
        // Ohne Papierkorb (Linux) schützt nur der atomare Schreibweg. Das ist
        // eine bewusste Einschränkung, kein stiller Fehlschlag.
        throw TagError.backupFailed(path: urls.first?.path ?? "",
                                    reason: "trash is only available on macOS")
        #endif
    }

    /// Bequemer Einzelaufruf für die Schreibwege.
    public func backUp(_ url: URL) throws {
        try backUp([url])
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

    #if os(macOS)
    /// Legt den Sicherungsordner für den Datenträger dieser Datei an — einmal
    /// pro Sitzung. Der Ordner entsteht in einem Temp-Verzeichnis desselben
    /// Datenträgers und wandert sofort in dessen Papierkorb; danach wird er
    /// direkt weiterbefüllt.
    private func sessionFolder(for url: URL) throws -> URL {
        let fileManager = FileManager.default
        let key = volumeKey(for: url)
        if let existing = lock.withLock({ folders[key] }),
           fileManager.fileExists(atPath: existing.path) {
            return existing
        }

        let staging = try fileManager.url(for: .itemReplacementDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: url,
                                          create: true)
        let name = "\(folderLabel) \(sessionStamp())"
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
    }
    #else
    private func sessionFolder(for url: URL) throws -> URL {
        throw TagError.backupFailed(path: url.path, reason: "trash is only available on macOS")
    }
    #endif

    /// Kennung des Datenträgers — externe Platten brauchen ihren eigenen
    /// Papierkorb, sonst würde die Kopie quer über Datenträger geschrieben.
    private func volumeKey(for url: URL) -> String {
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
    private func clone(_ source: URL, to target: URL) throws {
        #if canImport(Darwin)
        if clonefile(source.path, target.path, 0) == 0 { return }
        #endif
        try FileManager.default.copyItem(at: source, to: target)
    }
}

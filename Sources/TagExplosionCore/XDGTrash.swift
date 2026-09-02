// Papierkorb nach der freedesktop.org-Trash-Spezifikation (Linux, BSD).
//
// macOS hat `FileManager.trashItem`; unter Linux gibt es keinen System-
// aufruf, der Papierkorb ist eine Verzeichnis-Konvention, die alle
// Dateimanager (Nautilus, Nemo, Dolphin, Thunar …) und `gio trash` teilen:
//
//   $XDG_DATA_HOME/Trash/files/<Name>            der Eintrag selbst
//   $XDG_DATA_HOME/Trash/info/<Name>.trashinfo   Herkunft und Löschzeit
//
// `$XDG_DATA_HOME` ist normalerweise `~/.local/share`. Für andere Daten-
// träger (externe Platte, zweite Partition) gilt derselbe Aufbau unter
// `<Einhängepunkt>/.Trash/<uid>/` (vom Admin angelegt, Sticky-Bit) oder
// `<Einhängepunkt>/.Trash-<uid>/` (legt der Nutzer selbst an). Die Kopie
// bleibt so immer auf dem Datenträger des Originals — derselbe Grundsatz
// wie beim macOS-Weg in `TrashBackup`.
//
// Der Typ ist auf allen Plattformen baubar und testbar: Er braucht nur ein
// Datenverzeichnis und rechnet mit Gerätenummern (st_dev), nicht mit
// Plattform-APIs. `TrashBackup` benutzt ihn außerhalb von macOS automatisch;
// Tests unter macOS geben ihm ein Temp-Verzeichnis als `dataHome`.
//
// Spezifikation: https://specifications.freedesktop.org/trash-spec/latest/
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct XDGTrash: Sendable {

    /// XDG-Datenverzeichnis, unter dem der Home-Papierkorb liegt
    /// (`$XDG_DATA_HOME`, sonst `~/.local/share`).
    public let dataHome: URL
    /// Benutzer-ID für die Papierkörbe fremder Datenträger (`.Trash-<uid>`).
    public let uid: UInt32

    public init(dataHome: URL? = nil, uid: UInt32 = UInt32(getuid())) {
        if let dataHome {
            self.dataHome = dataHome
        } else {
            let environment = ProcessInfo.processInfo.environment
            if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
                self.dataHome = URL(fileURLWithPath: xdg, isDirectory: true)
            } else {
                self.dataHome = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/share", isDirectory: true)
            }
        }
        self.uid = uid
    }

    /// Der Papierkorb des Benutzers für den Datenträger, auf dem sein
    /// Datenverzeichnis liegt.
    public var homeTrash: URL {
        dataHome.appendingPathComponent("Trash", isDirectory: true)
    }

    /// Welcher Papierkorb für eine Datei zuständig ist.
    public struct Location: Sendable, Equatable {
        /// Verzeichnis mit `files/` und `info/` darin.
        public var trashDirectory: URL
        /// Einhängepunkt des Datenträgers bei einem Datenträger-Papierkorb;
        /// nil beim Home-Papierkorb. Entscheidet, ob `Path` in der
        /// `.trashinfo` absolut oder relativ zum Einhängepunkt geschrieben wird
        /// (so verlangt es die Spezifikation).
        public var topDirectory: URL?
    }

    // MARK: - Papierkorb wählen

    /// Bestimmt den Papierkorb für `url` und legt `files/` und `info/` an,
    /// falls sie fehlen. Liegt die Datei auf demselben Datenträger wie das
    /// Datenverzeichnis, ist es der Home-Papierkorb; sonst der des
    /// Datenträgers. Wirft, wenn dort keiner angelegt werden kann — eine
    /// Kopie quer über Datenträger (auf die Systemplatte) gibt es bewusst
    /// nicht, sie könnte diese unbemerkt füllen.
    public func location(for url: URL) throws -> Location {
        let fileManager = FileManager.default
        let fileDevice = XDGTrash.deviceNumber(ofExistingAncestorOf: url)
        let homeDevice = XDGTrash.deviceNumber(ofExistingAncestorOf: dataHome)
        if fileDevice == nil || fileDevice == homeDevice {
            try prepare(trashDirectory: homeTrash, for: url)
            return Location(trashDirectory: homeTrash, topDirectory: nil)
        }

        let top = XDGTrash.mountPoint(of: url)
        // Variante 1: vom Administrator angelegtes `.Trash` mit Sticky-Bit,
        // darin ein Unterordner je Benutzer. Ein Symlink zählt nicht (Schutz
        // vor einem umgebogenen Papierkorb, so schreibt es die Spezifikation).
        let shared = top.appendingPathComponent(".Trash", isDirectory: true)
        if let attributes = try? fileManager.attributesOfItem(atPath: shared.path),
           attributes[.type] as? FileAttributeType == .typeDirectory,
           let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
           mode & 0o1000 != 0 {
            let mine = shared.appendingPathComponent(String(uid), isDirectory: true)
            if (try? prepare(trashDirectory: mine, for: url)) != nil {
                return Location(trashDirectory: mine, topDirectory: top)
            }
        }
        // Variante 2: eigener Papierkorb des Benutzers direkt im Einhängepunkt.
        let own = top.appendingPathComponent(".Trash-\(uid)", isDirectory: true)
        try prepare(trashDirectory: own, for: url)
        return Location(trashDirectory: own, topDirectory: top)
    }

    /// Legt `files/` und `info/` an (nur für den Benutzer lesbar, wie es
    /// Dateimanager auch tun).
    private func prepare(trashDirectory: URL, for url: URL) throws {
        let fileManager = FileManager.default
        for name in ["files", "info"] {
            let directory = trashDirectory.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            } catch {
                throw TagError.backupFailed(
                    path: url.path,
                    reason: "trash directory \(trashDirectory.path) is not writable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Eintrag anlegen

    /// Legt einen neuen, leeren Ordner im Papierkorb an, so als wäre er aus
    /// `originalParent` gelöscht worden. Die `.trashinfo` entsteht zuerst und
    /// exklusiv (`O_EXCL`) — so reserviert sie den Namen, ohne dass zwei
    /// Prozesse denselben wählen können. Ist der Name belegt, hängt die
    /// Methode „(2)", „(3)" … an. Rückgabe: der Ordner unter `files/`.
    public func createTrashedFolder(named name: String, originalParent: URL) throws -> URL {
        let location = try location(for: originalParent)
        let fileManager = FileManager.default
        let files = location.trashDirectory.appendingPathComponent("files", isDirectory: true)
        let info = location.trashDirectory.appendingPathComponent("info", isDirectory: true)

        var counter = 1
        while counter < 10_000 {
            let candidate = counter == 1 ? name : "\(name) (\(counter))"
            counter += 1
            let folder = files.appendingPathComponent(candidate, isDirectory: true)
            let infoFile = info.appendingPathComponent("\(candidate).trashinfo")
            guard !fileManager.fileExists(atPath: folder.path) else { continue }

            let descriptor = open(infoFile.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw TagError.backupFailed(
                    path: originalParent.path,
                    reason: "cannot create \(infoFile.path): \(String(cString: strerror(errno)))")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let original = originalParent.appendingPathComponent(candidate, isDirectory: true)
            let content = trashInfo(for: original, topDirectory: location.topDirectory)
            do {
                try handle.write(contentsOf: Data(content.utf8))
                try handle.close()
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch {
                try? fileManager.removeItem(at: infoFile)
                throw TagError.backupFailed(path: originalParent.path,
                                            reason: error.localizedDescription)
            }
            return folder
        }
        throw TagError.backupFailed(path: originalParent.path,
                                    reason: "no free name in trash for \(name)")
    }

    /// Inhalt der `.trashinfo`: Herkunftspfad (prozent-kodiert, beim
    /// Datenträger-Papierkorb relativ zum Einhängepunkt) und Löschzeit in
    /// Ortszeit ohne Zone — genau das Format, das Dateimanager zurücklesen.
    func trashInfo(for original: URL, topDirectory: URL?) -> String {
        var path = original.standardizedFileURL.path
        if let top = topDirectory {
            let prefix = top.standardizedFileURL.path == "/" ? "/" : top.standardizedFileURL.path + "/"
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return "[Trash Info]\nPath=\(XDGTrash.percentEncoded(path))\nDeletionDate=\(formatter.string(from: Date()))\n"
    }

    /// Prozent-Kodierung wie in RFC 2396 mit dem knappen Zeichenvorrat, den
    /// die Spezifikation erlaubt: ASCII-Buchstaben, Ziffern, `-._~` und `/`.
    /// Alles andere — Leerzeichen, Umlaute, Klammern — wird Byte für Byte
    /// (UTF-8) kodiert.
    static func percentEncoded(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    // MARK: - Datenträger

    /// Einhängepunkt des Datenträgers, auf dem `url` liegt: der oberste
    /// Vorfahr mit derselben Gerätenummer. Liegt der Pfad (noch) nicht auf
    /// der Platte, zählt der nächste existierende Vorfahr.
    public static func mountPoint(of url: URL) -> URL {
        var current = existingAncestor(of: url).standardizedFileURL
        guard var device = deviceNumber(of: current.path) else { return URL(fileURLWithPath: "/") }
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            guard let parentDevice = deviceNumber(of: parent.path) else { break }
            if parentDevice != device { return current }
            device = parentDevice
            current = parent
        }
        return current
    }

    /// Gerätenummer (st_dev) eines Pfads; nil, wenn er nicht lesbar ist.
    static func deviceNumber(of path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return (attributes[.systemNumber] as? NSNumber)?.uint64Value
    }

    static func deviceNumber(ofExistingAncestorOf url: URL) -> UInt64? {
        deviceNumber(of: existingAncestor(of: url).path)
    }

    /// Der Pfad selbst, wenn er existiert, sonst sein nächster vorhandener
    /// Vorfahr (das Datenverzeichnis existiert vor der ersten Sicherung oft
    /// noch nicht).
    private static func existingAncestor(of url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}

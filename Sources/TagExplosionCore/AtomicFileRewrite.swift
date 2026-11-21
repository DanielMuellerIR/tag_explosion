// Änderungen entstehen an einer Geschwisterkopie und ersetzen das Original
// erst nach erfolgreicher Prüfung.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AtomicFileRewrite {
    /// `expecting` trägt den beim Lesen erhobenen `FileStamp` bis zum
    /// Austausch, damit Änderungen anderer Programme erhalten bleiben.
    static func run(
        url: URL,
        expecting stamp: FileStamp? = nil,
        mutate: (URL) throws -> Void,
        validate: (URL) throws -> Void
    ) throws {
        try run(
            url: url, expecting: stamp, replacingOriginal: true,
            beforeReplace: {}, mutate: mutate, validate: validate)
    }

    /// Variante für Abläufe, die die fertig mutierte und geprüfte Kopie schon
    /// vor einer Sicherung oder einer Dry-run-Antwort brauchen. Bei
    /// `replacingOriginal == false` wird die geprüfte Kopie verworfen. Bei
    /// einem echten Austausch läuft `beforeReplace` erst nach der Prüfung;
    /// anschließend wird der Ausgangsstempel nochmals kontrolliert.
    static func run(
        url: URL,
        expecting stamp: FileStamp? = nil,
        replacingOriginal: Bool,
        beforeReplace: () throws -> Void,
        mutate: (URL) throws -> Void,
        validate: (URL) throws -> Void
    ) throws {
        let destination = MediaFormats.canonicalFileURL(url)
        let temp = siblingTempURL(for: destination)
        let fileManager = FileManager.default

        try FileStamp.requireUnchanged(stamp, at: destination)
        try requireWritable(destination, reportedAt: url)

        // Die Kopie braucht Platz. Auf Dateisystemen mit Copy-on-Write (APFS)
        // kostet sie zunächst nichts, sonst die volle Dateigröße.
        try VolumeSpace.requireRoom(for: destination)

        try withWriteError(at: url) {
            try fileManager.copyItem(at: destination, to: temp)
        }
        defer { try? fileManager.removeItem(at: temp) }

        try withWriteError(at: url) {
            try mutate(temp)
            try validate(temp)
        }

        try FileStamp.requireUnchanged(stamp, at: destination)
        guard replacingOriginal else { return }
        try synchronize(temp, reportedAt: url)

        // Eine Sicherung gehört hinter Mutation und Prüfung: Ein vom Backend
        // normalisierter, also nicht exakt wiederherstellbarer Archivwert darf
        // weder im Dry-run als anwendbar gelten noch eine unnötige Sicherung
        // erzeugen. Der Hook arbeitet noch vor dem atomaren Austausch.
        try beforeReplace()
        try requireWritable(destination, reportedAt: url)
        try FileStamp.requireUnchanged(stamp, at: destination)

        // Beide Pfade liegen im selben Verzeichnis. POSIX rename ersetzt
        // das Ziel in genau einem atomaren Dateisystem-Schritt.
        guard rename(temp.path, destination.path) == 0 else {
            throw systemWriteError(at: url, code: errno)
        }
    }

    /// Legt eine NEUE Datei an, die es noch nicht gibt (etwa eine erste
    /// XMP-Sidecar): `mutate` erzeugt die Geschwister-Temp-Datei selbst,
    /// `validate` prüft sie, danach wird sie per `link` exklusiv auf den
    /// Zielnamen gesetzt. `link` scheitert atomar, wenn inzwischen ein
    /// anderes Programm dieselbe Datei angelegt hat — eine bloße
    /// `fileExists`-Prüfung vorher ließe dieses Zeitfenster offen. Bei
    /// `replacingOriginal == false` (Dry-run) wird die geprüfte Temp-Datei
    /// verworfen.
    static func create(
        url: URL,
        replacingOriginal: Bool,
        allowStreamingBackup: Bool = false,
        linkFile: (String, String) -> Int32 = { link($0, $1) },
        beforeReplace: () throws -> Void,
        mutate: (URL) throws -> Void,
        validate: (URL) throws -> Void
    ) throws {
        let destination = MediaFormats.canonicalFileURL(url)
        let temp = siblingTempURL(for: destination)
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temp) }

        try withWriteError(at: url) {
            try mutate(temp)
            try validate(temp)
        }
        guard replacingOriginal else { return }
        try synchronize(temp, reportedAt: url)

        try beforeReplace()
        guard linkFile(temp.path, destination.path) == 0 else {
            let code = errno
            // Linux meldet fehlende Hardlinks (etwa exFAT) auch als EPERM.
            // open prüft die Schreibrechte erneut und bleibt exklusiv.
            if allowStreamingBackup && (code == ENOTSUP || code == EOPNOTSUPP || code == EPERM) {
                try createExclusiveBackup(from: temp, at: destination)
                return
            }
            // EEXIST: Jemand anderes hat die Datei gerade angelegt — dessen
            // Stand bleibt unangetastet, der Aufrufer liest neu.
            if code == EEXIST {
                throw TagError.fileChangedOnDisk(path: url.path)
            }
            throw systemWriteError(at: url, code: code)
        }
    }

    // Nur automatische Archive dürfen auf Dateisystemen ohne Hardlinks direkt
    // exklusiv angelegt werden. Der Batch beginnt erst nach vollständigem Write
    // und fsync; keine leere Datei läuft durch TrashBackup oder das Journal.
    static func createExclusiveBackup(from source: URL, at destination: URL) throws {
        let sourceFD = open(source.path, O_RDONLY | O_CLOEXEC)
        guard sourceFD >= 0 else { throw systemWriteError(at: destination, code: errno) }
        defer { close(sourceFD) }

        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw TagError.fileChangedOnDisk(path: destination.path) }
            throw systemWriteError(at: destination, code: errno)
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var own = stat()
        guard fstat(fd, &own) == 0 else {
            throw systemWriteError(at: destination, code: errno)
        }
        var complete = false
        defer {
            if !complete {
                var current = stat()
                if lstat(destination.path, &current) == 0
                    && current.st_dev == own.st_dev && current.st_ino == own.st_ino {
                    unlink(destination.path)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: 1024 * 1024)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            let start = buffer.baseAddress!
            while true {
                let count = read(sourceFD, start, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw systemWriteError(at: destination, code: errno) }
                if count == 0 { break }

                var offset = 0
                while offset < count {
                    let written = write(fd, start.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else {
                        throw systemWriteError(at: destination, code: written == 0 ? EIO : errno)
                    }
                    offset += written
                }
            }
        }
        try withWriteError(at: destination) {
            try output.synchronize()
            try output.close()
        }
        complete = true
    }

    private static func requireWritable(_ destination: URL, reportedAt url: URL) throws {
        let attributes = try withWriteError(at: url) {
            try FileManager.default.attributesOfItem(atPath: destination.path)
        }
        let permissions = attributes[.posixPermissions] as? NSNumber
        let immutable = attributes[.immutable] as? NSNumber
        let appendOnly = attributes[.appendOnly] as? NSNumber
        if permissions.map({ $0.intValue & 0o222 == 0 }) == true
            || immutable?.boolValue == true || appendOnly?.boolValue == true {
            throw TagError.readOnly(path: url.path)
        }
        guard faccessat(AT_FDCWD, destination.path, W_OK, AT_EACCESS) == 0 else {
            let code = errno
            if code == EACCES || code == EPERM || code == EROFS {
                throw TagError.readOnly(path: url.path)
            }
            throw systemWriteError(at: url, code: code)
        }
    }

    private static func synchronize(_ temporary: URL, reportedAt url: URL) throws {
        // Schreibfehler der Kopie melden, solange das Original noch existiert.
        // Der atomare Austausch selbst ist keine Stromausfallgarantie.
        try withWriteError(at: url) {
            let file = try FileHandle(forWritingTo: temporary)
            try file.synchronize()
            try file.close()
        }
    }

    static func systemWriteError(at url: URL, code: Int32) -> TagError {
        let reason = String(cString: strerror(code))
        return .fileSystemWriteFailed(path: url.path, reason: "\(reason) (errno \(code))")
    }

    private static func withWriteError<T>(at url: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as TagError {
            throw error
        } catch {
            let reported = error as NSError
            let underlying = reported.userInfo[NSUnderlyingErrorKey] as? NSError ?? reported
            if underlying.domain == NSPOSIXErrorDomain, let code = Int32(exactly: underlying.code) {
                throw systemWriteError(at: url, code: code)
            }
            let reason = underlying.localizedFailureReason ?? underlying.localizedDescription
            throw TagError.fileSystemWriteFailed(path: url.path, reason: reason)
        }
    }

    private static func siblingTempURL(for url: URL) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var name = ".\(stem).tagx-\(UUID().uuidString)"
        if !ext.isEmpty { name += ".\(ext)" }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
}

/// Platzpruefung vor jeder Kopie. Ohne sie endet ein voller Datentraeger
/// mitten im Schreibvorgang — genau der Fall, den der atomare Rahmen
/// verhindern soll.
enum VolumeSpace {

    /// Reserve fuer Dateisystem-Metadaten, damit die Kopie nicht am
    /// allerletzten Block scheitert.
    static let margin: Int64 = 8 * 1024 * 1024

    /// Wirft `notEnoughSpace`, wenn eine Kopie der Datei nicht mehr sicher
    /// auf ihren eigenen Datentraeger passt. Kann der Datentraeger klonen
    /// (APFS), belegt die Kopie anfangs keine zusaetzlichen Bloecke.
    static func requireRoom(for url: URL, extraFiles: [URL] = []) throws {
        try requireRoom(for: url, bytes: requiredBytes(for: [url] + extraFiles))
    }

    static func requireRoom(for url: URL, bytes needed: Int64) throws {
        guard needed > 0 else { return }
        guard let free = availableBytes(at: url) else { return }
        guard free >= margin, needed <= free - margin else {
            throw TagError.notEnoughSpace(path: url.path, needBytes: needed, freeBytes: free)
        }
    }

    /// Wie viele Bytes eine Kopie der Dateien tatsaechlich kostet.
    static func requiredBytes(for urls: [URL]) throws -> Int64 {
        guard let first = urls.first, !supportsCloning(at: first) else { return 0 }
        return urls.reduce(into: Int64(0)) { total, url in
            total += fileSize(of: url) ?? 0
        }
    }

    static func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func availableBytes(at url: URL) -> Int64? {
        let directory = url.deletingLastPathComponent()
        #if !canImport(Darwin)
        // Linux-Foundation kennt die Volume-Schluessel von `resourceValues`
        // nicht; `attributesOfFileSystem` (statvfs) liefert den freien Platz.
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else { return nil }
        return free
        #else
        guard let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        // "Important usage" ist ein APFS-Konzept (kennt purgeable Space).
        // Nicht-APFS-Volumes (HFS+, FAT, DMGs) melden hier 0, obwohl Platz
        // frei ist — 0 heisst deshalb "nicht unterstuetzt", nicht "voll",
        // sonst schluege JEDER Schreibvorgang auf solchen Datentraegern fehl.
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return Int64(important)
        }
        return values.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// APFS klont Dateien blockweise (Copy-on-Write) — die Kopie kostet dann
    /// erst Platz, wenn sich eine der beiden Seiten aendert.
    static func supportsCloning(at url: URL) -> Bool {
        #if canImport(Darwin)
        let directory = url.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [.volumeSupportsFileCloningKey])
        return values?.volumeSupportsFileCloning ?? false
        #else
        return false
        #endif
    }
}

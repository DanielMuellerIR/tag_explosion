// Export bereits erzeugter Bytes. Das Ziel wurde vom Aufrufer gewählt;
// bestehende Dateien dürfen ersetzt werden, Fehler werden weitergereicht.
import Foundation

public enum FileExport {
    /// Legt ein neues Exportziel exklusiv an. Anders als `write` gibt es hier
    /// keinen alten Benutzerstand, der in den Papierkorb gehoert.
    public static func create(_ data: Data, at url: URL) throws {
        let target = MediaFormats.canonicalFileURL(url)
        let mutate: (URL) throws -> Void = { try data.write(to: $0) }
        let validate: (URL) throws -> Void = { temporary in
            guard try Data(contentsOf: temporary) == data else {
                throw TagError.saveFailed(path: url.path)
            }
        }
        try AtomicFileRewrite.create(url: target, replacingOriginal: true,
                                     beforeReplace: {}, mutate: mutate,
                                     validate: validate)
    }

    /// Erst eine geprüfte Geschwisterdatei erzeugen, dann das bestätigte Ziel
    /// ersetzen. Eine inzwischen angelegte oder geänderte Datei bleibt erhalten.
    public static func write(_ data: Data, to url: URL, backup: TrashBackup = .shared) throws {
        let target = MediaFormats.canonicalFileURL(url)
        let stamp = FileStamp.current(of: target)
        let mutate: (URL) throws -> Void = { try data.write(to: $0) }
        let validate: (URL) throws -> Void = { temporary in
            guard try Data(contentsOf: temporary) == data else {
                throw TagError.saveFailed(path: url.path)
            }
        }
        if let stamp {
            try AtomicFileRewrite.run(url: target, expecting: stamp, replacingOriginal: true,
                                      beforeReplace: { try backup.backUp(target) },
                                      mutate: mutate, validate: validate)
        } else {
            try create(data, at: target)
        }
    }
}

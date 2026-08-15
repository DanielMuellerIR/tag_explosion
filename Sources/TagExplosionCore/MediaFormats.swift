// Zentrale Format-/Endungslisten des Cores. App und CLI leiten ihre
// Dateierkennung hieraus ab, damit nichts auseinanderdriftet.
import EInvoiceCore
import Foundation

public enum MediaFormats {

    /// Audio-Endungen (deckt die TagLib-Formate ab).
    public static let audio: Set<String> = [
        "mp3", "m4a", "m4b", "m4r", "mp4", "aac",
        "flac", "ogg", "oga", "opus", "spx",
        "wav", "aiff", "aif", "wv", "ape", "mpc",
        "tta", "dsf", "dff", "wma", "asf",
    ]

    /// Bild-Endungen (Metadaten via exiftool).
    public static let image: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "dng", "gif",
    ]

    /// Video-Endungen. Tags via TagLib (mp4/m4v/mkv/webm); Rest nur anzeigen.
    public static let video: Set<String> = [
        "m4v", "mkv", "webm", "mov", "avi",
    ]

    /// E-Book-Endungen: epub/pdf immer; mobi/azw3/fb2 nur mit Calibre
    /// (einmalige Prüfung pro Prozess).
    public static let ebook: Set<String> = {
        var extensions = EbookTool.builtinExtensions
        if EbookTool.calibreAvailable {
            extensions.formUnion(EbookTool.calibreExtensions)
        }
        return extensions
    }()

    /// E-Rechnungs-Endungen (nur Anzeige). PDFs mit eingebetteter Rechnung
    /// laufen weiter als E-Book — dort ergänzt die Anzeige den Rechnungsteil.
    public static let invoice: Set<String> = ["xml"]

    /// Grobe Medienart — bestimmt Lese-/Schreibweg. Video läuft über den
    /// TagLib-Weg wie Audio (PropertyMap).
    public enum Kind: String, Sendable, Codable {
        case audio
        case image
        case ebook
        /// E-Rechnung (XML) — reine Anzeige, kein Schreibweg.
        case invoice
    }

    /// Kann diese Medienart in ein Tag-Archiv (Export/Import)? E-Rechnungen
    /// sind reine Anzeige — es gibt keine editierbaren Tags zu sichern.
    /// Die Regel liegt zentral, damit App und CLI gleich filtern und ihre
    /// Erfolgsmeldungen dieselben Dateien zählen wie das Archiv selbst.
    public static func isArchivable(_ kind: Kind) -> Bool {
        kind != .invoice
    }

    public static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if audio.contains(ext) { return .audio }
        if image.contains(ext) { return .image }
        if ebook.contains(ext) { return .ebook }
        if video.contains(ext) { return .audio }
        // XML nur annehmen, wenn der Inhalt tatsächlich eine E-Rechnung ist —
        // sonst zöge ein Ordner-Drop beliebige Fremd-XMLs in die Liste.
        if invoice.contains(ext), isInvoiceXML(url) { return .invoice }
        return nil
    }

    /// Schneller Inhaltstest: Wurzelelement/Namensräume stehen am Dateianfang,
    /// mehr als 8 KB muss dafür niemand lesen.
    private static func isInvoiceXML(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8192) else { return false }
        return EInvoiceReader.sniffXML(head)
    }

    /// Liefert die Identität, unter der die App dieselbe Datei wiedererkennt.
    /// `standardizedFileURL` räumt `.` und `..` auf, `resolvingSymlinksInPath`
    /// führt anschließend auch einen Finder-Alias/Unix-Symlink auf sein Ziel
    /// zurück. So erzeugen zwei Wege zu derselben Datei keinen zweiten Editor.
    public static func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Verzeichnisse mit einer Medien-Endung sind keine Medien-Dateien. Diese
    /// Prüfung liegt bewusst zentral, damit App, CLI und Archiv gleich filtern.
    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Verzeichnisse rekursiv auflösen, nur Medien-Dateien behalten, sortiert
    /// (Finder-artig, stabil).
    public static func expandMediaFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        var seen: Set<URL> = []
        let fm = FileManager.default
        for url in urls {
            let canonical = canonicalFileURL(url)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: canonical.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let iterator = fm.enumerator(
                    at: canonical,
                    includingPropertiesForKeys: [.isRegularFileKey]
                ) {
                    for case let child as URL in iterator {
                        let childCanonical = canonicalFileURL(child)
                        if isRegularFile(childCanonical), kind(of: childCanonical) != nil,
                           seen.insert(childCanonical).inserted {
                            files.append(childCanonical)
                        }
                    }
                }
            } else if isRegularFile(canonical), kind(of: canonical) != nil,
                      seen.insert(canonical).inserted {
                files.append(canonical)
            }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

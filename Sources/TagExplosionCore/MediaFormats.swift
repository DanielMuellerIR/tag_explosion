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

    /// Bild-Endungen (Metadaten via exiftool). Enthält auch die Kamera-RAW-
    /// Endungen, die nur über eine XMP-Sidecar-Datei beschrieben werden, die
    /// Sidecar-Endung selbst (`xmp`, ein „Bild ohne Pixel") und Formate, die
    /// exiftool nur lesen kann (`bmp`, `svg`; siehe `imageEmbeddedReadOnly`).
    public static let image: Set<String> = Set([
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "dng", "gif", "avif", "jxl", "bmp", "psd", "svg",
        xmpSidecarExtension,
    ]).union(rawImage)

    /// Kamera-RAW-Endungen. Diese Dateien werden NIE direkt beschrieben:
    /// Änderungen gehen in die XMP-Sidecar-Datei `<name>.xmp` daneben — so
    /// wie Lightroom und Bridge es tun. Ein RAW ist das unveränderliche
    /// „Negativ"; ein Schreibfehler darin wäre nicht wiedergutzumachen.
    public static let rawImage: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef",
    ]

    /// Bild-Endungen, in die exiftool KEINE Metadaten schreiben kann (Stand
    /// exiftool 13.55, geprüft per `exiftool -listwf`; ein Test hält die
    /// Liste gegen die installierte Version). Änderungen an solchen Dateien
    /// landen ebenfalls in der Sidecar-Datei.
    public static let imageEmbeddedReadOnly: Set<String> = ["bmp", "svg"]

    /// Endung der XMP-Sidecar-Datei. Eine `.xmp` lässt sich auch alleine
    /// öffnen und bearbeiten (gleiche Felder wie ein Bild, nur ohne Pixel).
    public static let xmpSidecarExtension = "xmp"

    /// Ist die Datei ein Kamera-RAW (Schreiben nur über Sidecar)?
    public static func isRawImage(_ url: URL) -> Bool {
        rawImage.contains(url.pathExtension.lowercased())
    }

    /// Ist die Datei selbst eine XMP-Sidecar-Datei?
    public static func isXMPSidecar(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == xmpSidecarExtension
    }

    /// Pfad der XMP-Sidecar-Datei zu einem Bild: gleicher Ordner, gleicher
    /// Name, Endung `.xmp` (Lightroom-/Bridge-Konvention). Für eine `.xmp`
    /// selbst ist das die Datei selbst. Achtung: `foto.cr2` und `foto.jpg`
    /// im selben Ordner teilen sich dieselbe Sidecar — auch das entspricht
    /// den Adobe-Werkzeugen.
    public static func sidecarURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(xmpSidecarExtension)
    }

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

    /// Schneller Inhaltstest: Der Rechnungs-Core liest den XML-Stream nur bis
    /// zum ersten Start-Element und prüft dessen aufgelösten Namensraum.
    private static func isInvoiceXML(_ url: URL) -> Bool {
        EInvoiceReader.sniffXML(url: url)
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
        return hidingSidecars(of: files).sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// Entfernt `.xmp`-Dateien, deren Bild ebenfalls in der Liste steht: Die
    /// Sidecar wird über ihr Bild angezeigt und bearbeitet; als zweiter
    /// Eintrag könnte sie mit dem Bild-Editor um dieselbe Datei konkurrieren.
    /// Eine `.xmp` ohne Bild daneben bleibt als eigener Eintrag erhalten.
    static func hidingSidecars(of files: [URL]) -> [URL] {
        var sidecarOwners: Set<URL> = []
        for file in files where !isXMPSidecar(file) && image.contains(file.pathExtension.lowercased()) {
            sidecarOwners.insert(sidecarURL(for: file))
        }
        return files.filter { !isXMPSidecar($0) || !sidecarOwners.contains($0) }
    }
}

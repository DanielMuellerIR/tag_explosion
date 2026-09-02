// Zentrale Format-/Endungslisten des Cores. App und CLI leiten ihre
// Dateierkennung hieraus ab, damit nichts auseinanderdriftet.
import EInvoiceCore
import Foundation

public enum MediaFormats {

    /// Tracker-Module (ProTracker `mod`, Scream Tracker 3 `s3m`, FastTracker II
    /// `xm`, Impulse Tracker `it`). TagLib liest sie, kennt aber nur Titel,
    /// Kommentar (= die Sample-/Instrumentnamen, eine Zeile je Name) und den
    /// Tracker-Namen — siehe `writableTagKeys(for:)`. Kein Cover-Speicherort.
    public static let tracker: Set<String> = ["mod", "s3m", "xm", "it"]

    /// Endungen, für die TagLib keinen Leser hat: Sun/NeXT-Audio `au` und
    /// Ogg-Video `ogv` (Theora/VP8 plus Vorbis in einem Ogg-Strom; TagLibs
    /// Ogg-Leser kennt nur reine Audio-Ströme). Sie öffnen nur zur Anzeige
    /// über mediainfo, ein Tag-Schreibweg fehlt.
    public static let displayOnly: Set<String> = ["au", "ogv"]

    /// Audio-Endungen (deckt die TagLib-Formate ab; `au` nur Anzeige).
    public static let audio: Set<String> = Set([
        "mp3", "mp2", "m4a", "m4b", "m4r", "mp4", "aac",
        "flac", "ogg", "oga", "opus", "spx",
        "wav", "aiff", "aif", "aifc", "wv", "ape", "mpc",
        "tta", "dsf", "dff", "wma", "asf", "mka", "au",
    ]).union(tracker)

    /// Bild-Endungen (Metadaten via exiftool).
    public static let image: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "dng", "gif",
    ]

    /// Video-Endungen. Tags via TagLib (mp4/m4v/3gp/3g2/mkv/webm); Rest nur
    /// anzeigen. 3gp/3g2 sind MP4-Container mit eigenem `ftyp`-Brand, die
    /// TagLib am Inhalt erkennt.
    public static let video: Set<String> = [
        "m4v", "mkv", "webm", "mov", "avi", "3gp", "3g2", "ogv",
    ]

    /// Tag-Schlüssel, die Tracker-Module speichern können. Alle anderen Felder
    /// weist TagLib beim Schreiben zurück (`TagError.propertiesRejected`); die
    /// Datei bleibt dann unverändert.
    public static let trackerTagKeys: Set<String> = ["TITLE", "COMMENT", "TRACKERNAME"]

    /// Welche Tag-Schlüssel kann diese Datei aufnehmen? `nil` heißt: keine
    /// Einschränkung (Formate mit PropertyMap-Vollabdeckung). Die App sperrt
    /// damit im Editor die Felder, die das Format ohnehin ablehnen würde.
    public static func writableTagKeys(for url: URL) -> Set<String>? {
        tracker.contains(url.pathExtension.lowercased()) ? trackerTagKeys : nil
    }

    /// Kann die Datei ein Cover einbetten? Tracker-Module haben keinen
    /// Speicherort dafür; Matroska (mkv/mka/webm) schreibt TagLib zwar ohne
    /// Fehler, liest das Bild aber nicht wieder — der Schreibweg würde die
    /// Prüfung nach dem Schreiben scheitern lassen. Anzeige-Formate ebenso.
    public static func supportsEmbeddedArtwork(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !tracker.contains(ext) && !displayOnly.contains(ext)
            && !["mkv", "mka", "webm"].contains(ext)
    }

    /// Darf das Öffnen ohne TagLib-Leser trotzdem gelingen (schreibgeschützt,
    /// nur Technik-Anzeige)? Gilt für Video-Container (AVI, manche MOV) und
    /// die reinen Anzeige-Formate.
    public static func toleratesMissingTagReader(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return video.contains(ext) || displayOnly.contains(ext)
    }

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
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

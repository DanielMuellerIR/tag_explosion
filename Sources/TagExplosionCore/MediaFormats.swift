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

    /// Dokument-Endungen: Office (docx/xlsx/pptx), OpenDocument (odt/ods/odp),
    /// Comic-Archive (cbz) und Markdown mit Frontmatter — alle nativ, ohne
    /// externe Programme (siehe DocumentTool).
    public static let document: Set<String> = DocumentTool.extensions

    /// Video-Sidecars: Kodi-/Jellyfin-NFO (`nfo`) und Untertitel (`srt`,
    /// `vtt`). Eine `.nfo` zählt nur, wenn ihr Inhalt eine NFO ist (XML mit
    /// bekannter Wurzel oder Nur-URL) — Szene-Textdateien heißen auch so.
    public static let sidecar: Set<String> = SidecarTool.extensions

    /// Video-Endungen, neben denen `<name>.nfo` als Sidecar gilt. `mp4`
    /// steht in `audio` (TagLib-Weg), gehört hier aber dazu.
    public static let nfoVideo: Set<String> = video.union(["mp4"])
    /// Playlist-Endungen: Cue-Sheets und Playlists (m3u, m3u8, pls, xspf) —
    /// nativ gelesen und beschriftet (PlaylistTool).
    public static let playlist: Set<String> = PlaylistTool.extensions

    /// Grobe Medienart — bestimmt Lese-/Schreibweg. Video läuft über den
    /// TagLib-Weg wie Audio (PropertyMap).
    public enum Kind: String, Sendable, Codable {
        case audio
        case image
        case ebook
        /// E-Rechnung (XML) — reine Anzeige, kein Schreibweg.
        case invoice
        /// Office, OpenDocument, Comic-Archiv, Markdown (DocumentTool).
        case document
        /// Video-Sidecars: NFO (editierbar) und Untertitel (SidecarTool).
        case sidecar
        /// Cue-Sheet oder Playlist (PlaylistTool): Beschriftung editierbar,
        /// Einträge selbst nicht.
        case playlist
    }

    /// Kann diese Medienart in ein Tag-Archiv (Export/Import)? E-Rechnungen
    /// sind reine Anzeige — es gibt keine editierbaren Tags zu sichern.
    /// Playlists beschreiben fremde Dateien statt eigener Tags; ein Archiv
    /// könnte ihre Einträge nicht sinnvoll wiederherstellen.
    /// Die Regel liegt zentral, damit App und CLI gleich filtern und ihre
    /// Erfolgsmeldungen dieselben Dateien zählen wie das Archiv selbst.
    /// Sidecars: nur NFO-Felder; Untertitel und Nur-URL-NFOs bleiben
    /// draußen — dafür gibt es `isArchivable(url:)`.
    public static func isArchivable(_ kind: Kind) -> Bool {
        kind != .invoice && kind != .playlist
    }

    /// Dateibezogene Variante: entscheidet bei Sidecars nach Endung und
    /// Inhalt (Untertitel und Nur-URL-NFOs tragen keine archivierbaren Felder).
    public static func isArchivable(url: URL) -> Bool {
        guard let kind = kind(of: url) else { return false }
        guard kind == .sidecar else { return isArchivable(kind) }
        guard SidecarTool.isNFO(url) else { return false }
        return (try? KodiNFOFile.read(url: url).isURLOnly) == false
    }

    public static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if audio.contains(ext) { return .audio }
        if image.contains(ext) { return .image }
        if ebook.contains(ext) { return .ebook }
        if video.contains(ext) { return .audio }
        if document.contains(ext) { return .document }
        if sidecar.contains(ext) {
            // `.nfo` nur mit passendem Inhalt (siehe `sidecar`).
            if ext == SidecarTool.nfoExtension { return KodiNFOFile.sniff(url: url) ? .sidecar : nil }
            return .sidecar
        }
        if playlist.contains(ext) { return .playlist }
        // XML nur annehmen, wenn der Inhalt tatsächlich eine E-Rechnung ist —
        // sonst zöge ein Ordner-Drop beliebige Fremd-XMLs in die Liste.
        if invoice.contains(ext), isInvoiceXML(url) { return .invoice }
        return nil
    }

    /// Pfad der NFO-Sidecar zu einer Videodatei (`film.mkv` → `film.nfo`);
    /// nil, wenn die Datei kein Video ist oder keine NFO daneben liegt.
    public static func nfoURL(forVideo url: URL) -> URL? {
        guard nfoVideo.contains(url.pathExtension.lowercased()) else { return nil }
        let candidate = url.deletingPathExtension().appendingPathExtension(SidecarTool.nfoExtension)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Das Video zu einer NFO (`film.nfo` → `film.mkv`, erste gefundene
    /// Video-Endung); nil, wenn keines daneben liegt. `tvshow.nfo` hat
    /// bauartbedingt keines.
    public static func videoURL(forNFO url: URL) -> URL? {
        guard SidecarTool.isNFO(url) else { return nil }
        let stem = url.deletingPathExtension()
        for ext in nfoVideo.sorted() {
            let candidate = stem.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
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
    /// Gleiche Regel für `.nfo` neben einem gelisteten Video: Der
    /// Video-Editor zeigt den NFO-Abschnitt. Untertitel bleiben eigene
    /// Einträge (sie teilen sich meist nicht einmal den Namen: `film.de.srt`).
    static func hidingSidecars(of files: [URL]) -> [URL] {
        var sidecarOwners: Set<URL> = []
        var nfoOwners: Set<URL> = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            if !isXMPSidecar(file), image.contains(ext) {
                sidecarOwners.insert(sidecarURL(for: file))
            }
            if nfoVideo.contains(ext) {
                nfoOwners.insert(file.deletingPathExtension().appendingPathExtension(SidecarTool.nfoExtension))
            }
        }
        return files.filter {
            if isXMPSidecar($0) { return !sidecarOwners.contains($0) }
            if SidecarTool.isNFO($0) { return !nfoOwners.contains($0) }
            return true
        }
    }
}

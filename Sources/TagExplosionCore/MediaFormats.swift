// Zentrale Format-/Endungslisten des Cores. App und CLI leiten ihre
// Dateierkennung hieraus ab, damit nichts auseinanderdriftet.
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

    /// Grobe Medienart — bestimmt Lese-/Schreibweg. Video läuft über den
    /// TagLib-Weg wie Audio (PropertyMap).
    public enum Kind: String, Sendable, Codable {
        case audio
        case image
        case ebook
    }

    public static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if audio.contains(ext) { return .audio }
        if image.contains(ext) { return .image }
        if ebook.contains(ext) { return .ebook }
        if video.contains(ext) { return .audio }
        return nil
    }

    /// Verzeichnisse rekursiv auflösen, nur Medien-Dateien behalten, sortiert
    /// (Finder-artig, stabil).
    public static func expandMediaFiles(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let child as URL in iterator {
                        if kind(of: child) != nil {
                            files.append(child)
                        }
                    }
                }
            } else if kind(of: url) != nil {
                files.append(url)
            }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

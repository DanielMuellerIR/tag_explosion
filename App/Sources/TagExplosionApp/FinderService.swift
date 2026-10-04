import AppKit

@MainActor
enum FinderService {
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.filter { $0.isFileURL && $0.path.hasPrefix("/") }
        }
        // Finder und ältere Dienst-Clients können mehrere Pfade als Liste
        // übergeben. Text und Netzwerk-URLs sind keine Datei-Auswahl.
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}

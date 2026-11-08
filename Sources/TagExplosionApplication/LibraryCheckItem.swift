import Foundation
import TagExplosionCore

extension FileEntry {
    /// Prüf-Item aus dem Bearbeitungspuffer: Geprüft wird, was gerade in den
    /// Feldern steht (wie die Vorschau beim Umbenennen). nil = Medienart wird
    /// nicht geprüft (Rechnung, Playlist, NFO/Untertitel) oder Container ohne
    /// Tag-Leser.
    public var libraryCheckItem: LibraryCheck.Item? {
        switch kind {
        case .audio:
            guard !isReadOnly else { return nil }
            let embeds = MediaFormats.supportsEmbeddedArtwork(url)
            return LibraryCheck.Item(
                url: url, kind: .audio, properties: properties,
                covers: embeds ? artworks.map(LibraryCheck.CoverSummary.init) : nil,
                durationMilliseconds: audio?.lengthMilliseconds,
                title: firstValue("TITLE"), patternFields: patternFields)
        case .image:
            return LibraryCheck.Item(url: url, image: imageFields)
        case .ebook:
            // Ein im Puffer gewähltes neues Cover zählt schon als vorhanden.
            let hasCover = (ebookCoverReplacement ?? ebookOriginalCover) != nil
            return LibraryCheck.Item(url: url, ebook: ebookFields,
                                     hasCover: EbookTool.supportsCover(url: url) ? hasCover : nil)
        case .document:
            return LibraryCheck.Item(url: url, document: documentFields)
        case .invoice, .playlist, .sidecar:
            return nil
        }
    }
}

extension AppModel {
    /// Führt die Prüfung über die Puffer der Einträge aus (rein lesend).
    public func libraryCheckReport(for targets: [FileEntry], pattern: FilenamePattern?) -> LibraryCheck.Report {
        LibraryCheck.run(targets.compactMap(\.libraryCheckItem), pattern: pattern)
    }
}

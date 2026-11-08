import Foundation
import TagExplosionCore

public enum FileListSort: String, CaseIterable {
    case input, filename, title, artist
    public var title: String {
        switch self {
        case .input: String(localized: "Öffnungsreihenfolge")
        case .filename: String(localized: "Dateiname")
        case .title: String(localized: "Titel")
        case .artist: String(localized: "Interpret")
        }
    }
}

extension FileEntry {
    /// Formatgerechter Interpret bzw. Autor; unabhängig davon, ob das Format
    /// Dateinamenmuster unterstützt. Audio-Sortierung nutzt den ersten Wert.
    public var listArtist: String {
        switch kind {
        case .audio: return firstValue("ARTIST")
        case .image: return imageFields.creator
        case .ebook: return ebookFields.authors.joined(separator: ", ")
        case .document: return documentFields.authors.joined(separator: ", ")
        case .playlist: return playlistFields.performer
        case .sidecar:
            if case .nfo = sidecarContents { return nfoFields.directors.joined(separator: ", ") }
            return ""
        case .invoice: return ""
        }
    }
}

extension AppModel {
    /// Filter ändern nur die Ansicht; Auswahl und Bearbeitungspuffer bleiben erhalten.
    private var filteredEntries: [FileEntry] {
        let query = listSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, listKind == nil, !listDirtyOnly, !listErrorsOnly { return entries }
        return entries.filter { entry in
            if let listKind, entry.kind != listKind { return false }
            if listDirtyOnly && !entry.isDirty { return false }
            if listErrorsOnly && entry.lastError == nil { return false }
            guard !query.isEmpty else { return true }
            if entry.url.lastPathComponent.localizedStandardContains(query)
                || entry.metadataTitle.localizedStandardContains(query) { return true }
            // Gesucht wird auch in weiteren ARTIST-Werten, nicht nur im ersten.
            let artists = entry.kind == .audio
                ? entry.properties.filter { $0.key == "ARTIST" }.map(\.value).joined(separator: "\n")
                : entry.listArtist
            return artists.localizedStandardContains(query)
        }
    }

    public var visibleEntries: [FileEntry] {
        let matching = filteredEntries
        guard listSort != .input else { return matching }
        // Den Schlüssel einmal je Eintrag bilden, nicht bei jedem Vergleich.
        let keyed = matching.enumerated().map { index, entry in
            let value: String
            switch listSort {
            case .input: value = ""
            case .filename: value = entry.url.lastPathComponent
            case .title: value = entry.metadataTitle
            case .artist: value = entry.listArtist
            }
            return (index: index, entry: entry, value: value)
        }
        return keyed.sorted {
            let order = $0.value.localizedStandardCompare($1.value)
            return order == .orderedSame ? $0.index < $1.index : order == .orderedAscending
        }.map(\.entry)
    }

    public var hiddenSelectionCount: Int {
        selection.subtracting(Set(filteredEntries.map(\.url))).count
    }

    /// SwiftUI bekommt nur sichtbare IDs; eine neue sichtbare Auswahl darf
    /// ausgeblendete IDs nicht versehentlich aus der Modellauswahl entfernen.
    public var visibleSelection: Set<URL> {
        get { selection.intersection(Set(filteredEntries.map(\.url))) }
        set {
            let visible = Set(filteredEntries.map(\.url))
            selection = selection.subtracting(visible).union(newValue.intersection(visible))
        }
    }

    public func selectKindWithinSelection(_ kind: MediaKind) {
        selection = Set(selectedEntries.filter { $0.kind == kind }.map(\.url))
    }
}

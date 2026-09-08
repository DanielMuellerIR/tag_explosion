import Foundation
import SwiftUI
import TagExplosionCore

enum FileListSort: String, CaseIterable {
    case input, filename, title, artist
    var title: String {
        switch self {
        case .input: String(localized: "Öffnungsreihenfolge")
        case .filename: String(localized: "Dateiname")
        case .title: String(localized: "Titel")
        case .artist: String(localized: "Interpret")
        }
    }
}

private extension FileEntry {
    /// Formatgerechter Interpret bzw. Autor; unabhängig davon, ob das Format
    /// Dateinamenmuster unterstützt. Audio-Sortierung nutzt den ersten Wert.
    var listArtist: String {
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

    var visibleEntries: [FileEntry] {
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

    var hiddenSelectionCount: Int {
        selection.subtracting(Set(filteredEntries.map(\.url))).count
    }

    /// SwiftUI bekommt nur sichtbare IDs; eine neue sichtbare Auswahl darf
    /// ausgeblendete IDs nicht versehentlich aus der Modellauswahl entfernen.
    var visibleSelection: Set<URL> {
        get { selection.intersection(Set(filteredEntries.map(\.url))) }
        set {
            let visible = Set(filteredEntries.map(\.url))
            selection = selection.subtracting(visible).union(newValue.intersection(visible))
        }
    }

    func selectKindWithinSelection(_ kind: MediaKind) {
        selection = Set(selectedEntries.filter { $0.kind == kind }.map(\.url))
    }
}

struct FileListControls: View {
    @Environment(AppModel.self) private var model
    private let kinds: [MediaKind] = [.audio, .image, .ebook, .document, .invoice, .playlist, .sidecar]
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            TextField("Dateiname, Titel oder Interpret", text: $model.listSearch)
                .textFieldStyle(.roundedBorder)
            HStack {
                Picker("Medienart", selection: $model.listKind) {
                    Text("Alle Medienarten").tag(nil as MediaKind?)
                    ForEach(kinds, id: \.self) { kind in
                        Text(RuleLabels.kind(kind)).tag(Optional(kind))
                    }
                }.labelsHidden()
                Picker("Sortierung", selection: $model.listSort) {
                    ForEach(FileListSort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                }.labelsHidden()
            }
            HStack {
                Toggle("Ungespeichert", isOn: $model.listDirtyOnly)
                Toggle("Fehler", isOn: $model.listErrorsOnly)
            }.toggleStyle(.checkbox)
            Text("\(model.selection.count) ausgewählt · \(model.hiddenSelectionCount) ausgeblendet")
                .font(.caption)
            if Set(model.selectedEntries.map(\.kind)).count > 1 {
                Menu("Auswahl auf Medienart begrenzen") {
                    ForEach(kinds, id: \.self) { kind in
                        Button(RuleLabels.kind(kind)) { model.selectKindWithinSelection(kind) }
                    }
                }
            }
        }.padding(8)
    }
}

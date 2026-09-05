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

extension AppModel {
    /// Filter ändern nur die Ansicht; Auswahl und Bearbeitungspuffer bleiben erhalten.
    var visibleEntries: [FileEntry] {
        let query = listSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = entries.enumerated().filter { _, entry in
            if let listKind, entry.kind != listKind { return false }
            if listDirtyOnly && !entry.isDirty { return false }
            if listErrorsOnly && entry.lastError == nil { return false }
            let fields = entry.patternFields
            let artists = entry.kind == .audio
                ? entry.properties.filter { $0.key == "ARTIST" }.map(\.value).joined(separator: "\n")
                : fields["ARTIST"] ?? ""
            return query.isEmpty || [entry.url.lastPathComponent, fields["TITLE"] ?? "", artists]
                .contains { $0.localizedStandardContains(query) }
        }
        return matching.sorted { lhs, rhs in
            @MainActor func value(_ entry: FileEntry) -> String {
                switch listSort {
                case .input: return ""
                case .filename: return entry.url.lastPathComponent
                case .title: return entry.patternFields["TITLE"] ?? ""
                case .artist: return entry.patternFields["ARTIST"] ?? ""
                }
            }
            let order = value(lhs.element).localizedStandardCompare(value(rhs.element))
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    var hiddenSelectionCount: Int {
        selection.subtracting(Set(visibleEntries.map(\.url))).count
    }

    /// SwiftUI bekommt nur sichtbare IDs; eine neue sichtbare Auswahl darf
    /// ausgeblendete IDs nicht versehentlich aus der Modellauswahl entfernen.
    var visibleSelection: Set<URL> {
        get { selection.intersection(Set(visibleEntries.map(\.url))) }
        set {
            let visible = Set(visibleEntries.map(\.url))
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

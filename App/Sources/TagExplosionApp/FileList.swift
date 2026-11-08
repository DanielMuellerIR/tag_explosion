import Foundation
import SwiftUI
import TagExplosionCore
import TagExplosionApplication

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

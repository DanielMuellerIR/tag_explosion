import SwiftUI
import TagExplosionApplication

struct BatchEditorLayout<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(.background)
    }
}

struct BatchSelectionSummary: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    let entries: [FileEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.semibold))
            Text(hint).font(.caption).foregroundStyle(.secondary)
            let dirtyCount = entries.filter(\.isDirty).count
            if dirtyCount > 0 {
                Label("\(dirtyCount) mit ungespeicherten Änderungen", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct BatchRuleActions: View {
    let entries: [FileEntry]

    var body: some View {
        HStack(spacing: 12) {
            FilenamePatternMenu(entries: entries)
            TagRulesButton(entries: entries)
        }
        .padding(.top, 4)
    }
}

struct BatchFileGrid<Columns: View>: View {
    let title: LocalizedStringKey
    let entries: [FileEntry]
    @ViewBuilder let columns: (FileEntry) -> Columns

    var body: some View {
        GroupBox(title) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        columns(entry)
                        if entry.isDirty {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

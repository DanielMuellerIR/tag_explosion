// Batch-Editor für E-Books: setzt Autor(en)/Serie/Verlag/Sprache/Schlagwörter/
// Datum für alle ausgewählten Bücher (Titel und Beschreibung bleiben bewusst
// Einzel-Editor-Sache — die sind pro Buch individuell).
import SwiftUI
import TagExplosionCore

struct EbookBatchEditorView: View {
    let entries: [FileEntry]

    /// Serie nur anbieten, wenn alle ausgewählten Formate sie speichern können
    /// (PDF kann nicht).
    private var allSupportSeries: Bool {
        entries.allSatisfy { EbookTool.supportsSeries(url: $0.url) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                fieldsSection
                ArchiveButtons(entries: entries)
                fileListSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entries.count) E-Books ausgewählt")
                .font(.title3.weight(.semibold))
            Text("Änderungen wirken auf alle ausgewählten Bücher.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let dirtyCount = entries.filter(\.isDirty).count
            if dirtyCount > 0 {
                Label("\(dirtyCount) mit ungespeicherten Änderungen", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var fieldsSection: some View {
        GroupBox("Metadaten (für alle setzen)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    GridFieldLabel("Autor(en)")
                    BatchFieldTextField(
                        entries: entries,
                        get: { $0.ebookFields.authors.joined(separator: ", ") },
                        set: { entry, value in entry.ebookFields.authors = value.splitCommaList() })
                }
                if allSupportSeries {
                    GridRow {
                        GridFieldLabel("Serie")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.ebookFields.series },
                            set: { entry, value in entry.ebookFields.series = value })
                    }
                } else {
                    GridRow {
                        GridFieldLabel("Serie")
                        Text("Nicht verfügbar — PDF in der Auswahl")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                GridRow {
                    GridFieldLabel("Verlag")
                    BatchFieldTextField(
                        entries: entries,
                        get: { $0.ebookFields.publisher },
                        set: { entry, value in entry.ebookFields.publisher = value })
                }
                GridRow {
                    GridFieldLabel("Sprache")
                    BatchFieldTextField(
                        entries: entries,
                        get: { $0.ebookFields.language },
                        set: { entry, value in entry.ebookFields.language = value })
                }
                GridRow {
                    GridFieldLabel("Datum")
                    BatchFieldTextField(
                        entries: entries,
                        get: { $0.ebookFields.date },
                        set: { entry, value in entry.ebookFields.date = value })
                }
                GridRow {
                    GridFieldLabel("Schlagwörter")
                    BatchFieldTextField(
                        entries: entries,
                        get: { $0.ebookFields.subjects.joined(separator: ", ") },
                        set: { entry, value in entry.ebookFields.subjects = value.splitCommaList() })
                }
            }
            .padding(8)
        }
    }

    private var fileListSection: some View {
        GroupBox("Ausgewählte E-Books") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.url.lastPathComponent)
                            .lineLimit(1)
                        Text(entry.ebookFields.authors.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

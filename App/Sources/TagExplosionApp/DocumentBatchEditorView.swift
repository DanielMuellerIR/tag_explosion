// Batch-Editor für Dokumente: setzt Autor(en)/Thema/Schlagwörter/Verlag/
// Sprache/Kategorie für alle ausgewählten Dateien (Titel, Beschreibung und
// Daten bleiben bewusst Einzel-Editor-Sache). Ein Feld erscheint nur, wenn
// ALLE ausgewählten Formate es speichern können — sonst würde ein Save für
// einen Teil der Auswahl scheitern.
import SwiftUI
import TagExplosionApplication
import TagExplosionCore

struct DocumentBatchEditorView: View {
    let entries: [FileEntry]

    /// Felder, die jedes ausgewählte Format speichern kann.
    private var commonFields: Set<DocumentField> {
        entries.map { DocumentTool.supportedFields(url: $0.url) }
            .reduce(Set(DocumentField.allCases)) { $0.intersection($1) }
    }

    var body: some View {
        BatchEditorLayout {
            header
            fieldsSection
            ArchiveButtons(entries: entries)
            fileListSection
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            BatchSelectionSummary(title: "\(entries.count) Dokumente ausgewählt",
                                  hint: "Änderungen wirken auf alle ausgewählten Dokumente. Gezeigt werden nur Felder, die jedes Format speichern kann.",
                                  entries: entries)
            BatchRuleActions(entries: entries)
        }
    }

    private var fieldsSection: some View {
        let common = commonFields
        return GroupBox("Metadaten (für alle setzen)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if common.contains(.authors) {
                    GridRow {
                        GridFieldLabel("Autor(en)")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.authors.joined(separator: ", ") },
                            set: { entry, value in entry.documentFields.authors = value.splitCommaList() })
                    }
                }
                if common.contains(.subject) {
                    GridRow {
                        GridFieldLabel("Thema")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.subject },
                            set: { entry, value in entry.documentFields.subject = value })
                    }
                }
                if common.contains(.keywords) {
                    GridRow {
                        GridFieldLabel("Schlagwörter")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.keywords.joined(separator: ", ") },
                            set: { entry, value in entry.documentFields.keywords = value.splitCommaList() })
                    }
                }
                if common.contains(.publisher) {
                    GridRow {
                        GridFieldLabel("Verlag")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.publisher },
                            set: { entry, value in entry.documentFields.publisher = value })
                    }
                }
                if common.contains(.language) {
                    GridRow {
                        GridFieldLabel("Sprache")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.language },
                            set: { entry, value in entry.documentFields.language = value })
                    }
                }
                if common.contains(.category) {
                    GridRow {
                        GridFieldLabel("Kategorie")
                        BatchFieldTextField(
                            entries: entries,
                            get: { $0.documentFields.category },
                            set: { entry, value in entry.documentFields.category = value })
                    }
                }
                if common.isDisjoint(with: [.authors, .subject, .keywords, .publisher, .language, .category]) {
                    Text("Die ausgewählten Formate haben kein gemeinsames Stapel-Feld.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .gridCellColumns(2)
                }
            }
            .padding(8)
        }
    }

    private var fileListSection: some View {
        BatchFileGrid(title: "Ausgewählte Dokumente", entries: entries) { entry in
            Text(entry.url.lastPathComponent)
                .lineLimit(1)
            Text(entry.documentFields.authors.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

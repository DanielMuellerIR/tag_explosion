// Abschnitt „NFO-Sidecar" im Video-Editor: Liegt `<name>.nfo` neben der
// Videodatei, erscheinen hier die wichtigsten Felder (Titel, Jahr, Handlung,
// Genres) mit Herkunft. Der Puffer liegt im `FileEntry` (`videoNFOFields`),
// nicht in der View: So zählen NFO-Änderungen zu `isDirty`, und der
// Schließ-/Beenden-Guard fragt nach, statt sie still zu verwerfen.
// Gespeichert wird mit dem Eintrag (⌘S): Nur die NFO wird geschrieben, wenn
// sich am Video nichts geändert hat; Stempelprüfung, Papierkorb-Sicherung
// und atomarer Austausch liegen in `AppModel.write`.
import SwiftUI
import TagExplosionCore

struct NFOSidecarSection: View {
    @Bindable var entry: FileEntry

    var body: some View {
        if let nfo = entry.videoNFO {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Aus \(nfo.url.lastPathComponent) — Speichern schreibt die NFO, das Video nur bei eigenen Änderungen."),
                          systemImage: "doc.badge.gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let error = nfo.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    if let contents = nfo.contents, contents.isURLOnly {
                        Text("Nur-URL-NFO: enthält nur Scraper-Adressen und wird nicht beschrieben.")
                            .foregroundStyle(.secondary)
                        ForEach(contents.urls, id: \.self) { url in
                            Text(url).font(.body.monospaced()).textSelection(.enabled)
                        }
                    } else if nfo.isEditable {
                        fieldGrid
                    }
                }
                .padding(8)
            } label: {
                Text("NFO-Sidecar")
            }
        }
    }

    private var fieldGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                GridFieldLabel("Titel")
                TextField("", text: $entry.videoNFOFields.title).textFieldStyle(.roundedBorder)
            }
            GridRow {
                GridFieldLabel("Jahr")
                TextField("JJJJ", text: $entry.videoNFOFields.year)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 100)
            }
            GridRow {
                GridFieldLabel("Handlung")
                TextField("", text: $entry.videoNFOFields.plot, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                GridFieldLabel("Genres")
                TextField("kommagetrennt", text: Binding(
                    get: { entry.videoNFOFields.genres.joined(separator: ", ") },
                    set: { entry.videoNFOFields.genres = $0.splitCommaList() }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

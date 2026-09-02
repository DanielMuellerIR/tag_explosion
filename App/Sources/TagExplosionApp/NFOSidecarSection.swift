// Abschnitt „NFO-Sidecar" im Video-Editor: Liegt `<name>.nfo` neben der
// Videodatei, erscheinen hier die wichtigsten Felder (Titel, Jahr, Handlung,
// Genres) mit Herkunft. Gespeichert wird ausschließlich in die NFO — mit
// eigenem Knopf, unabhängig vom Speichern der Video-Tags: Der Abschnitt hat
// seinen eigenen Lesestand und Dateistempel (Konfliktschutz), die Sicherung
// läuft über TrashBackup, der Austausch über AtomicFileRewrite im Core.
import SwiftUI
import TagExplosionCore

struct NFOSidecarSection: View {
    let videoURL: URL

    @State private var nfoURL: URL?
    @State private var contents: NFOContents?
    @State private var original = NFOFields()
    @State private var fields = NFOFields()
    @State private var stamp: FileStamp?
    @State private var error: String?
    @State private var isSaving = false

    private var isDirty: Bool { fields != original }

    var body: some View {
        Group {
            if let nfoURL, let contents {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(String(localized: "Aus \(nfoURL.lastPathComponent) — Speichern schreibt nur die NFO, nicht das Video."),
                              systemImage: "doc.badge.gearshape")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                        if contents.isURLOnly {
                            Text("Nur-URL-NFO: enthält nur Scraper-Adressen und wird nicht beschrieben.")
                                .foregroundStyle(.secondary)
                            ForEach(contents.urls, id: \.self) { url in
                                Text(url).font(.body.monospaced()).textSelection(.enabled)
                            }
                        } else {
                            fieldGrid
                            HStack {
                                Button("In NFO speichern") { save() }
                                    .disabled(!isDirty || isSaving)
                                Button("Zurücksetzen") { fields = original; error = nil }
                                    .disabled(!isDirty || isSaving)
                                Spacer()
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Text("NFO-Sidecar")
                }
            }
        }
        .task(id: videoURL) { await load() }
    }

    private var fieldGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                GridFieldLabel("Titel")
                TextField("", text: $fields.title).textFieldStyle(.roundedBorder)
            }
            GridRow {
                GridFieldLabel("Jahr")
                TextField("JJJJ", text: $fields.year)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: 100)
            }
            GridRow {
                GridFieldLabel("Handlung")
                TextField("", text: $fields.plot, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                GridFieldLabel("Genres")
                TextField("kommagetrennt", text: Binding(
                    get: { fields.genres.joined(separator: ", ") },
                    set: { fields.genres = $0.splitCommaList() }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    /// Lesen im Hintergrund; ohne NFO daneben bleibt der Abschnitt leer.
    private func load() async {
        guard let url = MediaFormats.nfoURL(forVideo: videoURL) else {
            nfoURL = nil
            contents = nil
            return
        }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try KodiNFOFile.readSnapshot(url: url)
            }.value
            nfoURL = url
            accept(snapshot)
        } catch {
            nfoURL = url
            contents = nil
            self.error = error.localizedDescription
        }
    }

    private func accept(_ snapshot: FileSnapshot<NFOContents>) {
        contents = snapshot.value
        original = snapshot.value.fields
        fields = snapshot.value.fields
        stamp = snapshot.stamp
        error = nil
    }

    /// Schreibweg wie im Core-CLI: Stempel prüfen, Papierkorb-Sicherung,
    /// atomar schreiben, neu lesen. Der Puffer bleibt bei Fehlern erhalten.
    private func save() {
        guard let url = nfoURL, !isSaving else { return }
        let target = fields
        let base = original
        let expected = stamp
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try KodiNFOFile.validate(target, original: base)
                    try FileStamp.requireUnchanged(expected, at: url)
                    try TrashBackup.shared.backUp(url)
                    try KodiNFOFile.write(url: url, fields: target, original: base, expecting: expected)
                    return try KodiNFOFile.readSnapshot(url: url)
                }.value
                // Weitergetippte Änderungen während des Schreibens behalten.
                let typed = fields
                accept(snapshot)
                if typed != target { fields = typed }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

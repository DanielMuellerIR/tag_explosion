import TagExplosionApplication
// Cover-Werkzeuge in der App (AP12): Info-Zeile unter dem Cover (Maße,
// Format, Größe, Prüfhinweise) und das Zahnrad-/Kontextmenü mit Verkleinern,
// JPEG-Wandlung, Metadaten entfernen, Ordner-Cover übernehmen und Export als
// folder.jpg. Die Umwandlungen ändern nur den Bearbeitungspuffer
// (`entry.artworks`); gespeichert wird über den gewohnten Weg mit
// Papierkorb-Sicherung und atomarem Austausch. Nur der Export schreibt sofort
// eine Datei — über `FolderCover.export`, das dieselben Regeln einhält.
import AppKit
import SwiftUI
import TagExplosionCore

/// Info-Zeile unter dem Cover: "JPEG · 500×500 px · 48 KB", darunter die
/// Prüfhinweise in Orange.
struct CoverInfoLine: View {
    let artwork: Artwork
    /// Weitere eingebettete Bilder (Booklet etc.), nur als Zähler.
    var extraCount = 0

    var body: some View {
        let analysis = CoverTools.analyze(artwork.data)
        VStack(spacing: 2) {
            Text(analysis.summary + (extraCount > 0 ? " · " + String(localized: "+\(extraCount) weitere") : ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if !analysis.issues.isEmpty {
                Label(analysis.issues.map { CoverToolActions.issueText($0.code) }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 180)
        .help(analysis.issues.map(\.message).joined(separator: "\n"))
    }
}

/// Menüeinträge der Cover-Werkzeuge — im Kontextmenü des Covers und im
/// Zahnrad-Menü darunter identisch. Für eine Datei oder für die Batch-Auswahl.
struct CoverToolsMenuItems: View {
    @Environment(AppModel.self) private var model
    let entries: [FileEntry]

    private var hasAnyCover: Bool { entries.contains { $0.frontCover != nil } }
    private var sharedCover: Artwork? { CoverToolActions.sharedCover(of: entries) }
    private var folderCoverAvailable: Bool {
        entries.contains { FolderCover.find(in: $0.url.deletingLastPathComponent()) != nil }
    }

    var body: some View {
        Menu("Verkleinern auf …") {
            ForEach(CoverToolActions.shrinkSizes, id: \.self) { size in
                Button("\(size) px") {
                    run(String(localized: "Cover verkleinern"),
                        CoverToolActions.convert(entries, .init(maxPixelSize: size)))
                }
            }
        }
        .disabled(!hasAnyCover)
        Button("Nach JPEG wandeln") {
            run(String(localized: "Nach JPEG wandeln"),
                CoverToolActions.convert(entries, .init(format: .jpeg)))
        }
        .disabled(!hasAnyCover)
        Button("Bild-Metadaten entfernen") {
            run(String(localized: "Bild-Metadaten entfernen"),
                CoverToolActions.convert(entries, .init(stripMetadata: true)))
        }
        .disabled(!hasAnyCover)
        Divider()
        Button("Ordner-Cover übernehmen") {
            run(String(localized: "Ordner-Cover übernehmen"), CoverToolActions.applyFolderCover(entries))
        }
        .disabled(!folderCoverAvailable)
        .help("folder.jpg, cover.jpg oder front.jpg (auch .png) neben der Datei als Cover setzen")
        Button(exportLabel) { exportToFolder() }
            .disabled(sharedCover == nil)
            .help("Das eingebettete Cover neben die Datei schreiben; vorhandene Datei nur nach Rückfrage ersetzen")
    }

    private var exportLabel: String {
        let name = sharedCover.flatMap(FolderCover.exportFileName) ?? "folder.jpg"
        return String(localized: "Als \(name) exportieren")
    }

    private func run(_ action: String, _ outcome: CoverToolActions.Outcome) {
        if let message = CoverToolActions.report(outcome, action: action) {
            model.alertMessage = message
        }
    }

    /// Export ins Verzeichnis des ersten Eintrags. Existiert die Datei schon,
    /// fragt ein Dialog; „Ersetzen" sichert die alte Datei in den Papierkorb.
    private func exportToFolder() {
        guard let cover = sharedCover, let entry = entries.first else { return }
        let directory = entry.url.deletingLastPathComponent()
        do {
            try FolderCover.export(cover, to: directory)
        } catch CoverToolError.targetExists(let path) {
            let alert = NSAlert()
            alert.messageText = String(localized: "\(URL(fileURLWithPath: path).lastPathComponent) existiert bereits in diesem Ordner.")
            alert.informativeText = String(localized: "Die vorhandene Datei wird vorher in den Papierkorb kopiert, sofern der abgesicherte Modus aktiv ist.")
            alert.addButton(withTitle: String(localized: "Ersetzen"))
            alert.addButton(withTitle: String(localized: "Abbrechen"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try FolderCover.export(cover, to: directory, force: true)
            } catch {
                model.alertMessage = String(localized: "Export fehlgeschlagen:") + "\n" + error.localizedDescription
            }
        } catch {
            model.alertMessage = String(localized: "Export fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }
}

/// Zahnrad-Knopf mit den Cover-Werkzeugen (neben der Info-Zeile).
struct CoverToolsButton: View {
    let entries: [FileEntry]

    var body: some View {
        Menu {
            CoverToolsMenuItems(entries: entries)
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cover-Werkzeuge")
        .accessibilityLabel("Cover-Werkzeuge")
    }
}

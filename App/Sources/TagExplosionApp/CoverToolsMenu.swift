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

/// Die eigentlichen Aktionen, getrennt von der View, damit sie ohne Fenster
/// testbar sind. Alle Funktionen wirken auf das erste Bild jedes Eintrags.
@MainActor
enum CoverToolActions {
    /// Verkleinerungsstufen im Menü.
    static let shrinkSizes = [500, 1000, 1500]

    /// Ergebnis einer Aktion über mehrere Einträge.
    struct Outcome: Equatable {
        var changed = 0
        var unchanged = 0
        /// Einträge ohne Cover bzw. ohne Ordner-Cover.
        var skipped = 0
        var errors: [String] = []
    }

    /// Wendet eine Umwandlung auf das Cover jedes Eintrags an. Einträge ohne
    /// Cover werden übersprungen; ein Fehler bei einer Datei stoppt die
    /// anderen nicht.
    static func convert(_ entries: [FileEntry], _ conversion: CoverTools.Conversion) -> Outcome {
        var outcome = Outcome()
        for entry in entries {
            guard let cover = entry.artworks.first else { outcome.skipped += 1; continue }
            do {
                let converted = try CoverTools.convert(cover, conversion)
                if converted.data == cover.data {
                    outcome.unchanged += 1
                } else {
                    entry.artworks[0] = converted
                    outcome.changed += 1
                }
            } catch {
                outcome.errors.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// Ordner-Cover (folder/cover/front .jpg/.png neben der Datei) als Cover
    /// übernehmen. Jeder Eintrag sucht in seinem eigenen Verzeichnis.
    static func applyFolderCover(_ entries: [FileEntry]) -> Outcome {
        var outcome = Outcome()
        // Je Verzeichnis nur einmal lesen.
        var cache: [URL: Artwork?] = [:]
        for entry in entries {
            let directory = entry.url.deletingLastPathComponent()
            let artwork: Artwork?
            if let cached = cache[directory] {
                artwork = cached
            } else {
                do {
                    artwork = try FolderCover.load(in: directory)
                } catch {
                    outcome.errors.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                    cache[directory] = .some(nil)
                    continue
                }
                cache[directory] = artwork
            }
            guard let artwork else { outcome.skipped += 1; continue }
            if entry.artworks.first?.data == artwork.data {
                outcome.unchanged += 1
            } else if entry.artworks.isEmpty {
                entry.artworks = [artwork]
                outcome.changed += 1
            } else {
                entry.artworks[0] = artwork
                outcome.changed += 1
            }
        }
        return outcome
    }

    /// Gemeinsames Cover der Einträge (erstes Bild, bei allen byteidentisch);
    /// nil bei Unterschieden oder ohne Cover.
    static func sharedCover(of entries: [FileEntry]) -> Artwork? {
        guard let first = entries.first?.artworks.first else { return nil }
        return entries.allSatisfy { $0.artworks.first?.data == first.data } ? first : nil
    }

    /// Lesbare Zusammenfassung für die Hinweisbox; nil, wenn nichts zu melden ist.
    static func report(_ outcome: Outcome, action: String) -> String? {
        var lines: [String] = []
        if outcome.skipped > 0 {
            lines.append(String(localized: "\(outcome.skipped) Datei(en) übersprungen (kein Cover bzw. kein Ordner-Cover gefunden)."))
        }
        lines.append(contentsOf: outcome.errors)
        guard !lines.isEmpty else { return nil }
        return action + "\n" + lines.joined(separator: "\n")
    }

    /// Lokalisierter Text zu einem Prüfcode (die Core-Texte sind englisch).
    static func issueText(_ code: CoverIssueCode) -> String {
        switch code {
        case .tooSmall: return String(localized: "zu klein (unter \(CoverTools.minimumEdge) px)")
        case .tooLarge: return String(localized: "zu groß (über \(CoverTools.maximumEdge) px)")
        case .tooManyBytes: return String(localized: "zu groß (über 2 MiB)")
        case .notSquare: return String(localized: "nicht quadratisch")
        case .progressiveJPEG: return String(localized: "progressives JPEG (manche Player zeigen es nicht)")
        case .cmyk: return String(localized: "CMYK (viele Player können das nicht)")
        case .unknownFormat: return String(localized: "Bildformat nicht lesbar")
        }
    }
}

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

    private var hasAnyCover: Bool { entries.contains { !$0.artworks.isEmpty } }
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

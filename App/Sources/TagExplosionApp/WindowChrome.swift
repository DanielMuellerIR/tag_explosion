// Was im Fensterkopf steht und welche Datei das Fenster vertritt — als reine
// Umwandlung, damit die Regeln ohne Fenster prüfbar bleiben.
import SwiftUI

/// Anzeigedaten einer geladenen Datei, soweit der Fensterkopf sie braucht.
struct WindowChromeEntry: Equatable {
    var title: String
    var url: URL
    var isDirty: Bool
    var isSaving: Bool
}

/// Titel, Untertitel und vertretene Datei eines Fensters.
struct WindowChrome: Equatable {
    var title: String
    var subtitle: String
    /// Datei, die das Fenster vertritt. AppKit macht daraus das Datei-Icon in
    /// der Titelleiste und das Pfadmenü bei Command-Klick auf den Titel.
    /// Nur bei genau einer ausgewählten Datei gesetzt — bei mehreren gäbe es
    /// keine eindeutige Datei, auf die sich das Menü beziehen könnte.
    var documentURL: URL?

    /// - Parameter selected: die ausgewählten Dateien in Listenreihenfolge
    /// - Parameter totalCount: Anzahl aller im Fenster geladenen Dateien
    static func make(selected: [WindowChromeEntry], totalCount: Int) -> WindowChrome {
        if selected.count == 1, let entry = selected.first {
            let fileName = entry.url.lastPathComponent
            var parts: [String] = []
            // Der Titel ist meist der Tag-Titel („4D Write Pro Neues Dokument")
            // und sagt nichts über die Datei. Deshalb steht der Dateiname
            // daneben — außer er wäre dieselbe Zeile zweimal.
            if fileName != entry.title { parts.append(fileName) }
            if entry.isSaving {
                parts.append(String(localized: "Speichert …"))
            } else if entry.isDirty {
                parts.append(String(localized: "Bearbeitet"))
            }
            return WindowChrome(title: entry.title,
                                subtitle: parts.joined(separator: " · "),
                                documentURL: entry.url)
        }

        if selected.count > 1 {
            let dirty = selected.filter(\.isDirty).count
            return WindowChrome(
                title: String(localized: "\(selected.count) Dateien"),
                subtitle: dirty > 0 ? String(localized: "\(dirty) bearbeitet") : "",
                documentURL: nil)
        }

        return WindowChrome(
            title: "Tag Explosion",
            subtitle: totalCount == 0 ? "" : String(localized: "\(totalCount) Dateien"),
            documentURL: nil)
    }
}

/// Grundeinstellung der Seitenleiste. Bei einer einzelnen Datei sagt die Liste
/// nichts, was der Editor nicht schon zeigt — sie kostet nur Breite, die gerade
/// die E-Rechnungs-Ansicht gut gebrauchen kann.
enum SidebarRule {
    static func visibility(fileCount: Int) -> NavigationSplitViewVisibility {
        fileCount > 1 ? .all : .detailOnly
    }
}

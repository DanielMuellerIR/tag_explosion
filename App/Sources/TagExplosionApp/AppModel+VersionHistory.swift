// Undo-Historie im App-Modell: eine Papierkorb-Sicherung zurückspielen und
// den Eintrag danach neu von der Platte lesen (siehe BackupHistory im Core).
import AppKit
import SwiftUI
import TagExplosionCore

extension AppModel {

    /// Spielt `version` auf ihren Originalpfad zurück und liest die Datei neu.
    ///
    /// Läuft wie ein Speichern: Während des Austauschs gilt der Eintrag als
    /// "speichert" (kein zweiter Schreibzugriff), der Plattenstempel schützt
    /// vor fremden Änderungen seit dem Öffnen, und der jetzige Stand wandert
    /// vorher in den Papierkorb (Auslöser `restore`). Ungespeicherte Änderungen
    /// im Puffer werden durch den neu gelesenen Stand ersetzt — die Rückfrage
    /// dazu stellt die View.
    @discardableResult
    func restoreVersion(_ version: BackupVersion, for entry: FileEntry) async -> Bool {
        guard !entry.isSaving, !isDestructiveActionLocked else { return false }
        entry.isSaving = true
        defer { entry.finishSaving() }
        let url = entry.url
        let kind = entry.kind
        // Der Stempel gehört zur Datei des Eintrags. Bei Bildern kann die
        // Version zur XMP-Sidecar gehören — dann gibt es keinen bekannten
        // Ausgangsstand, und der Core prüft nur die Kopie selbst.
        let target = MediaFormats.canonicalFileURL(url).path
        let stamp = version.entry.originalPath == target ? entry.diskStamp : nil
        do {
            let (loaded, newStamp) = try await Task.detached(priority: .userInitiated) {
                try BackupHistory.restore(version, expecting: stamp)
                return try Self.readStamped(url: url, kind: kind)
            }.value
            entry.acceptNew(loaded, stamp: newStamp)
            entry.lastError = nil
            return true
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Version wiederherstellen fehlgeschlagen: \(entry.url.lastPathComponent)")
                + "\n" + error.localizedDescription
            return false
        }
    }

    /// Menübefehl „Letzte Änderung rückgängig" (⌘⇧Z): jüngste Sicherung der
    /// ausgewählten Datei zurückspielen — nach Rückfrage, weil dabei auch
    /// ungespeicherte Änderungen im Editor ersetzt werden.
    func undoLastChangeOfSelection() async {
        guard let entry = selectedEntry, !entry.isSaving, !isDestructiveActionLocked else { return }
        guard let latest = BackupHistory.versions(of: entry.url).first else {
            alertMessage = String(localized: "Keine Sicherung im Papierkorb für \(entry.url.lastPathComponent)")
            return
        }
        guard Self.confirmRestore(of: latest, for: entry) else { return }
        await restoreVersion(latest, for: entry)
    }

    /// Rückfrage vor dem Zurückspielen; nennt Zeit und Auslöser der Version.
    static func confirmRestore(of version: BackupVersion, for entry: FileEntry) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Version wiederherstellen?")
        var text = String(localized: "„\(entry.url.lastPathComponent)“ wird auf den Stand vom \(VersionHistoryFormat.date(version.entry.date)) zurückgesetzt (\(VersionHistoryFormat.reason(version.entry.reason))). Der jetzige Stand wird vorher in den Papierkorb kopiert.")
        if entry.isDirty {
            text += "\n\n" + String(localized: "Ungespeicherte Änderungen im Editor gehen dabei verloren.")
        }
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Wiederherstellen"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Anzeigeformen für die Historie (Zeit, Auslöser, Größe) — App-weit gleich.
enum VersionHistoryFormat {
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Auslöser in Worten; unbekannte Werte (spätere Versionen, Skripte)
    /// erscheinen unverändert.
    static func reason(_ reason: String) -> String {
        switch reason {
        case BackupReason.save: return String(localized: "Speichern")
        case BackupReason.tags: return String(localized: "Tags")
        case BackupReason.cover: return String(localized: "Cover")
        case BackupReason.chapters: return String(localized: "Kapitel")
        case BackupReason.layers: return String(localized: "Tag-Schicht")
        case BackupReason.import: return String(localized: "Import")
        case BackupReason.rename: return String(localized: "Umbenennen")
        case BackupReason.sidecar: return String(localized: "Sidecar")
        case BackupReason.playlist: return String(localized: "Playlist")
        case BackupReason.restore: return String(localized: "vor Wiederherstellung")
        default: return reason
        }
    }
}

extension FileEntry.SaveSnapshot {
    /// Auslöser fürs Sicherungs-Journal, abgeleitet aus der Art des
    /// Speichervorgangs (die Historie zeigt ihn je Version an).
    var backupReason: String {
        switch self {
        case .audio, .image, .ebook, .document: return BackupReason.tags
        case .sidecar: return BackupReason.sidecar
        case .playlist: return BackupReason.playlist
        }
    }
}

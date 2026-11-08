import AppKit
import SwiftUI
import TagExplosionCore
import TagExplosionApplication

extension AppModel {
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

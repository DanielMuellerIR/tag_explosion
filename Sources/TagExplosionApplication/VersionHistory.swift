// Undo-Historie im App-Modell: eine Papierkorb-Sicherung zurückspielen und
// den Eintrag danach neu von der Platte lesen (siehe BackupHistory im Core).
import Foundation
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
    public func restoreVersion(_ version: BackupVersion, for entry: FileEntry,
                        backup: TrashBackup = .shared) async -> Bool {
        guard !entry.isSaving, !isDestructiveActionLocked else { return false }
        let url = entry.url
        let kind = entry.kind
        let destination = URL(fileURLWithPath: version.entry.originalPath)
        do {
            guard let state = entry.restoreState(for: destination) else {
                throw TagError.saveFailed(path: destination.path)
            }
            return try await reloadAfterMutation(entry: entry) {
                try await BlockingWork.run {
                    try BackupHistory.restore(version, expecting: state, backup: backup)
                    return try Self.readStamped(url: url, kind: kind)
                }
            }
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Version wiederherstellen fehlgeschlagen: \(entry.url.lastPathComponent)")
                + "\n" + error.localizedDescription
            return false
        }
    }

}

/// Anzeigeformen für die Historie (Zeit, Auslöser, Größe) — App-weit gleich.
public enum VersionHistoryFormat {
    public static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Auslöser in Worten; unbekannte Werte (spätere Versionen, Skripte)
    /// erscheinen unverändert.
    public static func reason(_ reason: String) -> String {
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
    public var backupReason: String {
        switch self {
        case .audio, .image, .ebook, .document: return BackupReason.tags
        case .sidecar: return BackupReason.sidecar
        case .playlist: return BackupReason.playlist
        }
    }
}

extension FileEntry {
    /// Nur Datei und zugehörige Sidecars gehören zur Historie dieses Eintrags.
    /// Ihre Lesestände bleiben auch nach Auswahl einer alten Sicherung gültig.
    public func restoreState(for destination: URL) -> FileState? {
        let target = MediaFormats.canonicalFileURL(destination)
        let media = MediaFormats.canonicalFileURL(url)
        if target == media { return diskStamp.map(FileState.present) ?? .unknown }
        switch loadedState {
        case .audio(_, let sidecars):
            if target == MediaFormats.canonicalFileURL(LRC.sidecarURL(for: media)) {
                return sidecars.lrcState
            }
            let nfo = media.deletingPathExtension().appendingPathExtension(SidecarTool.nfoExtension)
            if MediaFormats.nfoVideo.contains(media.pathExtension.lowercased()),
               target == MediaFormats.canonicalFileURL(nfo) {
                guard let nfo = sidecars.nfo else { return .absent }
                return nfo.stamp.map(FileState.present) ?? .unknown
            }
        case .image(let reading):
            if target == MediaFormats.canonicalFileURL(MediaFormats.sidecarURL(for: media)) {
                return reading.sidecar
            }
        default: break
        }
        return nil
    }
}

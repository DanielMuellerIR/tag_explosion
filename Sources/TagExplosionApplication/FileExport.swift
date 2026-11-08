import Foundation
import TagExplosionCore

extension AppModel {
    public func exportData(_ data: Data, to url: URL) async {
        await exportData(data, to: url) { try FileExport.write($0, to: $1) }
    }

    /// Variante mit austauschbarem Schreiber für headless Tests. Anmeldung,
    /// Hintergrundstart und Fehleranzeige bleiben identisch zur App.
    ///
    /// Der Export wird vor dem Hintergrundstart als laufender Schreibauftrag
    /// angemeldet und erst nach seinem Ende wieder abgemeldet. Sonst meldet
    /// `hasUnfinishedWork` bei sauberen Puffern nichts, und ⌘Q beendet die App
    /// mitten zwischen Sicherung und atomarem Austausch (Review-Fund 2026-09-09).
    public func exportData(
        _ data: Data,
        to url: URL,
        write: @escaping @Sendable (Data, URL) throws -> Void
    ) async {
        guard beginExport() else { return }
        defer { endExport() }
        do {
            try await Task.detached(priority: .userInitiated) {
                try write(data, url)
            }.value
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

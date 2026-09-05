import Foundation
import SwiftUI

struct BatchSaveResult: Identifiable {
    enum Status {
        case pending, saving, success, failed, skipped
        var title: String {
            switch self {
            case .pending: String(localized: "Wartend")
            case .saving: String(localized: "Speichern …")
            case .success: String(localized: "Erfolgreich")
            case .failed: String(localized: "Fehlgeschlagen")
            case .skipped: String(localized: "Übersprungen")
            }
        }
    }
    var url: URL
    var id: URL { url }
    var status: Status = .pending
    var reason = ""
}

/// Erfolgreicher Container-Austausch lässt sich bei einem Sidecar-Fehler
/// nicht zurückrollen. Die Meldung nennt deshalb die bereits geschriebenen Ziele.
struct PartialSaveError: LocalizedError {
    let completed: [String]
    let underlying: Error
    var errorDescription: String? {
        String(localized: "Bereits geschrieben:") + " " + completed.joined(separator: ", ")
            + "\n" + underlying.localizedDescription
    }
}

struct BatchSaveResultsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading) {
            Text("Speicherergebnisse").font(.headline)
            if model.isBatchSaving {
                ProgressView(value: Double(model.batchCompletedCount),
                             total: Double(max(1, model.batchResults.count)))
                Button("Abbrechen") { model.cancelBatchSave() }
            }
            List(model.batchResults) { result in
                VStack(alignment: .leading) {
                    Text(result.url.lastPathComponent + " — " + result.status.title)
                    if !result.reason.isEmpty { Text(result.reason).foregroundStyle(.secondary) }
                }.help(result.url.path)
            }
            HStack {
                Button("Fehlgeschlagene wiederholen") { Task { await model.retryFailedSaves() } }
                    .disabled(model.isBatchSaving || model.isDestructiveActionLocked || !model.batchResults.contains { $0.status == .failed })
                Spacer()
                Button("Schließen") { model.showBatchResults = false }
            }
        }.padding().frame(minWidth: 600, minHeight: 360)
    }
}

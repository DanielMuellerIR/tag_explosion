import Foundation
import SwiftUI
import TagExplosionApplication

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

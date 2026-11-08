import SwiftUI
import TagExplosionApplication

struct ApplicationDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let conflictMessage: String = model.pendingConflict?.displayedMessage ?? ""
        let externalMessage: String = model.pendingExternalImport?.displayedMessage ?? ""
        return content
        .confirmationDialog(
            model.pendingConflict?.title ?? "",
            isPresented: .init(
                get: { model.pendingConflict != nil },
                set: { isPresented in
                    // Klick außerhalb des Dialogs zählt wie Abbrechen. Der
                    // MainActor-Guard im Modell macht Button + Binding sicher
                    // gegen doppelte Aufrufe.
                    guard !isPresented, model.pendingConflict != nil,
                          model.claimPendingConflict(.cancel) else { return }
                    Task { await model.resolveClaimedPendingConflict() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Speichern") {
                guard model.claimPendingConflict(.save) else { return }
                Task { await model.resolveClaimedPendingConflict() }
            }
            .disabled(model.isResolvingConflict)
            Button("Verwerfen", role: .destructive) {
                guard model.claimPendingConflict(.discard) else { return }
                Task { await model.resolveClaimedPendingConflict() }
            }
            .disabled(model.isResolvingConflict)
            Button("Abbrechen", role: .cancel) {
                guard model.claimPendingConflict(.cancel) else { return }
                Task { await model.resolveClaimedPendingConflict() }
            }
            .disabled(model.isResolvingConflict)
        } message: {
            Text(conflictMessage)
        }
        .confirmationDialog(
            "Externe Importziele",
            isPresented: .init(
                get: { model.pendingExternalImport != nil },
                set: { isPresented in
                    guard !isPresented, model.pendingExternalImport != nil,
                          model.claimPendingExternalImport(approve: false) else { return }
                    Task { await model.resolveClaimedPendingExternalImport() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Alle Ziele freigeben", role: .destructive) {
                guard model.claimPendingExternalImport(approve: true) else { return }
                Task { await model.resolveClaimedPendingExternalImport() }
            }
            Button("Abbrechen", role: .cancel) {
                guard model.claimPendingExternalImport(approve: false) else { return }
                Task { await model.resolveClaimedPendingExternalImport() }
            }
        } message: {
            Text(externalMessage)
        }
        // Wie bei den anderen Dialogen wird die Entscheidung synchron im
        // Button-Callback beansprucht. Sonst räumte der unmittelbar folgende
        // Dismiss den bestätigten Eintrag aus der Warteschlange, und der erst
        // danach laufende Task schriebe die NÄCHSTE Datei ohne ihre eigene
        // Bestätigung.
        .alert("Datei wurde außerhalb geändert", isPresented: .init(
            get: { model.pendingStaleWrite != nil },
            set: { isPresented in
                guard !isPresented, model.pendingStaleWrite != nil,
                      model.claimStaleWrite(write: false) else { return }
                Task { await model.resolveClaimedStaleWrite() }
            }
        )) {
            Button("Trotzdem speichern") {
                guard model.claimStaleWrite(write: true) else { return }
                Task { await model.resolveClaimedStaleWrite() }
            }
            Button("Abbrechen", role: .cancel) {
                guard model.claimStaleWrite(write: false) else { return }
                Task { await model.resolveClaimedStaleWrite() }
            }
        } message: {
            Text("""
            \(model.pendingStaleWrite?.fileName ?? "") wurde seit dem Öffnen von \
            einem anderen Programm geändert. Speichern überschreibt diese \
            Änderung. Der jetzige Stand der Datei wird vorher in den Papierkorb \
            kopiert, sofern der abgesicherte Modus aktiv ist.
            """)
        }
        .alert("Hinweis", isPresented: .init(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

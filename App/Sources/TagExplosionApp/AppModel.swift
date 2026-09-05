// Zentrales App-Modell: geladene Dateien, Auswahl, Laden/Speichern.
// UI-State läuft auf dem MainActor; Datei-IO in Hintergrund-Tasks.
import AppKit
import EInvoiceCore
import Observation
import SwiftUI
import TagExplosionCore
import UniformTypeIdentifiers

/// Entscheidung für eine Aktion, die ungespeicherte Editor-Puffer zerstören
/// oder durch Plattenwerte ersetzen würde.
enum DirtyConflictDecision {
    case save
    case discard
    case cancel
}

/// Der für SwiftUI sichtbare Teil einer wartenden Aktion. Die eigentliche
/// Abschluss-Closure bleibt privat im Modell, damit die View keine Dateilogik
/// oder Terminierungsdetails kennen muss.
struct PendingDirtyConflict: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let affectedEntryCount: Int
    var failureMessage: String?

    var displayedMessage: String { failureMessage ?? message }
}

/// Explizite Freigabe für Archive, die mindestens ein Ziel außerhalb ihres
/// eigenen Verzeichnisses enthalten. Angezeigt wird bewusst die vollständige
/// aufgelöste Zielliste, nicht nur der erste auffällige Pfad.
struct PendingExternalImportApproval: Identifiable {
    let id = UUID()
    let targetPaths: [String]
    let externalTargetCount: Int

    var displayedMessage: String {
        String(localized:
            "Dieses Archiv enthält \(externalTargetCount) Ziel(e) außerhalb seines Ordners. Alle aufgelösten Ziele:")
            + "\n\n" + targetPaths.joined(separator: "\n")
    }
}

/// Rückmeldung an den AppDelegate nach einer asynchronen Terminierungsfrage.
/// AppKit-Typen bleiben dabei aus der headless testbaren Konfliktlogik heraus.
enum TerminationDecision {
    case terminateNow
    case terminateCancel
}

/// Globaler App-Zustand.
@Observable
@MainActor
final class AppModel {
    private struct PendingAction {
        var conflict: PendingDirtyConflict
        let entries: [FileEntry]
        let perform: @MainActor () async -> Void
        let cancel: @MainActor () -> Void
    }

    private struct PendingExternalImportAction {
        let perform: @MainActor () async -> Void
    }

    var entries: [FileEntry] = []
    var selection: Set<URL> = []
    var listSearch = ""
    var listKind: MediaKind?
    var listDirtyOnly = false
    var listErrorsOnly = false
    var listSort: FileListSort = .input

    /// Das Fenster, in dem dieses Modell steckt — gesetzt von `WindowBridge`.
    /// `WindowSessions` erkennt daran, welche Modelle wirklich sichtbar sind;
    /// ein Modell ohne Fenster darf keine Dateien mehr zugeteilt bekommen.
    /// Bewusst nicht beobachtet: Es ist keine Anzeige-, sondern Zuordnungsinfo.
    @ObservationIgnored weak var hostWindow: NSWindow?
    /// Zustand des Ladeablaufs; Reservierungen gehören demselben Fenster.
    let loading = FileLoadingState()
    var loadingCompleted: Int { loading.completed }
    var loadingTotal: Int { loading.total }
    var isLoading: Bool { loading.operationCount > 0 }
    var batchResults: [BatchSaveResult] = []
    var batchCompletedCount: Int {
        batchResults.filter { $0.status != .pending && $0.status != .saving }.count
    }
    private(set) var isBatchSaving = false
    private var cancelBatchRequested = false
    private var batchSaveWaiters: [CheckedContinuation<Void, Never>] = []
    var showBatchResults = false
    func cancelBatchSave() { cancelBatchRequested = true }

    func retryFailedSaves() async {
        await retryFailedSaves { await self.save(entry: $0) }
    }

    func retryFailedSaves(saveEntry: @escaping @MainActor (FileEntry) async -> Bool) async {
        guard !isBatchSaving, !isDestructiveActionLocked else { return }
        let previous = batchResults
        let failed = Set(previous.filter { $0.status == .failed }.map(\.url))
        await saveEntries(entries.filter { failed.contains($0.url) }, saveEntry: saveEntry)
        let retried = Dictionary(uniqueKeysWithValues: batchResults.map { ($0.url, $0) })
        batchResults = previous.map { retried[$0.url] ?? $0 }
    }

    /// Fehlermeldung für Alert-Anzeige.
    var alertMessage: String?
    /// Einträge, für die das Sheet der Konsistenzprüfung offen ist (nil =
    /// geschlossen). Liegt im Modell statt in der View, damit ein Klick auf
    /// eine Datei im Sheet die Auswahl ändern kann, ohne das Sheet zu schließen
    /// (der Batch-Editor wird bei Auswahlwechsel neu aufgebaut).
    var libraryCheckTargets: [FileEntry]?
    /// Sichtbarer Save/Discard/Cancel-Zustand für Import, Entfernen, Fenster
    /// und App-Terminierung.
    private(set) var pendingConflict: PendingDirtyConflict?
    /// Eine Aktion wartet zunächst auf bereits laufende Speichervorgänge.
    /// Währenddessen darf kein zweiter konkurrierender Auftrag entstehen.
    private var isPreparingDestructiveAction = false
    /// Nach einem Klick auf Speichern/Verwerfen bleibt die UI gesperrt, bis
    /// alle betroffenen Dateien fertig behandelt sind.
    private(set) var isResolvingConflict = false
    private var pendingAction: PendingAction?
    /// Der Button beansprucht die Entscheidung synchron vor dem asynchronen
    /// Task. So kann SwiftUIs anschließendes Dialog-Dismiss nicht noch ein
    /// konkurrierendes „Abbrechen“ dazwischenschieben.
    private var claimedConflictDecision: DirtyConflictDecision?
    private(set) var pendingExternalImport: PendingExternalImportApproval?
    private var pendingExternalImportAction: PendingExternalImportAction?
    private var claimedExternalImportApproval: Bool?

    var isDestructiveActionLocked: Bool {
        isBatchSaving || pendingConflict != nil || pendingExternalImport != nil
            || pendingStaleWrite != nil || claimedStaleWrite != nil
            || isPreparingDestructiveAction || isResolvingConflict
    }

    /// Der Dialog selbst sperrt bereits die View. Diese Ergänzung deckt die
    /// kurze Warte- und Auflösungsphase ab, in der sonst ein Textfeld noch eine
    /// neue, unbestätigte Änderung annehmen könnte.
    var isEditorInteractionLocked: Bool {
        isPreparingDestructiveAction || isResolvingConflict
    }

    /// Die ausgewählten Einträge in Listenreihenfolge.
    var selectedEntries: [FileEntry] {
        entries.filter { selection.contains($0.url) }
    }

    /// Genau ein ausgewählter Eintrag (Einzel-Editor), sonst nil.
    var selectedEntry: FileEntry? {
        let selected = selectedEntries
        return selected.count == 1 ? selected.first : nil
    }

    var hasDirtyEntries: Bool {
        entries.contains { $0.isDirty }
    }

    // Bestehende Einstiege bleiben erhalten; IO besitzt keinen Fensterzustand.
    nonisolated static func readLoaded(url: URL, kind: MediaKind) throws -> LoadedData {
        try AppFileIO.readLoaded(url: url, kind: kind)
    }
    nonisolated static func readVideoNFO(for url: URL) -> NFOSidecarReading? {
        AppFileIO.readVideoNFO(for: url)
    }
    nonisolated static func readStamped(url: URL, kind: MediaKind,
                                       read: (URL, MediaKind) throws -> LoadedData = AppModel.readLoaded) throws -> (LoadedData, FileStamp?) {
        try AppFileIO.readStamped(url: url, kind: kind, read: read)
    }

    // MARK: - Speichern

    /// Schlüssel der Auto-Backup-Einstellung (Toggle in den Einstellungen).
    static let autoBackupDefaultsKey = "autoBackupBeforeBatchSave"

    /// Schlüssel des abgesicherten Modus (Kopie in den Papierkorb vor jeder
    /// Änderung).
    static let safeModeDefaultsKey = "trashBackupBeforeSave"

    /// Abgesicherter Modus aktiv? Default an — solange die App jung ist, soll
    /// keine Änderung eine Datei endgültig kosten.
    static var safeModeEnabled: Bool {
        UserDefaults.standard.object(forKey: safeModeDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: safeModeDefaultsKey)
    }

    /// Überträgt die Einstellung in den Core. Muss beim Start und nach jeder
    /// Änderung der Einstellung laufen.
    static func applySafeMode() {
        TrashBackup.shared.isEnabled = safeModeEnabled
        TrashBackup.shared.folderLabel = String(localized: "Tag Explosion Sicherung")
    }

    /// Schlüssel der Einstellung „Bild-Metadaten in die XMP-Sidecar schreiben
    /// statt in die Bilddatei". Voreinstellung aus; für Kamera-RAW und
    /// Formate ohne exiftool-Schreibweg erzwingt der Core die Sidecar ohnehin.
    nonisolated static let imageSidecarDefaultsKey = "writeImageSidecar"

    /// Sidecar statt Original für alle Bildformate? (Default: aus).
    /// `nonisolated`, weil der Hintergrund-Schreibweg sie liest; UserDefaults
    /// ist threadsicher.
    nonisolated static var imageSidecarPreferred: Bool {
        UserDefaults.standard.bool(forKey: imageSidecarDefaultsKey)
    }

    /// Schlüssel der Einstellung „ID3v2.3 statt ID3v2.4 schreiben" (für alte
    /// Player, die v2.4 nicht lesen). Voreinstellung aus.
    nonisolated static let id3v23DefaultsKey = "writeID3v23"

    /// ID3v2-Version für den Audio-Schreibweg laut Einstellung (Default v2.4).
    /// `nonisolated`, weil der Hintergrund-Schreibweg sie liest.
    nonisolated static var preferredID3Version: ID3Version {
        UserDefaults.standard.bool(forKey: id3v23DefaultsKey) ? .v23 : .v24
    }

    /// Auto-Backup vor Batch-Speichern? (Default: an)
    static var autoBackupEnabled: Bool {
        UserDefaults.standard.object(forKey: autoBackupDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: autoBackupDefaultsKey)
    }

    /// Speichert alle ausgewählten Dateien mit Änderungen.
    func saveSelected() async {
        guard !isDestructiveActionLocked else { return }
        await saveEntries(selectedEntries.filter(\.isDirty))
    }

    /// Verwirft Änderungen aller ausgewählten Dateien.
    func revertSelected() {
        guard !isDestructiveActionLocked else { return }
        for entry in selectedEntries { entry.revert() }
    }

    var selectionIsDirty: Bool {
        selectedEntries.contains { $0.isDirty }
    }

    /// Die Auswahl kann nur einmal gleichzeitig gespeichert werden. Sichtbar
    /// deaktivierte Speichern-Aktionen verhindern unzulässige Doppel-Clicks.
    var selectionIsSaving: Bool {
        selectedEntries.contains { $0.isSaving }
    }

    var hasSavingEntries: Bool {
        entries.contains { $0.isSaving }
    }

    /// Hat dieses Fenster etwas zu verlieren? Ungespeicherte Änderungen, ein
    /// laufendes Speichern oder ein offener Dialog — jedes davon muss das
    /// Beenden aufhalten. Als benannte Eigenschaft, weil `WindowSessions` das
    /// Prädikat an zwei Stellen braucht (Rundenguard und Schlussabgleich) und
    /// ein Auseinanderlaufen die App unbeendbar machte (Review-Fund 2026-08-20).
    var hasUnfinishedWork: Bool {
        hasDirtyEntries || hasSavingEntries || isDestructiveActionLocked
    }

    func saveAll() async {
        guard !isDestructiveActionLocked else { return }
        await saveEntries(entries.filter(\.isDirty))
    }

    /// Gemeinsamer Speicherpfad: erst Auto-Backup, dann Datei für Datei.
    /// Der Rückgabewert ist für die Konfliktlogik entscheidend: Nur ein
    /// vollständig erfolgreicher Batch darf anschließend importieren, entfernen
    /// oder die App beenden. Modulintern, weil auch die Batch-Regeln
    /// (`applyRules`) diesen Weg nehmen.
    @discardableResult
    func saveEntries(_ dirty: [FileEntry]) async -> Bool {
        await saveEntries(dirty) { entry in
            await self.save(entry: entry)
        }
    }

    /// Variante mit austauschbarem Einzel-Speicherweg für headless Tests. Die
    /// Sicherung, Wartezeit und Erfolgsprüfung bleiben identisch zur App.
    @discardableResult
    func saveEntries(
        _ dirty: [FileEntry],
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async -> Bool {
        guard !isBatchSaving else { return false }
        isBatchSaving = true
        cancelBatchRequested = false
        defer {
            isBatchSaving = false
            let waiters = batchSaveWaiters
            batchSaveWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let targets = uniqueEntries(dirty)
        batchResults = targets.map { BatchSaveResult(url: $0.url) }
        await waitForSaves(in: targets)
        let pending = targets.filter(\.isDirty)
        guard await backupIfNeeded(before: pending) else {
            batchResults = targets.map {
                BatchSaveResult(url: $0.url, status: $0.isDirty ? .failed : .skipped,
                                reason: alertMessage ?? String(localized: "Sicherung fehlgeschlagen"))
            }
            return false
        }
        var succeeded = true
        for (index, entry) in targets.enumerated() {
            if cancelBatchRequested || Task.isCancelled {
                batchResults[index].status = .skipped
                batchResults[index].reason = String(localized: "Abgebrochen")
                succeeded = false
                continue
            }
            guard entry.isDirty else {
                batchResults[index].status = .skipped
                batchResults[index].reason = String(localized: "Unverändert")
                continue
            }
            batchResults[index].status = .saving
            let saved = await saveEntry(entry)
            batchResults[index].status = saved ? .success : .failed
            batchResults[index].reason = saved ? "" : (entry.lastError ?? String(localized: "Speichern fehlgeschlagen"))
            if !saved { succeeded = false }
        }
        return succeeded
    }

    /// Schreibt vor einem Batch-Speichern (mehr als eine Datei) die Backups
    /// über TagArchiveIO (Namensschema und Ordner-Gruppierung liegen im Core,
    /// damit CLI-Wiederherstellung und App dasselbe Format teilen).
    /// false = Backup fehlgeschlagen, Speichern wird abgebrochen.
    private func backupIfNeeded(before dirtyEntries: [FileEntry]) async -> Bool {
        guard Self.autoBackupEnabled, dirtyEntries.count > 1 else { return true }
        let files = dirtyEntries.map(\.url)
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.writeBackups(files: files)
            }.value
            return true
        } catch {
            alertMessage = String(localized: "Auto-Backup fehlgeschlagen — Speichern abgebrochen.")
                + "\n" + error.localizedDescription
            return false
        }
    }

    // MARK: - Ungespeicherte Änderungen vor destruktiven Aktionen

    /// Startet genau eine geschützte Aktion. Zuerst warten wir auf alle schon
    /// laufenden Saves derselben Dateien; erst dann entscheiden wir anhand der
    /// aktuellen Puffer, ob ein Save/Discard/Cancel-Dialog nötig ist.
    func requestDestructiveAction(
        title: String,
        message: String,
        entries affectedEntries: [FileEntry],
        perform: @escaping @MainActor () async -> Void,
        cancel: @escaping @MainActor () -> Void = {}
    ) async {
        guard !isDestructiveActionLocked else {
            // Besonders bei App-Terminierung muss jeder terminateLater-Aufruf
            // eine Antwort erhalten. Die neue, konkurrierende Anfrage wird
            // daher ausdrücklich abgebrochen statt still hängen zu bleiben.
            cancel()
            return
        }

        isPreparingDestructiveAction = true
        defer { isPreparingDestructiveAction = false }
        let targets = uniqueEntries(affectedEntries)
        await waitForSaves(in: targets)

        let dirty = targets.filter(\.isDirty)
        guard !dirty.isEmpty else {
            await perform()
            return
        }

        let conflict = PendingDirtyConflict(
            title: title,
            message: message,
            affectedEntryCount: dirty.count
        )
        let action = PendingAction(conflict: conflict, entries: targets,
                                   perform: perform, cancel: cancel)
        pendingAction = action
        pendingConflict = conflict
    }

    /// Beansprucht synchron genau eine sichtbare Entscheidung. Diese Methode
    /// wird direkt aus dem Button-Callback aufgerufen, noch bevor dessen
    /// `Task` geplant wird; der Dismiss-Callback kann sie danach nicht mehr
    /// durch `.cancel` ersetzen.
    @discardableResult
    func claimPendingConflict(_ decision: DirtyConflictDecision) -> Bool {
        guard pendingAction != nil, !isResolvingConflict else { return false }
        isResolvingConflict = true
        claimedConflictDecision = decision
        return true
    }

    /// Bequemer asynchroner Einstieg für nicht-visuelle Aufrufer und Tests.
    /// Die View benutzt stattdessen Claim + `resolveClaimedPendingConflict()`,
    /// damit sie die Entscheidung synchron sichern kann.
    func resolvePendingConflict(_ decision: DirtyConflictDecision) async {
        guard claimPendingConflict(decision) else { return }
        await resolveClaimedPendingConflict { entry in
            await self.save(entry: entry)
        }
    }

    /// Austauschbarer Schreibweg für Tests; der Produktionsweg oben verwendet
    /// exakt dieselbe Konfliktsteuerung und nur den echten Dateischreiber.
    func resolvePendingConflict(
        _ decision: DirtyConflictDecision,
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async {
        guard claimPendingConflict(decision) else { return }
        await resolveClaimedPendingConflict(saveEntry: saveEntry)
    }

    /// Führt ausschließlich die zuvor synchron beanspruchte Entscheidung aus.
    /// Ohne Claim bleibt der Konflikt unangetastet, damit ein versehentlicher
    /// zweiter Task keine fremde Auswahl übernehmen kann.
    func resolveClaimedPendingConflict() async {
        await resolveClaimedPendingConflict { entry in
            await self.save(entry: entry)
        }
    }

    /// Testbare Variante des geclaimten Ablaufs mit austauschbarem Schreiber.
    func resolveClaimedPendingConflict(
        saveEntry: @escaping @MainActor (FileEntry) async -> Bool
    ) async {
        guard let decision = claimedConflictDecision, var action = pendingAction else { return }
        defer {
            claimedConflictDecision = nil
            isResolvingConflict = false
        }

        switch decision {
        case .cancel:
            clearPendingAction()
            action.cancel()

        case .discard:
            // Nur die tatsächlich betroffenen Puffer verwerfen. Ein offener,
            // aber nicht importierter Editor bleibt bewusst unverändert.
            for entry in action.entries where entry.isDirty { entry.revert() }
            clearPendingAction()
            await action.perform()

        case .save:
            // Ein in der Zwischenzeit gestarteter Save muss vor dem eigenen
            // Batch enden. Danach speichern wir alle noch dirty Puffer erneut.
            await waitForSaves(in: action.entries)
            let succeeded = await saveEntries(
                action.entries.filter(\.isDirty), saveEntry: saveEntry
            )
            let stillDirty = action.entries.contains { $0.isDirty || $0.isSaving }
            guard succeeded, !stillDirty else {
                action.conflict.failureMessage = String(localized:
                    "Speichern fehlgeschlagen. Die Aktion wurde nicht ausgeführt.")
                pendingAction = action
                pendingConflict = action.conflict
                return
            }
            clearPendingAction()
            await action.perform()
        }
    }

    /// AppKit erhält seine konkrete Terminierungsantwort erst hier. Dadurch
    /// bleibt die Save/Discard/Cancel-Logik ohne Fenster und NSApplication
    /// ausführbar testbar.
    func requestTermination(
        reply: @escaping @MainActor (TerminationDecision) -> Void
    ) async {
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Beenden müssen die Änderungen gespeichert oder verworfen werden."),
            entries: entries,
            perform: { reply(.terminateNow) },
            cancel: { reply(.terminateCancel) }
        )
    }

    /// Fenster-Schließen verwendet denselben Pfad wie Cmd-Q, antwortet aber
    /// über den vom NSWindowDelegate bereitgestellten Close-Bypass.
    func requestWindowClose(
        performClose: @escaping @MainActor () -> Void
    ) async {
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Schließen des Fensters müssen die Änderungen gespeichert oder verworfen werden."),
            entries: entries,
            perform: performClose
        )
    }

    private func clearPendingAction() {
        pendingAction = nil
        pendingConflict = nil
    }

    /// Dedupliziert Klasseninstanzen, nicht URLs: Ein Eintrag kann während
    /// eines Imports noch denselben Pfad wie ein Symlink tragen, bleibt aber
    /// trotzdem nur ein Editor-Puffer.
    private func uniqueEntries(_ candidates: [FileEntry]) -> [FileEntry] {
        var seen: Set<ObjectIdentifier> = []
        return candidates.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func waitForSaves(in entries: [FileEntry]) async {
        for entry in uniqueEntries(entries) {
            await entry.waitUntilSaveFinished()
        }
    }

    // MARK: - Untertitel verschieben

    /// Verschiebt alle Cues einer Untertiteldatei um `seconds` und liest den
    /// Eintrag neu. Eigener Schreibweg neben `save`, weil sich dabei kein
    /// Feld des Puffers ändert: Stempelprüfung, Papierkorb-Sicherung und der
    /// atomare Austausch liegen im Core (`SubtitleFile.shift`).
    @discardableResult
    func shiftSubtitle(entry: FileEntry, seconds: Double) async -> Bool {
        guard entry.kind == .sidecar, !entry.isSaving, !entry.isDirty else { return false }
        let url = entry.url
        let stamp = entry.diskStamp
        // Bereichsprüfung im Core (endlich, höchstens 1000 Stunden) — ein zu
        // großer Wert endet als Fehlertext am Eintrag statt als Absturz.
        let milliseconds: Int
        do {
            milliseconds = try SubtitleFile.shiftMilliseconds(seconds: seconds)
        } catch {
            entry.lastError = error.localizedDescription
            return false
        }
        guard milliseconds != 0 else { return false }
        entry.isSaving = true
        defer { entry.finishSaving() }
        do {
            let (loaded, newStamp) = try await Task.detached(priority: .userInitiated) {
                try FileStamp.requireUnchanged(stamp, at: url)
                try TrashBackup.shared.backUp(url)
                try SubtitleFile.shift(url: url, milliseconds: milliseconds, expecting: stamp)
                return try Self.readStamped(url: url, kind: .sidecar)
            }.value
            entry.acceptNew(loaded, stamp: newStamp)
            return true
        } catch {
            entry.lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Export/Import (JSON)

    /// Exportiert die Tags der Einträge als selbständige JSON-Datei.
    /// E-Rechnungen sind reine Anzeige und werden nicht mitgezählt — sonst
    /// entstünde ein Archiv, das weniger Dateien enthält als versprochen.
    func exportEntries(_ exportEntries: [FileEntry], to url: URL) async {
        let files = exportEntries
            .filter { MediaFormats.isArchivable(url: $0.url) }
            .map(\.url)
        guard !files.isEmpty else {
            alertMessage = String(localized:
                "Nichts zu exportieren: E-Rechnungen sind reine Anzeige und tragen keine editierbaren Tags.")
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.export(files: files, to: url, includeCovers: true)
            }.value
        } catch {
            alertMessage = String(localized: "Export fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Wendet eine Export-/Backup-JSON auf die Platte an und lädt betroffene,
    /// bereits geöffnete Dateien neu.
    func importArchive(from url: URL) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let archive = try TagArchiveIO.load(url)
                let base = url.deletingLastPathComponent()
                let targets = try TagArchiveIO.validatedTargets(
                    archive, relativeTo: base, allowExternalTargets: true)
                let external = TagArchiveIO.externalTargets(targets, relativeTo: base)
                return (archive, base, targets, external)
            }.value
            // Die geprüfte Zielliste geht IMMER an `apply` — auch wenn kein
            // Ziel außerhalb des Archivordners liegt und deshalb kein
            // Freigabedialog nötig war. Genau diese Liste hat der Konflikt-
            // dialog verwendet, um betroffene offene Editoren zu bestimmen;
            // ein während des Dialogs umgebogener Symlink darf nicht auf eine
            // nie berücksichtigte Datei zeigen.
            let approvedTargets = prepared.2
            let allowExternal = !prepared.3.isEmpty
            await requestExternalApprovalOrScheduleImport(
                archive: prepared.0,
                relativeTo: prepared.1,
                targets: prepared.2,
                externalTargets: prepared.3
            ) { archive, base in
                try await Task.detached(priority: .userInitiated) {
                    try TagArchiveIO.apply(
                        archive, relativeTo: base, dryRun: false,
                        approvedTargets: approvedTargets,
                        allowExternalTargets: allowExternal)
                }.value
            }
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Testbarer Import-Einstieg mit austauschbarem Schreiber. Die Archiv-
    /// Validierung und die Schnittmenge mit geöffneten Dateien bleiben dabei
    /// identisch zum echten JSON-Import.
    func importArchive(
        archive: TagArchive,
        relativeTo base: URL,
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        do {
            let targets = try await Task.detached(priority: .userInitiated) {
                try TagArchiveIO.validatedTargets(
                    archive, relativeTo: base, allowExternalTargets: true)
            }.value
            let external = TagArchiveIO.externalTargets(targets, relativeTo: base)
            await requestExternalApprovalOrScheduleImport(
                archive: archive, relativeTo: base, targets: targets,
                externalTargets: external, apply: apply)
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    private func requestExternalApprovalOrScheduleImport(
        archive: TagArchive,
        relativeTo base: URL,
        targets: [URL],
        externalTargets: [URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        guard !isDestructiveActionLocked else { return }
        guard !externalTargets.isEmpty else {
            await scheduleImport(
                archive: archive, relativeTo: base, targets: targets, apply: apply)
            return
        }

        pendingExternalImport = PendingExternalImportApproval(
            targetPaths: targets.map(\.path),
            externalTargetCount: externalTargets.count)
        pendingExternalImportAction = PendingExternalImportAction(
            perform: { [weak self] in
                await self?.scheduleImport(
                    archive: archive, relativeTo: base,
                    targets: targets, apply: apply)
            })
    }

    /// Beansprucht Freigeben/Abbrechen synchron, damit Dialog-Button und
    /// Dismiss-Callback nicht zwei verschiedene Entscheidungen ausführen.
    @discardableResult
    func claimPendingExternalImport(approve: Bool) -> Bool {
        guard pendingExternalImportAction != nil,
              claimedExternalImportApproval == nil else { return false }
        claimedExternalImportApproval = approve
        return true
    }

    func resolveClaimedPendingExternalImport() async {
        guard let approve = claimedExternalImportApproval,
              let action = pendingExternalImportAction else { return }
        pendingExternalImport = nil
        pendingExternalImportAction = nil
        claimedExternalImportApproval = nil
        if approve { await action.perform() }
    }

    /// Der Archiv-Snapshot ist schon geladen und validiert, wird aber erst in
    /// der `perform`-Closure nach Save/Discard angewandt. Damit kann ein
    /// Konfliktdialog nie einen Teilimport vor der Entscheidung auslösen.
    private func scheduleImport(
        archive: TagArchive,
        relativeTo base: URL,
        targets: [URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        let targetSet = Set(targets.map(MediaFormats.canonicalFileURL))
        let openedTargets = entries.filter {
            targetSet.contains(MediaFormats.canonicalFileURL($0.url))
        }
        // Feste Zuordnung Archiveintrag → geprüftes Ziel. `validatedTargets`
        // liefert die Ziele in der Reihenfolge der Archiveinträge, und deren
        // Pfade sind eindeutig (Archiv-Schemaprüfung).
        let targetsByArchivePath = Dictionary(
            uniqueKeysWithValues: zip(archive.files.map(\.path), targets))
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Import müssen die Änderungen betroffener Dateien gespeichert oder verworfen werden."),
            entries: openedTargets,
            perform: { [weak self] in
                await self?.applyPreparedImport(
                    archive: archive, relativeTo: base,
                    targetsByArchivePath: targetsByArchivePath, apply: apply)
            }
        )
    }

    private func applyPreparedImport(
        archive: TagArchive,
        relativeTo base: URL,
        targetsByArchivePath: [String: URL],
        apply: @escaping @Sendable (TagArchive, URL) async throws -> TagArchiveReport
    ) async {
        do {
            let report = try await apply(archive, base)

            // Geänderte, geladene Einträge neu von der Platte lesen. Die Pfade
            // werden NICHT erneut aufgelöst: Ein nach der Prüfung umgebogener
            // Symlink zeigte sonst auf eine andere Datei, deren offener
            // Editor-Puffer beim Neuladen verlorenginge. `apply` schreibt
            // ausschließlich in die hier hinterlegten, freigegebenen Ziele.
            let changedPaths = Set(report.applied.compactMap {
                targetsByArchivePath[$0].map(MediaFormats.canonicalFileURL)
            })
            for entry in entries where changedPaths.contains(MediaFormats.canonicalFileURL(entry.url)) {
                await reload(entry: entry)
            }

            var summary = String(localized: "Import: \(report.applied.count) geändert, \(report.unchanged.count) unverändert")
            if !report.missing.isEmpty { summary += String(localized: ", \(report.missing.count) fehlend") }
            if !report.extra.isEmpty { summary += String(localized: ", \(report.extra.count) nicht im Archiv") }
            if !report.failed.isEmpty {
                summary += "\n" + String(localized: "Fehlgeschlagen:") + "\n" + report.failed
                    .map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            }
            alertMessage = summary
        } catch {
            alertMessage = String(localized: "Import fehlgeschlagen:") + "\n" + error.localizedDescription
        }
    }

    /// Entfernt eine Tag-Schicht (z.B. ID3v1) aus der Datei und liest sie neu.
    ///
    /// Läuft nur auf einer sauberen Datei: Der Bearbeitungspuffer würde nach
    /// dem Neuladen sonst still durch den Plattenstand ersetzt. Die View
    /// sperrt den Knopf deshalb bei ungespeicherten Änderungen; hier wird das
    /// trotzdem geprüft. Während des Entfernens gilt die Datei als „speichert"
    /// — derselbe Schutz wie beim Speichern gegen parallele Schreibzugriffe.
    @discardableResult
    func stripLayer(entry: FileEntry, kind: TagLayerKind) async -> Bool {
        guard !entry.isDirty, !entry.isSaving, !isDestructiveActionLocked else { return false }
        entry.isSaving = true
        defer { entry.finishSaving() }
        let url = entry.url
        let stamp = entry.diskStamp
        do {
            let (reloaded, newStamp) = try await Task.detached(priority: .userInitiated) {
                // Fremde Änderung seit dem Öffnen? Dann nicht anfassen.
                try FileStamp.requireUnchanged(stamp, at: url)
                try TrashBackup.shared.backUp(url, reason: BackupReason.layers)
                try TagFile.stripLayers([kind], from: url, expecting: stamp)
                return try Self.readStamped(url: url, kind: .audio)
            }.value
            entry.acceptNew(reloaded, stamp: newStamp)
            return true
        } catch {
            entry.lastError = error.localizedDescription
            alertMessage = String(localized: "Schicht entfernen fehlgeschlagen: \(entry.url.lastPathComponent)")
                + "\n" + error.localizedDescription
            return false
        }
    }

    /// Liest eine Datei neu von der Platte und ersetzt den Originalzustand.
    private func reload(entry: FileEntry) async {
        let url = entry.url
        let kind = entry.kind
        do {
            let (loaded, stamp) = try await Task.detached(priority: .userInitiated) {
                try Self.readStamped(url: url, kind: kind)
            }.value
            entry.acceptNew(loaded, stamp: stamp)
        } catch {
            entry.lastError = error.localizedDescription
        }
    }

    /// Schreibt den Bearbeitungspuffer einer Datei und liest sie neu ein.
    ///
    /// `ignoringDiskChange` überspringt die Prüfung auf fremde Änderungen —
    /// nur nach ausdrücklicher Bestätigung. Die Sicherungskopie im Papierkorb
    /// enthält dann den fremden Stand, das Überschreiben bleibt also umkehrbar.
    @discardableResult
    func save(entry: FileEntry, ignoringDiskChange: Bool = false) async -> Bool {
        let url = entry.url
        let kind = entry.kind
        let stamp = ignoringDiskChange ? nil : entry.diskStamp
        return await save(entry: entry, staleCandidate: ignoringDiskChange ? nil : entry) { snapshot in
            // Bewusstes Überschreiben gilt auch für die Sidecars (.lrc, NFO):
            // deren Stempel fallen ebenso weg wie der des Mediums.
            var snapshot = snapshot
            if ignoringDiskChange, case .audio(let audio) = snapshot {
                snapshot = .audio(audio.ignoringSidecarStamps())
            }
            let prepared = snapshot
            return try await Task.detached(priority: .userInitiated) {
                try Self.write(snapshot: prepared, to: url, kind: kind, expecting: stamp)
            }.value
        }
    }

    /// Eine Datei wurde außerhalb der App verändert; das Speichern wartet auf
    /// die Entscheidung der Person.
    struct PendingStaleWrite: Equatable {
        var fileName: String
    }

    private(set) var pendingStaleWrite: PendingStaleWrite?
    /// Wartende Konflikte in Reihenfolge ihres Auftretens. Ein Batch kann
    /// mehrere Dateien mit fremden Änderungen enthalten — jede bekommt ihre
    /// eigene Frage. Ein einzelner Merker würde beim zweiten Konflikt den
    /// ersten überschreiben: Der Dialog gehörte dann zur falschen Datei.
    private var staleEntries: [FileEntry] = []
    /// Der synchron beanspruchte Konflikt: Eintrag plus Entscheidung
    /// (true = trotzdem speichern). Solange ein Claim besteht, ist der Eintrag
    /// schon aus `staleEntries` heraus — ein zusätzlicher Dismiss findet ihn
    /// dort nicht mehr und kann weder ihn noch den nächsten Eintrag abbrechen.
    private var claimedStaleWrite: (entry: FileEntry, write: Bool)?

    /// Beansprucht synchron genau den gerade angezeigten Konflikt. Der Aufruf
    /// steht direkt im Button-Callback, noch bevor dessen `Task` läuft; der
    /// unmittelbar danach folgende Dismiss-Callback trifft auf einen bereits
    /// vergebenen Claim und lässt die Warteschlange in Ruhe.
    @discardableResult
    func claimStaleWrite(write: Bool) -> Bool {
        guard claimedStaleWrite == nil, !staleEntries.isEmpty else { return false }
        claimedStaleWrite = (staleEntries.removeFirst(), write)
        // Erst nach der Entscheidung den nächsten Konflikt anzeigen, sonst
        // stünde der Dialog schon während des laufenden Schreibvorgangs da.
        pendingStaleWrite = nil
        return true
    }

    /// Führt ausschließlich den zuvor beanspruchten Konflikt aus.
    func resolveClaimedStaleWrite() async {
        await resolveClaimedStaleWrite { entry in
            await self.save(entry: entry, ignoringDiskChange: true)
        }
    }

    /// Testbare Variante mit austauschbarem Schreiber; die Warteschlangen-
    /// Logik ist identisch zum Produktionsweg oben.
    func resolveClaimedStaleWrite(saveEntry: @MainActor (FileEntry) async -> Bool) async {
        guard let claim = claimedStaleWrite else { return }
        // Eine bestätigte Konfliktwiederholung darf den noch laufenden
        // seriellen Auftrag nicht mit einem zweiten Schreiber überholen.
        if claim.write && isBatchSaving {
            await withCheckedContinuation { batchSaveWaiters.append($0) }
        }
        claimedStaleWrite = nil
        if claim.write {
            let saved = await saveEntry(claim.entry)
            if let index = batchResults.firstIndex(where: { $0.url == claim.entry.url }) {
                batchResults[index].status = saved ? .success : .failed
                batchResults[index].reason = saved ? "" : (claim.entry.lastError ?? "")
            }
        }
        refreshPendingStaleWrite()
    }

    /// Trotzdem speichern — der bisherige Plattenstand liegt im Papierkorb.
    /// Bequemer Einstieg für nicht-visuelle Aufrufer und Tests; die View
    /// benutzt Claim + `resolveClaimedStaleWrite()`, damit sie die Entscheidung
    /// synchron sichern kann.
    func confirmStaleWrite() async {
        guard claimStaleWrite(write: true) else { return }
        await resolveClaimedStaleWrite()
    }

    /// Testbare Variante mit austauschbarem Schreiber.
    func confirmStaleWrite(saveEntry: @MainActor (FileEntry) async -> Bool) async {
        guard claimStaleWrite(write: true) else { return }
        await resolveClaimedStaleWrite(saveEntry: saveEntry)
    }

    /// Verwirft nur die aktuell angezeigte Frage; weitere wartende Konflikte
    /// bekommen danach ihre eigene Entscheidung.
    func cancelStaleWrite() {
        guard claimStaleWrite(write: false) else { return }
        claimedStaleWrite = nil
        refreshPendingStaleWrite()
    }

    private func refreshPendingStaleWrite() {
        pendingStaleWrite = staleEntries.first
            .map { PendingStaleWrite(fileName: $0.url.lastPathComponent) }
    }

    /// Gemeinsame Save-Steuerung. Der austauschbare Schreibblock ermöglicht
    /// einen headless Regressionstest, der einen laufenden Save exakt anhalten
    /// kann, ohne echte UI- oder Dateitiming-Rennen zu brauchen.
    @discardableResult
    func save(entry: FileEntry,
              staleCandidate: FileEntry? = nil,
              writeSnapshot: @escaping @Sendable (FileEntry.SaveSnapshot) async throws -> (LoadedData, FileStamp?)) async -> Bool {
        guard let snapshot = entry.beginSaving() else { return !entry.isDirty }
        defer { entry.finishSaving() }

        do {
            let (reloaded, stamp) = try await writeSnapshot(snapshot)
            entry.acceptSaved(snapshot, reloaded: reloaded, stamp: stamp)
            return true
        } catch let error as PartialSaveError {
            entry.lastError = error.localizedDescription
            if case TagError.fileChangedOnDisk = error.underlying, let staleCandidate {
                if !staleEntries.contains(where: { $0 === staleCandidate }) { staleEntries.append(staleCandidate) }
                if pendingStaleWrite == nil { refreshPendingStaleWrite() }
            }
            if !isBatchSaving { alertMessage = error.localizedDescription }
            return false
        } catch TagError.fileChangedOnDisk(let path) where staleCandidate != nil {
            // Kein normaler Fehler, sondern eine Entscheidung: überschreiben
            // oder nicht. Der Puffer bleibt in jedem Fall erhalten.
            entry.lastError = TagError.fileChangedOnDisk(path: path).localizedDescription
            if let staleCandidate,
               !staleEntries.contains(where: { $0 === staleCandidate }) {
                staleEntries.append(staleCandidate)
            }
            if pendingStaleWrite == nil { refreshPendingStaleWrite() }
            return false
        } catch {
            // Der Puffer und das letzte gute Original bleiben unverändert.
            entry.lastError = error.localizedDescription
            if !isBatchSaving {
                alertMessage = String(localized: "Speichern fehlgeschlagen: \(entry.url.lastPathComponent)")
                    + "\n" + error.localizedDescription
            }
            return false
        }
    }

    nonisolated private static func write(snapshot: FileEntry.SaveSnapshot,
                                          to url: URL, kind: MediaKind,
                                          expecting stamp: FileStamp?) throws -> (LoadedData, FileStamp?) {
        try AppFileIO.write(snapshot: snapshot, to: url, kind: kind, expecting: stamp,
                            preferImageSidecar: imageSidecarPreferred, id3Version: preferredID3Version)
    }

    // MARK: - Liste verwalten

    /// Entfernen heißt nur „aus der Liste entfernen“, kann aber einen dirty
    /// Editor ohne sichtbare Rückfrage verschwinden lassen. Deshalb läuft es
    /// durch dieselbe zentrale Save/Discard/Cancel-Steuerung wie Import und
    /// Fenster-Schließen.
    func remove(urls: [URL]) async {
        let targets = Set(urls.map(MediaFormats.canonicalFileURL))
        let affected = entries.filter {
            targets.contains(MediaFormats.canonicalFileURL($0.url))
        }
        await requestDestructiveAction(
            title: String(localized: "Ungespeicherte Änderungen"),
            message: String(localized:
                "Vor dem Entfernen müssen die Änderungen gespeichert oder verworfen werden."),
            entries: affected,
            perform: { [weak self] in self?.removeNow(urls: targets) }
        )
    }

    private func removeNow(urls: Set<URL>) {
        entries.removeAll { urls.contains(MediaFormats.canonicalFileURL($0.url)) }
        selection = Set(selection.filter {
            !urls.contains(MediaFormats.canonicalFileURL($0))
        })
        if selection.isEmpty, let first = entries.first { selection = [first.url] }
    }
}

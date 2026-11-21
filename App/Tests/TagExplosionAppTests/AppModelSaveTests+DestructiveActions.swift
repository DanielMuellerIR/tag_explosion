import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

extension AppModelSaveTests {
    @Test("Synchron geclaimte Entscheidung gewinnt gegen sofortiges Dialog-Dismiss")
    func claimedDecisionCannotBeReplacedByDismiss() async {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/claim-decision.mp3"),
                              loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: "Speichern")]
        let model = AppModel()
        let performed = CallCounter()
        var cancelled = 0

        await model.requestDestructiveAction(
            title: "Test",
            message: "Test",
            entries: [entry],
            perform: { await performed.increment() },
            cancel: { cancelled += 1 }
        )

        // Der Button beansprucht Speichern synchron. SwiftUI kann direkt
        // danach den Binding-Setter mit false auslösen, der hier nur noch
        // erfolglos versuchen darf, Abbrechen zu beanspruchen.
        #expect(model.claimPendingConflict(.save))
        #expect(!model.claimPendingConflict(.cancel))
        await model.resolveClaimedPendingConflict { candidate in
            await model.save(entry: candidate) { _ in
                (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: "Speichern")],
                    artworks: [], audio: nil
                )), nil)
            }
        }

        #expect(await performed.value == 1)
        #expect(cancelled == 0)
        #expect(!entry.isDirty)
        #expect(model.pendingConflict == nil)
    }

    @Test("Entfernen respektiert Abbrechen, Verwerfen und doppelte Anfragen")
    func removeCancelDiscardAndReentrancy() async {
        let entry = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/remove-conflict.mp3"),
            changedTitle: "Nicht gespeichert"
        )
        let model = AppModel()
        model.entries = [entry]
        model.selection = [entry.url]

        await model.remove(urls: [entry.url])
        let firstConflictID = try! #require(model.pendingConflict).id
        // Der zweite Klick darf weder den ersten Auftrag ersetzen noch ohne
        // Entscheidung aus der Liste löschen.
        await model.remove(urls: [entry.url])
        #expect(model.pendingConflict?.id == firstConflictID)
        #expect(model.entries.count == 1)

        await model.resolvePendingConflict(.cancel)
        #expect(model.entries.count == 1)
        #expect(entry.isDirty)

        await model.remove(urls: [entry.url])
        await model.resolvePendingConflict(.discard)
        #expect(model.entries.isEmpty)
        #expect(model.selection.isEmpty)
    }

    @Test("Geschützte Aktion wartet auf laufenden Save und führt danach aus")
    func destructiveActionWaitsForRunningSave() async {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/wait-for-save.mp3"),
                              loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: "Gespeichert")]
        let model = AppModel()
        model.entries = [entry]
        let gate = SaveGate()
        let runningSave = Task { @MainActor in
            await model.save(entry: entry) { _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: "Gespeichert")],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        await gate.waitUntilStarted()

        let removal = Task { @MainActor in
            await model.remove(urls: [entry.url])
        }
        // Der Save-Gate ist noch zu; eine geschützte Aktion darf weder den
        // Editor entfernen noch schon eine Terminierung/Import-Closure ausführen.
        await Task.yield()
        #expect(model.entries.count == 1)
        #expect(entry.isSaving)

        await gate.release()
        _ = await runningSave.value
        await removal.value
        #expect(model.entries.isEmpty)
    }

    @Test("Fehlgeschlagener Konflikt-Save bewahrt Puffer und blockiert Aktion")
    func failedConflictSaveBlocksActionAndPreservesBuffer() async {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/save-failure.mp3"),
                              loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: "Puffer")]
        let model = AppModel()
        let actions = CallCounter()

        await model.requestDestructiveAction(
            title: "Test",
            message: "Test",
            entries: [entry],
            perform: { await actions.increment() }
        )
        await model.resolvePendingConflict(.save) { candidate in
            await model.save(entry: candidate) { _ in
                throw ConflictTestError.expectedSaveFailure
            }
        }

        #expect(await actions.value == 0)
        #expect(entry.original == original)
        #expect(entry.firstValue("TITLE") == "Puffer")
        #expect(entry.isDirty)
        #expect(entry.lastError != nil)
        #expect(model.pendingConflict?.failureMessage
                == "Speichern fehlgeschlagen. Die Aktion wurde nicht ausgeführt.")
    }

    @Test("Terminierung antwortet erst nach einem laufenden Save")
    func terminationWaitsForRunningSaveBeforeReply() async {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/terminate-save.mp3"),
                              loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: "Gespeichert")]
        let model = AppModel()
        model.entries = [entry]
        let gate = SaveGate()
        var replies: [TerminationDecision] = []
        let runningSave = Task { @MainActor in
            await model.save(entry: entry) { _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: "Gespeichert")],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        await gate.waitUntilStarted()

        let termination = Task { @MainActor in
            await model.requestTermination { decision in
                replies.append(decision)
            }
        }
        await Task.yield()
        #expect(replies.isEmpty)

        await gate.release()
        _ = await runningSave.value
        _ = await termination.value
        #expect(replies.count == 1)
        if case .terminateNow = replies.first {
            #expect(Bool(true))
        } else {
            Issue.record("Terminierung wurde nicht freigegeben")
        }
    }

    // MARK: - Exporte und Beenden

    /// Ein Export schreibt an einem Ziel außerhalb der Editor-Puffer. Bleibt er
    /// unangemeldet, meldet `hasUnfinishedWork` bei sauberen Puffern nichts und
    /// ⌘Q beendet die App zwischen Sicherung und atomarem Austausch.
    @Test("Terminierung antwortet erst nach einem laufenden Export")
    func terminationWaitsForRunningExportBeforeReply() async throws {
        let model = AppModel()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-export-terminate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("cover.png")
        let payload = Data([0x89, 0x50, 0x4E, 0x47])

        let gate = ExportGate()
        let runningExport = Task { @MainActor in
            await model.exportData(payload, to: target) { data, url in
                gate.holdUntilReleased()
                try data.write(to: url)
            }
        }
        #expect(await Self.waitForRunningExport(in: model))
        // Der laufende Export allein muss das Beenden schon aufhalten; die
        // Fenster-Registry reicht genau dieses Prädikat weiter.
        #expect(model.hasUnfinishedWork)

        var replies: [TerminationDecision] = []
        let termination = Task { @MainActor in
            await model.requestTermination { decision in
                replies.append(decision)
            }
        }
        await Task.yield()
        #expect(replies.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        gate.release()
        await runningExport.value
        await termination.value
        #expect(replies.count == 1)
        if case .terminateNow = replies.first {
            #expect(Bool(true))
        } else {
            Issue.record("Terminierung wurde nicht freigegeben")
        }
        #expect(!model.hasRunningExports)
        #expect(try Data(contentsOf: target) == payload)
        #expect(model.alertMessage == nil)
    }

    @Test("Während der Beenden-Vorbereitung startet kein zweiter Export")
    func terminationRejectsExportAdmittedAfterWaitingStarted() async throws {
        let model = AppModel()
        let firstGate = ExportGate()
        let firstExport = Task { @MainActor in
            await model.exportData(Data([1]), to: URL(fileURLWithPath: "/tmp/erster-export")) {
                _, _ in firstGate.holdUntilReleased()
            }
        }
        #expect(await Self.waitForRunningExport(in: model))

        let actions = CallCounter()
        let termination = Task { @MainActor in
            await model.requestDestructiveAction(title: "Test", message: "Test",
                                                 entries: [],
                                                 perform: { await actions.increment() })
        }
        var attempts = 0
        while !model.isEditorInteractionLocked, attempts < 5000 {
            await Task.yield()
            attempts += 1
        }
        #expect(model.isEditorInteractionLocked)

        await model.exportData(Data([2]), to: URL(fileURLWithPath: "/tmp/spaeter-export")) {
            _, _ in throw ConflictTestError.expectedSaveFailure
        }
        #expect(model.alertMessage == nil)
        #expect(model.runningExportCount == 1)

        firstGate.release()
        await firstExport.value
        await termination.value
        #expect(await actions.value == 1)
        #expect(!model.hasRunningExports)
    }

    /// Jeder andere Schreibweg der App prüft `isDestructiveActionLocked`, bevor
    /// er loslegt. Beim Verschieben der Cues fehlte die Prüfung: Ein während
    /// der Vorbereitung von ⌘W gestarteter Zeitversatz taucht in der dortigen
    /// Entscheidung nicht mehr auf, und das Fenster schlösse mitten im
    /// Umschreiben der Untertiteldatei.
    @Test("Zeitversatz startet nicht, während eine destruktive Aktion vorbereitet wird")
    func subtitleShiftRefusesWhileDestructiveActionIsPending() async {
        let info = SubtitleInfo(format: .srt, cueCount: 1, firstStartMilliseconds: 0,
                                lastEndMilliseconds: 1000, spanMilliseconds: 1000,
                                encoding: "UTF-8", lineEndings: "LF",
                                languageFromName: nil, flagsFromName: [],
                                header: SubtitleHeader())
        let subtitle = FileEntry(
            url: URL(fileURLWithPath: "/tmp/verschieben-gesperrt.srt"),
            loaded: .sidecar(.subtitle(SubtitleContents(info: info,
                                                        fields: SubtitleEditableFields()))),
            stamp: nil)
        let dirty = FileEntry(url: URL(fileURLWithPath: "/tmp/verschieben-gesperrt.mp3"),
                              loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        dirty.properties = [TagProperty(key: "TITLE", value: "Neu")]

        let model = AppModel()
        model.entries = [subtitle, dirty]
        // Offener Konfliktdialog = laufende destruktive Aktion.
        await model.requestDestructiveAction(title: "Test", message: "Test",
                                             entries: [dirty], perform: {})
        #expect(model.isDestructiveActionLocked)

        #expect(await model.shiftSubtitle(entry: subtitle, seconds: 1) == false)
        #expect(!subtitle.isSaving)
        #expect(subtitle.lastError == nil)
    }

    /// Der JSON-Archivexport ist derselbe Fall: kein Editor-Puffer, aber ein
    /// laufender Schreibauftrag. Ohne Anmeldung sähe `hasUnfinishedWork` nichts.
    @Test("Terminierung antwortet erst nach einem laufenden Archivexport")
    func terminationWaitsForRunningArchiveExport() async throws {
        let model = AppModel()
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/archiv-export.mp3"),
                              loaded: .audio(TagData(properties: [], artworks: [], audio: nil)))
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-archive-\(UUID().uuidString).json")

        let gate = ExportGate()
        let runningExport = Task { @MainActor in
            await model.exportEntries([entry], to: target) { _, _ in
                gate.holdUntilReleased()
            }
        }
        #expect(await Self.waitForRunningExport(in: model))
        #expect(model.hasUnfinishedWork)

        var replies: [TerminationDecision] = []
        let termination = Task { @MainActor in
            await model.requestTermination { replies.append($0) }
        }
        await Task.yield()
        #expect(replies.isEmpty)

        gate.release()
        await runningExport.value
        await termination.value
        #expect(replies.count == 1)
        #expect(!model.hasRunningExports)
        #expect(model.alertMessage == nil)
    }

    /// Der Playlist-Export ist der heikelste der drei: Eine vorhandene Datei
    /// wird erst in den Papierkorb gesichert und dann atomar ersetzt. Genau
    /// dazwischen darf Beenden nicht durchgehen.
    @Test("Terminierung antwortet erst nach einem laufenden Playlist-Export")
    func terminationWaitsForRunningPlaylistExport() async throws {
        let model = AppModel()
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-playlist-\(UUID().uuidString).m3u")

        let gate = ExportGate()
        let runningExport = Task { @MainActor in
            await model.exportPlaylist(files: [URL(fileURLWithPath: "/tmp/lied.mp3")],
                                       to: target, format: .m3u,
                                       absolutePaths: false, title: "") { _, _ in
                gate.holdUntilReleased()
                return []
            }
        }
        #expect(await Self.waitForRunningExport(in: model))
        #expect(model.hasUnfinishedWork)

        var replies: [TerminationDecision] = []
        let termination = Task { @MainActor in
            await model.requestTermination { replies.append($0) }
        }
        await Task.yield()
        #expect(replies.isEmpty)

        gate.release()
        await runningExport.value
        await termination.value
        #expect(replies.count == 1)
        #expect(!model.hasRunningExports)
        #expect(model.alertMessage == nil)
    }

    /// Wartet begrenzt auf die Anmeldung des Exports. Begrenzt, damit ein
    /// unangemeldeter Export den Test scheitern lässt statt ihn hängen zu lassen.
    private static func waitForRunningExport(in model: AppModel) async -> Bool {
        var attempts = 0
        while !model.hasRunningExports, attempts < 5000 {
            await Task.yield()
            attempts += 1
        }
        return model.hasRunningExports
    }
}

/// Hält den synchronen Schreiber eines Exports an. Er läuft in einem
/// Hintergrund-Task außerhalb des MainActors, deshalb wartet er blockierend auf
/// die Freigabe aus dem Test.
private final class ExportGate: @unchecked Sendable {
    private let releaseSignal = DispatchSemaphore(value: 0)

    /// Aus dem Schreiber heraus aufgerufen: wartet auf `release()`.
    func holdUntilReleased() {
        releaseSignal.wait()
    }

    func release() {
        releaseSignal.signal()
    }
}

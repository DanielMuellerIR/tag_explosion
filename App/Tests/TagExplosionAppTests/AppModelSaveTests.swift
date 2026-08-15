// Der Test hält den Hintergrundspeicherweg gezielt an. So lässt sich ohne
// Fenster prüfen, dass neuere Editoränderungen und ein zweiter Speichern-Klick
// nicht im Rennen verlorengehen.
import Foundation
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("AppModel Speichern", .serialized)
@MainActor
struct AppModelSaveTests {

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

    @Test("Import fragt nur für geöffnete Archivziele und schreibt erst nach Entscheidung")
    func importPreflightProtectsOnlyMatchingOpenEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-import-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let importedURL = root.appendingPathComponent("im-archiv.mp3")
        try Data().write(to: importedURL)

        let imported = dirtyAudioEntry(url: importedURL, changedTitle: "Lokaler Puffer")
        let untouched = dirtyAudioEntry(
            url: root.appendingPathComponent("nicht-im-archiv.mp3"),
            changedTitle: "Anderer lokaler Puffer"
        )
        let model = AppModel()
        model.entries = [imported, untouched]
        let applyCalls = CallCounter()
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "im-archiv.mp3", kind: .audio,
                  properties: ["TITLE": ["Aus dem Archiv"]]),
        ])

        await model.importArchive(archive: archive, relativeTo: root) { _, _ in
            await applyCalls.increment()
            throw ConflictTestError.expectedApplyFailure
        }

        let conflict = try #require(model.pendingConflict)
        #expect(conflict.affectedEntryCount == 1)
        #expect(await applyCalls.value == 0)
        #expect(imported.firstValue("TITLE") == "Lokaler Puffer")
        #expect(untouched.firstValue("TITLE") == "Anderer lokaler Puffer")

        await model.resolvePendingConflict(.discard)
        #expect(await applyCalls.value == 1)
        #expect(!imported.isDirty)
        #expect(untouched.isDirty)
    }

    @Test("Externe Importziele werden vollständig angezeigt und erst nach Freigabe geschrieben")
    func externalImportTargetsRequireExplicitApproval() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-external-import-\(UUID().uuidString)")
        let base = parent.appendingPathComponent("archive")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let inside = base.appendingPathComponent("inside.mp3")
        let outside = parent.appendingPathComponent("outside.mp3")
        try Data().write(to: inside)
        try Data().write(to: outside)
        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "inside.mp3", kind: .audio, properties: [:]),
            .init(path: "../outside.mp3", kind: .audio, properties: [:]),
        ])
        let model = AppModel()
        let applyCalls = CallCounter()

        await model.importArchive(archive: archive, relativeTo: base) { _, _ in
            await applyCalls.increment()
            return try TagArchiveIO.apply(
                TagArchive(created: "2026-07-22T00:00:00Z", files: []),
                relativeTo: base, dryRun: true)
        }

        let approval = try #require(model.pendingExternalImport)
        #expect(approval.externalTargetCount == 1)
        #expect(approval.targetPaths == [inside.path, outside.path])
        #expect(await applyCalls.value == 0)

        #expect(model.claimPendingExternalImport(approve: true))
        #expect(!model.claimPendingExternalImport(approve: false))
        await model.resolveClaimedPendingExternalImport()
        #expect(await applyCalls.value == 1)
        #expect(model.pendingExternalImport == nil)
    }

    @Test("Ein während des Dialogs umgebogenes Archivziel wird nicht geschrieben",
          .enabled(if: AudioFixture.isAvailable, "Audio-Fixtures fehlen (ffmpeg)"))
    func retargetedImportDuringConflictDialogIsRejected() async throws {
        // Zwischen der geprüften Zielliste und dem eigentlichen Schreiben liegt
        // der Save/Discard-Dialog. Wird das Ziel in diesem Fenster auf eine
        // ANDERE geöffnete Datei umgebogen, darf der Import sie weder ändern
        // noch ihren ungespeicherten Puffer per Neuladen verwerfen — auch wenn
        // gar kein Ziel außerhalb des Archivordners im Spiel ist.
        let source = try AudioFixture.workingCopy()
        let dir = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let victim = dir.appendingPathComponent("opfer.mp3")
        try FileManager.default.copyItem(at: source, to: victim)

        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [source], to: json, includeCovers: false)
        let victimBytes = try Data(contentsOf: victim)

        let model = AppModel()
        let target = dirtyAudioEntry(url: source, changedTitle: "Puffer des Archivziels")
        let openVictim = dirtyAudioEntry(url: victim, changedTitle: "Puffer des Opfers")
        model.entries = [target, openVictim]

        await model.importArchive(from: json)
        let conflict = try #require(model.pendingConflict)
        #expect(conflict.affectedEntryCount == 1)

        // Der Austausch passiert genau jetzt: Dialog offen, noch nichts geschrieben.
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: victim)

        await model.resolvePendingConflict(.discard)

        #expect(model.alertMessage?.contains("Import fehlgeschlagen") == true)
        #expect(try Data(contentsOf: victim) == victimBytes)
        // Der nie im Dialog berücksichtigte Puffer lebt weiter.
        #expect(openVictim.firstValue("TITLE") == "Puffer des Opfers")
        #expect(openVictim.isDirty)
    }

    @Test("Dasselbe Cover erneut auszuwählen ist keine Änderung")
    func identicalEbookCoverIsNotDirty() {
        // Ein Schreibvorgang für gleiche Bytes wäre ein reiner Nachteil: neue
        // Dateiidentität, neue Änderungszeit, unnötige Sicherung, verwaiste
        // Hardlinks — und inhaltlich passiert nichts.
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03, 0x04,
                          0x05, 0x06, 0x07, 0x08])
        var fields = EbookCoreFields()
        fields.title = "Testbuch"
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-noop.epub"),
                              loaded: .ebook(fields, cover: cover))
        #expect(!entry.isDirty)

        entry.setEbookCover(cover)
        #expect(entry.ebookCoverReplacement == nil)
        #expect(!entry.isDirty)
        #expect(entry.beginSaving() == nil)

        // Ein wirklich anderes Bild bleibt selbstverständlich eine Änderung.
        let other = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                          0x01, 0x02, 0x03, 0x04])
        entry.setEbookCover(other)
        #expect(entry.ebookCoverReplacement == other)
        #expect(entry.isDirty)
    }

    @Test("Cover-Auswahl während eines laufenden Saves geht nicht verloren")
    func coverSelectionDuringSaveSurvives() async {
        // Ablauf O→A speichern→währenddessen wieder O wählen: Während des
        // Schreibens ist `ebookOriginalCover` veraltet (gleich wird A das neue
        // Original). Eine Normalisierung gegen das alte Original würde die
        // Auswahl O zu nil machen — nach dem Save zeigte die Oberfläche A als
        // sauberen Stand, die Auswahl O wäre verloren.
        let originalCover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03, 0x04,
                                  0x05, 0x06, 0x07, 0x08])
        let newCover = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                             0x01, 0x02, 0x03, 0x04])
        var fields = EbookCoreFields()
        fields.title = "Testbuch"
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-race.epub"),
                              loaded: .ebook(fields, cover: originalCover))
        entry.setEbookCover(newCover)
        #expect(entry.isDirty)

        let model = AppModel()
        let gate = SaveGate()
        let savedFields = fields
        let runningSave = Task { @MainActor in
            await model.save(entry: entry) { _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.ebook(savedFields, cover: newCover), nil)
            }
        }
        await gate.waitUntilStarted()

        // Mitten im Save wählt die Person wieder das ursprüngliche Cover.
        entry.setEbookCover(originalCover)

        await gate.release()
        _ = await runningSave.value

        // Das gerade geschriebene Cover ist das neue Original; die spätere
        // Auswahl des alten Originals bleibt als ungespeicherte Änderung.
        #expect(entry.ebookOriginalCover == newCover)
        #expect(entry.ebookCoverReplacement == originalCover)
        #expect(entry.isDirty)
    }

    @Test("Serienindex ohne Serie scheitert vor jeder Datei-Mutation",
          .enabled(if: AudioFixture.isAvailable, "Fixtures fehlen (ffmpeg?)"))
    func invalidSeriesFailsBeforeAnyMutation() async throws {
        // Der Produktions-Schreibweg muss die ungültige Kombination VOR
        // Sicherung und Schreibzugriff ablehnen: Datei bleibt byte-identisch.
        guard let directory = AudioFixture.directory else { return }
        let source = directory.appendingPathComponent("book2.epub")
        // Die EPUB-Fixture entsteht nur, wenn zip verfügbar war.
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-series-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("book2.epub")
        try FileManager.default.copyItem(at: source, to: copy)

        let (loaded, stamp) = try AppModel.readStamped(url: copy, kind: .ebook)
        let entry = FileEntry(url: copy, loaded: loaded, stamp: stamp)
        // Serie löschen, aber einen Index behalten: genau die Kombination,
        // die kein Format speichern kann.
        entry.ebookFields.series = ""
        entry.ebookFields.seriesIndex = "7"
        #expect(entry.isDirty)
        let bytesBefore = try Data(contentsOf: copy)

        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError != nil)
        #expect(try Data(contentsOf: copy) == bytesBefore)
        #expect(entry.isDirty)
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

    @Test("Überlappende Öffnen-Aufträge reservieren Dateien einmal und behalten Auswahl")
    func openReservesInFlightFilesAndKeepsStableSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Musik")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("A.mp3")
        let second = folder.appendingPathComponent("B.flac")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        let model = AppModel()
        let gate = LoadGate()
        let secondOpenCalls = CallCounter()
        let firstOpen = Task { @MainActor in
            await model.open(urls: [first, folder]) { url, _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: url.lastPathComponent)],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        await gate.waitUntilStarted()
        #expect(model.isLoading)

        // Dieser Auftrag sieht beide URLs bereits in `openingURLs` und darf
        // deshalb weder einen zweiten Leser starten noch den Fortschritt beenden.
        let overlappingOpen = Task { @MainActor in
            await model.open(urls: [folder, folder]) { _, _ in
                await secondOpenCalls.increment()
                return (.audio(TagData(properties: [], artworks: [], audio: nil)), nil)
            }
        }
        await overlappingOpen.value
        #expect(await secondOpenCalls.value == 0)
        #expect(model.isLoading)

        await gate.release()
        await firstOpen.value
        #expect(!model.isLoading)
        #expect(model.entries.map(\.url) == [
            MediaFormats.canonicalFileURL(first),
            MediaFormats.canonicalFileURL(second),
        ])
        #expect(model.selection == [MediaFormats.canonicalFileURL(first)])
    }

    @Test("Änderung während Save bleibt dirty, zweites Save startet nicht")
    func saveKeepsNewerBufferAndRejectsDuplicate() async {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/appmodel-save.mp3"),
                              loaded: .audio(original))
        let model = AppModel()
        let gate = SaveGate()
        let duplicateWrites = CallCounter()

        entry.properties = [TagProperty(key: "TITLE", value: "Gespeicherter Stand")]
        let firstSave = Task { @MainActor in
            await model.save(entry: entry) { _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: "Gespeicherter Stand")],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        await gate.waitUntilStarted()
        #expect(entry.isSaving)

        // Diese Änderung passiert nach dem Snapshot und muss im Puffer bleiben.
        entry.properties = [TagProperty(key: "TITLE", value: "Neuere Eingabe")]
        await model.save(entry: entry) { _ in
            await duplicateWrites.increment()
            return (.audio(original), nil)
        }
        #expect(await duplicateWrites.value == 0)

        await gate.release()
        _ = await firstSave.value
        #expect(!entry.isSaving)
        #expect(entry.original.firstValue(for: "TITLE") == "Gespeicherter Stand")
        #expect(entry.firstValue("TITLE") == "Neuere Eingabe")
        #expect(entry.isDirty)
    }

    @Test("Fremde Änderung auf der Platte wird nicht stillschweigend überschrieben",
          .enabled(if: AudioFixture.isAvailable, "Audio-Fixture fehlt"))
    func externalChangeStopsSaveUntilConfirmed() async throws {
        let url = try AudioFixture.workingCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let entry = FileEntry(url: url, loaded: .audio(try TagFile.read(at: url)))
        entry.setSingleValue("TITLE", "Mein Stand")
        let model = AppModel()

        // Ein anderes Programm schreibt, während die Datei geöffnet ist.
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Fremder Stand")], to: url)

        #expect(await model.save(entry: entry) == false)
        #expect(model.pendingStaleWrite?.fileName == url.lastPathComponent)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == "Fremder Stand")
        #expect(entry.isDirty)

        // Erst die ausdrückliche Bestätigung überschreibt.
        await model.confirmStaleWrite()
        #expect(model.pendingStaleWrite == nil)
        #expect(try TagFile.read(at: url).firstValue(for: "TITLE") == "Mein Stand")
        #expect(!entry.isDirty)
    }

    @Test("Ein offener Dateikonflikt blockiert eine konkurrierende Terminierung")
    func staleWriteBlocksConcurrentTermination() async {
        // Der Konflikt wegen einer extern geänderten Datei hat einen eigenen
        // Alert. Eine gleichzeitig gestartete Terminierungsfrage würde einen
        // zweiten Save/Discard/Cancel-Alert aufbauen; beide Entscheidungen
        // könnten dann denselben Editor-Puffer in verschiedener Reihenfolge
        // behandeln. Die Terminierung muss stattdessen sauber abgebrochen
        // werden, bis der erste Konflikt entschieden ist.
        let entry = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-termination.mp3"),
            changedTitle: "Lokaler Puffer")
        let model = AppModel()
        model.entries = [entry]

        await model.save(entry: entry, staleCandidate: entry) { _ in
            throw TagError.fileChangedOnDisk(path: entry.url.path)
        }
        #expect(model.pendingStaleWrite?.fileName == "stale-termination.mp3")

        var reply: TerminationDecision?
        await model.requestTermination { reply = $0 }

        if case .terminateCancel = reply {
            #expect(Bool(true))
        } else {
            Issue.record("Die konkurrierende Terminierung wurde nicht abgebrochen")
        }
        #expect(model.pendingConflict == nil)
        #expect(model.pendingStaleWrite?.fileName == "stale-termination.mp3")
        #expect(entry.isDirty)
    }

    @Test("Mehrere Konflikte im Batch bekommen nacheinander je eigene Frage")
    func multipleStaleConflictsAreQueuedPerFile() async {
        // Zwei Dateien melden im selben Batch eine fremde Änderung. Ein
        // einzelner Merker würde den ersten Konflikt überschreiben: Der Dialog
        // gehörte zur falschen Datei und eine Entscheidung ginge verloren.
        let first = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-erste.mp3"), changedTitle: "Puffer 1")
        let second = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-zweite.mp3"), changedTitle: "Puffer 2")
        let model = AppModel()
        model.entries = [first, second]

        for entry in [first, second] {
            await model.save(entry: entry, staleCandidate: entry) { _ in
                throw TagError.fileChangedOnDisk(path: entry.url.path)
            }
        }
        // Der ERSTE Konflikt bleibt sichtbar, der zweite wartet dahinter.
        #expect(model.pendingStaleWrite?.fileName == "stale-erste.mp3")

        // Bestätigen speichert genau die erste Datei; danach erscheint die
        // Frage zur zweiten.
        var savedNames: [String] = []
        await model.confirmStaleWrite { entry in
            savedNames.append(entry.url.lastPathComponent)
            return await model.save(entry: entry) { _ in
                (.audio(TagData(
                    properties: [TagProperty(key: "TITLE", value: "Puffer 1")],
                    artworks: [], audio: nil
                )), nil)
            }
        }
        #expect(savedNames == ["stale-erste.mp3"])
        #expect(!first.isDirty)
        #expect(model.pendingStaleWrite?.fileName == "stale-zweite.mp3")

        // Abbrechen verwirft nur die zweite Frage; ihr Puffer bleibt dirty.
        model.cancelStaleWrite()
        #expect(model.pendingStaleWrite == nil)
        #expect(second.isDirty)
    }

    @Test("Bestätigtes Überschreiben übersteht den sofort folgenden Dialog-Dismiss")
    func claimedStaleWriteSurvivesTheDismissCallback() async {
        // SwiftUI ruft nach dem Button-Callback sofort den Dismiss-Callback des
        // Alerts. Solange der bestätigte Eintrag erst im Task aus der
        // Warteschlange kam, räumte der Dismiss ihn dazwischen weg: Die
        // bestätigte Datei wurde nicht gespeichert, und die Bestätigung traf
        // stattdessen die NÄCHSTE Datei ohne deren eigene Rückfrage.
        let first = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-erste.mp3"), changedTitle: "Puffer 1")
        let second = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-zweite.mp3"), changedTitle: "Puffer 2")
        let model = AppModel()
        model.entries = [first, second]
        for entry in [first, second] {
            await model.save(entry: entry, staleCandidate: entry) { _ in
                throw TagError.fileChangedOnDisk(path: entry.url.path)
            }
        }
        #expect(model.pendingStaleWrite?.fileName == "stale-erste.mp3")

        // Button „Trotzdem speichern“: Entscheidung synchron beanspruchen …
        #expect(model.claimStaleWrite(write: true))
        // … der unmittelbar folgende Dismiss findet nichts mehr zum Abbrechen.
        #expect(!model.claimStaleWrite(write: false))
        model.cancelStaleWrite()

        var savedNames: [String] = []
        await model.resolveClaimedStaleWrite { entry in
            savedNames.append(entry.url.lastPathComponent)
            return true
        }
        #expect(savedNames == ["stale-erste.mp3"])
        // Die zweite Datei wartet unverändert auf ihre eigene Entscheidung.
        #expect(model.pendingStaleWrite?.fileName == "stale-zweite.mp3")
        #expect(second.isDirty)
    }

    @Test("Eine verschwundene Videodatei wird nicht als read-only Platzhalter geöffnet")
    func readStampedRejectsAVanishedFile() {
        // `readLoaded` fängt für Video-Container einen Lesefehler bewusst als
        // read-only-Platzhalter ab. Ohne die Stempel-Pflicht landete eine gar
        // nicht mehr vorhandene .avi als scheinbar erfolgreich geöffneter
        // Eintrag in der Liste.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verschwunden-\(UUID().uuidString).avi")
        #expect(throws: TagError.cannotOpen(path: url.path)) {
            _ = try AppModel.readStamped(url: url, kind: .audio)
        }
    }

    @Test("Lesen liefert Inhalt und Stempel als konsistenten Schnappschuss")
    func readStampedRetriesUntilContentAndStampMatch() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-read-stamped-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wackelig.mp3")
        try Data("erster Stand".utf8).write(to: url)

        // Der erste Leseversuch wird von einer "fremden" Änderung überlappt:
        // Der Leser verändert die Datei nach dem Lesen selbst. Ein getrennt
        // erhobener Stempel gehörte dann zur neuen Datei, der Inhalt zur alten.
        var reads = 0
        let (_, stamp) = try AppModel.readStamped(url: url, kind: .audio) { _, _ in
            reads += 1
            let loaded = LoadedData.audio(TagData(properties: [], artworks: [], audio: nil))
            if reads == 1 {
                try Data("fremde Änderung mit anderer Länge".utf8).write(to: url)
            }
            return loaded
        }

        // Genau ein Wiederholungsversuch, und der Stempel passt zum Endstand.
        #expect(reads == 2)
        #expect(stamp == FileStamp.current(of: url))

        // Kommt die Datei nie zur Ruhe, bricht das Lesen ab, statt einen
        // inkonsistenten Zustand zu liefern.
        var restlessReads = 0
        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            _ = try AppModel.readStamped(url: url, kind: .audio) { _, _ in
                restlessReads += 1
                try Data("Änderung Nr. \(restlessReads) ...".utf8).write(to: url)
                return LoadedData.audio(TagData(properties: [], artworks: [], audio: nil))
            }
        }
    }
}

/// Zugriff auf die Audio-Fixtures des Root-Pakets. Der Generator wird bei
/// Bedarf selbst ausgeführt (idempotent) — sonst hinge dieser App-Test davon
/// ab, dass vorher zufällig die Root-Tests liefen. Übersprungen wird nur noch,
/// wenn die Erzeugung selbst nicht möglich ist (ffmpeg fehlt).
private enum AudioFixture {
    static let directory: URL? = {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TagExplosionAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // Repo-Wurzel
        let generated = repoRoot
            .appendingPathComponent("Tests/TagExplosionCoreTests/Fixtures/generated")
        let sample = generated.appendingPathComponent("sample.mp3")
        if !FileManager.default.fileExists(atPath: sample.path) {
            let script = repoRoot.appendingPathComponent(
                "Tests/TagExplosionCoreTests/Fixtures/generate_fixtures.sh")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return FileManager.default.fileExists(atPath: sample.path) ? generated : nil
    }()

    static var isAvailable: Bool { directory != nil }

    static func workingCopy() throws -> URL {
        guard let directory else { throw ConflictTestError.expectedSaveFailure }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-app-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("sample.mp3")
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("sample.mp3"), to: target)
        return target
    }
}

private enum ConflictTestError: Error {
    case expectedApplyFailure
    case expectedSaveFailure
}

@MainActor
private func dirtyAudioEntry(url: URL, changedTitle: String) -> FileEntry {
    let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                           artworks: [], audio: nil)
    let entry = FileEntry(url: url, loaded: .audio(original))
    entry.properties = [TagProperty(key: "TITLE", value: changedTitle)]
    return entry
}

/// Zwei kleine Actors machen den Testablauf deterministisch: Kein sleep und
/// damit kein zufälliges Timing-Rennen auf langsamen oder schnellen Rechnern.
private actor SaveGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

/// Der Lese-Gate macht überlappende Öffnen-Aufträge ohne zeitabhängige Sleeps
/// reproduzierbar: Der erste Auftrag reserviert seine URLs, bevor er wartet.
private actor LoadGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !started else { return }
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters = []
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("Lesepfad")
@MainActor
struct AppModelReadTests {

    /// Container ohne TagLib-Leser (AVI) müssen sich trotzdem öffnen lassen —
    /// schreibgeschützt, damit der Technik-Tab nutzbar bleibt.
    @Test("AVI öffnet schreibgeschützt statt mit einem Fehler")
    func aviOpensReadOnly() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-avi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.avi")
        // Der Inhalt ist bewusst kein gültiges AVI: TagLib kann AVI generell
        // nicht lesen, der Fallback darf nicht vom Dateiinhalt abhängen.
        try Data("nicht lesbar".utf8).write(to: url)

        let loaded = try AppModel.readLoaded(url: url, kind: .audio)
        guard case .audio(let data) = loaded else {
            Issue.record("Erwartet wurde ein Audio-Zustand")
            return
        }
        #expect(data.isReadOnly)
        #expect(data.properties.isEmpty)
    }

    @Test("Eine kaputte Audiodatei meldet weiterhin einen Fehler")
    func brokenAudioStillFails() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-broken-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("kaputt.flac")
        try Data("kein FLAC".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            _ = try AppModel.readLoaded(url: url, kind: .audio)
        }
    }
}

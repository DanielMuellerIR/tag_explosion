import EInvoiceCore
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionApp
import TagExplosionCore

@Suite("AppModel Speichern", .serialized)
@MainActor
struct AppModelSaveTests {
    @Test("Batch-Speichern sichert überlappende Kapitel und leere SYLT und erhält beide")
    func batchSaveWithLegacyAudioDetails() async throws {
        let first = try MediaTestFixtures.workingCopy()
        let folder = first.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let second = folder.appendingPathComponent("second.mp3")
        try FileManager.default.copyItem(at: first, to: second)
        try ID3TestFixtures.installLegacyDetails(at: first)
        let original = try TagFile.read(at: first)
        let entries = try [first, second].map { url in
            let entry = FileEntry(url: url, loaded: .audio(try TagFile.read(at: url)))
            entry.setSingleValue("TITLE", "Batch title")
            return entry
        }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppModel.autoBackupDefaultsKey)
        let model = AppModel(preferences: AppPreferences(defaults: defaults))
        model.entries = entries
        #expect(await model.saveEntries(entries))
        #expect(model.batchResults.allSatisfy { $0.status == .success })
        let after = try TagFile.read(at: first)
        #expect(after.firstValue(for: "TITLE") == "Batch title")
        #expect(after.chapters == original.chapters)
        #expect(after.syncedLyricsLanguage == "eng")
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("tags-backup-") }
        let backup = try #require(backups.first)
        let archived = try TagArchiveIO.load(backup)
        #expect(archived.files.first(where: { $0.path == first.lastPathComponent })?.chapters == original.chapters)
    }


    @Test("Direkte Wiederherstellung bleibt für Rechnungen ohne Bearbeitungspuffer möglich")
    func invoiceReloadingMutation() async throws {
        let xml = """
        <Invoice xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
          xmlns:b="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"><b:ID>R-1</b:ID></Invoice>
        """
        let original = try EInvoiceReader.document(fromXML: Data(xml.utf8), source: .xmlFile)
        let restored = try EInvoiceReader.document(fromXML: Data(xml.replacingOccurrences(of: "R-1", with: "R-2").utf8), source: .xmlFile)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/invoice.pdf"), loaded: .invoice(original))
        let model = AppModel()
        #expect(try await model.reloadAfterMutation(entry: entry) { (.invoice(restored), nil) })
        #expect(entry.invoiceDocument?.summary.invoiceNumber == "R-2")
        #expect(!entry.isSaving)
    }

    @Test("Direkte Dateiaktionen erhalten spätere Eingaben und ersetzen nur bestätigte Puffer",
          arguments: [false, true], [false, true])
    func reloadingMutationPreservesLaterEdits(initiallyDirty: Bool, editDuringWrite: Bool) async throws {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")], artworks: [], audio: nil)
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/reloading-write.mp3"), loaded: .audio(original))
        if initiallyDirty { entry.setSingleValue("TITLE", "Bestätigter Puffer") }
        let model = AppModel()
        let gate = SaveGate()
        let newStamp = FileStamp(size: 42, modified: 123)
        let task = Task {
            try await model.reloadAfterMutation(entry: entry) {
                await gate.markStarted()
                await gate.waitForRelease()
                return (.audio(TagData(properties: [TagProperty(key: "TITLE", value: "Neuer Plattenstand")],
                                       artworks: [], audio: nil)), newStamp)
            }
        }
        await gate.waitUntilStarted()
        #expect(entry.isSaving)
        if editDuringWrite { entry.setSingleValue("TITLE", "Währenddessen eingegeben") }
        await gate.release()
        #expect(try await task.value)
        #expect(entry.firstValue("TITLE") == (editDuringWrite ? "Währenddessen eingegeben" : "Neuer Plattenstand"))
        #expect(entry.original.properties.first?.value == "Neuer Plattenstand")
        #expect(entry.diskStamp == newStamp)
        #expect(entry.isDirty == editDuringWrite)
        #expect(!entry.isSaving)
    }

    @Test("Bestätigtes Überschreiben erfasst den aktuellen XMP-Stand",
          .enabled(if: MediaTestFixtures.isAvailable && (try? ExifTool.locateExecutable()) != nil,
                   "Bild-Fixture oder exiftool fehlt"), arguments: [false, true])
    func confirmedImageSidecarOverwrite(existing: Bool) async throws {
        let copy = try MediaTestFixtures.workingCopy("cover.jpg")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let sidecar = MediaFormats.sidecarURL(for: copy)
        func writeSidecar(_ title: String) throws {
            try Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:title="\(title)" dc:creator="Fremder Autor"/>
            </rdf:RDF></x:xmpmeta>
            """.utf8).write(to: sidecar)
        }
        if existing { try writeSidecar("Alter Titel") }
        let (loaded, stamp) = try AppModel.readStamped(url: copy, kind: .image)
        let entry = FileEntry(url: copy, loaded: loaded, stamp: stamp)
        entry.imageFields.title = "Eigener Titel"
        try writeSidecar("Fremder neuer Titel")
        let foreign = try Data(contentsOf: sidecar)
        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(try Data(contentsOf: sidecar) == foreign)
        #expect(entry.isDirty)
        #expect(await model.save(entry: entry, ignoringDiskChange: true))
        #expect(!entry.isDirty)
        let saved = try ExifTool.readCoreFields(url: copy)
        #expect(saved.title == "Eigener Titel")
        #expect(saved.creator == "Fremder Autor")
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

    @Test("Reiner Feld-Save: erneut gewähltes Originalcover bleibt nicht dauerhaft dirty")
    func reselectedOriginalCoverDuringFieldSaveBecomesClean() async {
        // Während eines reinen Feld-Saves (Cover unangetastet) wählt die
        // Person das unveränderte Originalcover erneut. `setEbookCover` darf
        // während des Saves nicht normalisieren (siehe Test darüber); nach dem
        // Read-back ist das Cover in der Datei aber identisch zur Auswahl —
        // der Eintrag muss wieder sauber sein, sonst tauschte der nächste
        // Save die Datei ohne Inhaltsänderung aus (samt Sicherung).
        let originalCover = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03, 0x04,
                                  0x05, 0x06, 0x07, 0x08])
        var fields = EbookCoreFields()
        fields.title = "Alter Titel"
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/cover-feldsave.epub"),
                              loaded: .ebook(fields, cover: originalCover))
        var changedFields = fields
        changedFields.title = "Neuer Titel"
        let changed = changedFields
        entry.ebookFields = changed
        #expect(entry.isDirty)

        let model = AppModel()
        let gate = SaveGate()
        let runningSave = Task { @MainActor in
            await model.save(entry: entry) { _ in
                await gate.markStarted()
                await gate.waitForRelease()
                return (.ebook(changed, cover: originalCover), nil)
            }
        }
        await gate.waitUntilStarted()

        // Mitten im Feld-Save wird das unveränderte Originalcover erneut gewählt.
        entry.setEbookCover(originalCover)
        #expect(entry.ebookCoverReplacement == originalCover)

        await gate.release()
        _ = await runningSave.value

        #expect(entry.ebookCoverReplacement == nil)
        #expect(!entry.isDirty)
        #expect(entry.beginSaving() == nil)
    }

    @Test("Serienindex ohne Serie: der EPUB-Produktionsweg speichert ihn",
          .enabled(if: MediaTestFixtures.isAvailable, "Fixtures fehlen (ffmpeg?)"))
    func bareSeriesIndexSavesOnEpub() async throws {
        // EPUB kennt mit calibre:series_index einen Speicherort auch ohne
        // Serie; der Produktions-Schreibweg muss diesen Zustand speichern
        // können, sonst wäre ein Archiv-Restore desselben Zustands unmöglich.
        // Dass Formate OHNE diesen Speicherort weiterhin vor jeder Mutation
        // ablehnen, deckt der Core-Test "Serienindex ohne Serie: EPUB
        // speichert ihn, andere Formate lehnen ab" ab.
        guard let directory = MediaTestFixtures.availableDirectory else { return }
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
        entry.ebookFields.series = ""
        entry.ebookFields.seriesIndex = "7"
        #expect(entry.isDirty)

        let model = AppModel()
        #expect(await model.save(entry: entry) == true)
        #expect(entry.lastError == nil)
        #expect(!entry.isDirty)
        let restored = try EbookTool.readCoreFields(url: copy)
        #expect(restored.series.isEmpty)
        #expect(restored.seriesIndex == "7")
    }

    @Test("Dokument: Speichern über den Produktionsweg, unspeicherbares Feld scheitert vorab",
          .enabled(if: MediaTestFixtures.isAvailable, "Fixtures fehlen (ffmpeg?)"))
    func documentSavesAndRejectsUnsupportedField() async throws {
        guard let directory = MediaTestFixtures.availableDirectory else { return }
        let source = directory.appendingPathComponent("doc.odt")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-document-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("doc.odt")
        try FileManager.default.copyItem(at: source, to: copy)

        let (loaded, stamp) = try AppModel.readStamped(url: copy, kind: .document)
        let entry = FileEntry(url: copy, loaded: loaded, stamp: stamp)
        #expect(entry.kind == .document)
        #expect(entry.displayTitle == "Testtext")
        entry.documentFields.title = "Aus der App"
        entry.documentFields.setCustom("generator", "Tag Explosion Test")
        #expect(entry.isDirty)

        let model = AppModel()
        #expect(await model.save(entry: entry) == true)
        #expect(entry.lastError == nil)
        #expect(!entry.isDirty)
        let restored = try DocumentTool.readCoreFields(url: copy)
        #expect(restored.title == "Aus der App")
        #expect(restored.customValue(for: "generator") == "Tag Explosion Test")

        // ODF kennt keine Kategorie: Der Save scheitert vor jeder Mutation,
        // der Puffer bleibt dirty.
        let bytes = try Data(contentsOf: copy)
        entry.documentFields.category = "Kein Ort"
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError?.contains("category") == true)
        #expect(entry.isDirty)
        #expect(try Data(contentsOf: copy) == bytes)
    }

    @Test("Ungültige Bild-GPS-Werte scheitern vor jeder Datei-Mutation")
    func invalidImageGPSFailsBeforeAnyMutation() async throws {
        guard let directory = MediaTestFixtures.availableDirectory else { return }
        let source = directory.appendingPathComponent("cover.jpg")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-image-guard-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("cover.jpg")
        try FileManager.default.copyItem(at: source, to: copy)

        let (loaded, stamp) = try AppModel.readStamped(url: copy, kind: .image)
        let entry = FileEntry(url: copy, loaded: loaded, stamp: stamp)
        entry.imageFields.gpsLatitude = "91"
        entry.imageFields.gpsLongitude = "181"
        #expect(entry.isDirty)
        let bytesBefore = try Data(contentsOf: copy)

        let model = AppModel()
        #expect(await model.save(entry: entry) == false)
        #expect(entry.lastError != nil)
        #expect(try Data(contentsOf: copy) == bytesBefore)
        #expect(entry.isDirty)
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

    @Test("Lyrics und Video-NFO behalten Eingaben nach dem Speichersnapshot",
          arguments: [false, true], [false, true])
    func optionalAudioChangesDuringSave(alreadyChanged: Bool, editDuringSave: Bool) async {
        let initialLines = [SyncedLyricLine(milliseconds: 0, text: "Original")]
        let savedLines = [SyncedLyricLine(milliseconds: 0, text: "Gespeichert")]
        let newerLines = [SyncedLyricLine(milliseconds: 0, text: "Weiter")]
        let original = TagData(properties: [], artworks: [], audio: nil,
                               lyricsLanguage: "deu", syncedLyrics: initialLines,
                               supportsSyncedLyrics: true)
        let nfo = NFOContents(rootName: "movie", fields: NFOFields(title: "Original"),
                              info: [], urls: [])
        let sidecars = AudioSidecars(nfo: NFOSidecarReading(
            url: URL(fileURLWithPath: "/tmp/save-fields.nfo"), contents: nfo, stamp: nil))
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/save-fields.mp4"),
                              loaded: .audio(original, sidecars: sidecars))
        entry.setSingleValue("TITLE", "Titeländerung")
        if alreadyChanged {
            entry.syncedLyrics = savedLines
            entry.lyricsLanguage = "eng"
            entry.videoNFOFields.title = "Gespeichert"
        }
        let model = AppModel()
        let gate = SaveGate()
        let save = Task { @MainActor in
            await model.save(entry: entry) { snapshot in
                guard case .audio(let audio) = snapshot else {
                    throw ConflictTestError.expectedSaveFailure
                }
                await gate.markStarted()
                await gate.waitForRelease()
                var reloaded = original
                reloaded.properties = audio.properties
                reloaded.syncedLyrics = audio.syncedLyrics ?? original.syncedLyrics
                reloaded.lyricsLanguage = audio.lyricsLanguage ?? original.lyricsLanguage
                let writtenNFO = NFOContents(rootName: "movie",
                    fields: audio.nfo?.fields ?? nfo.fields, info: [], urls: [])
                return (.audio(reloaded, sidecars: AudioSidecars(nfo: NFOSidecarReading(
                    url: sidecars.nfo!.url, contents: writtenNFO, stamp: nil))), nil)
            }
        }
        await gate.waitUntilStarted()
        if editDuringSave {
            entry.syncedLyrics = newerLines
            entry.lyricsLanguage = "fra"
            entry.videoNFOFields.title = "Weiter"
        }
        await gate.release()
        #expect(await save.value)
        #expect(entry.original.syncedLyrics == (alreadyChanged ? savedLines : initialLines))
        #expect(entry.syncedLyrics == (editDuringSave ? newerLines : alreadyChanged ? savedLines : initialLines))
        #expect(entry.lyricsLanguage == (editDuringSave ? "fra" : alreadyChanged ? "eng" : "deu"))
        #expect(entry.videoNFOFields.title == (editDuringSave ? "Weiter" : alreadyChanged ? "Gespeichert" : "Original"))
        #expect(entry.isDirty == editDuringSave)
    }

    // MARK: - Änderungen auf dem Datenträger

    @Test("Fremde Änderung auf der Platte wird nicht stillschweigend überschrieben",
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixture fehlt"))
    func externalChangeStopsSaveUntilConfirmed() async throws {
        let url = try MediaTestFixtures.workingCopy()
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

    /// Solange eine beansprucht Entscheidung noch läuft — sie kann auf das Ende
    /// des seriellen Batches warten —, darf kein zweiter Dialog erscheinen:
    /// `claimStaleWrite` nähme dessen Klick nicht an, der Alert schlösse sich
    /// und käme sofort wieder (Review-Fund 2026-09-10).
    @Test("Der zweite Konflikt wartet, bis die beanspruchte Entscheidung fertig ist")
    func secondStaleConflictWaitsForTheClaimedDecision() async {
        let first = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-claim-1.mp3"), changedTitle: "Puffer 1")
        let second = dirtyAudioEntry(
            url: URL(fileURLWithPath: "/tmp/stale-claim-2.mp3"), changedTitle: "Puffer 2")
        let model = AppModel()
        model.entries = [first, second]

        await model.save(entry: first, staleCandidate: first) { _ in
            throw TagError.fileChangedOnDisk(path: first.url.path)
        }
        #expect(model.pendingStaleWrite?.fileName == "stale-claim-1.mp3")
        #expect(model.claimStaleWrite(write: true))
        #expect(model.pendingStaleWrite == nil)

        // Die zweite Datei meldet ihren Konflikt, während die erste
        // Entscheidung noch aussteht.
        await model.save(entry: second, staleCandidate: second) { _ in
            throw TagError.fileChangedOnDisk(path: second.url.path)
        }
        #expect(model.pendingStaleWrite == nil)

        var savedNames: [String] = []
        await model.resolveClaimedStaleWrite { entry in
            savedNames.append(entry.url.lastPathComponent)
            return true
        }
        #expect(savedNames == ["stale-claim-1.mp3"])
        // Jetzt erst — und jetzt nimmt der Dialog auch einen Klick an.
        #expect(model.pendingStaleWrite?.fileName == "stale-claim-2.mp3")
        #expect(model.claimStaleWrite(write: false))
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

    enum ConflictTestError: Error {
        case expectedApplyFailure
        case expectedSaveFailure
    }

    func dirtyAudioEntry(url: URL, changedTitle: String) -> FileEntry {
        let original = TagData(properties: [TagProperty(key: "TITLE", value: "Original")],
                               artworks: [], audio: nil)
        let entry = FileEntry(url: url, loaded: .audio(original))
        entry.properties = [TagProperty(key: "TITLE", value: changedTitle)]
        return entry
    }

    /// Kontrollierter Start und Abschluss für Lese- und Speicheraufträge.
    /// Derselbe Ablauf benötigt weder Sleeps noch getrennte Helferkopien.
    actor SaveGate {
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

    actor CallCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }
}

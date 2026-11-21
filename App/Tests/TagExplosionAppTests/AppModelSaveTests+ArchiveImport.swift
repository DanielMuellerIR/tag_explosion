import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionApp
import TagExplosionCore

extension AppModelSaveTests {
    @Test("Import lädt einen separat geöffneten XMP-Editor neu")
    func importReloadsSeparateXMP() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("cover.jpg")
        try FileManager.default.copyItem(at: AppTestFixtures.directory.appendingPathComponent("cover.jpg"), to: image)
        let sidecar = MediaFormats.sidecarURL(for: image)
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>".utf8).write(to: sidecar)
        var archive = try TagArchiveIO.build(files: [image], baseDirectory: folder, includeCovers: true)
        archive.files[0].image?.title = "Imported XMP title"
        let json = folder.appendingPathComponent("tags.json")
        try JSONEncoder().encode(archive).write(to: json)
        let entry = FileEntry(url: sidecar, loaded: .image(try ExifTool.readCoreReading(url: sidecar)))
        let model = AppModel(); model.entries = [entry]
        await model.importArchive(from: json)
        #expect(try ExifTool.readCoreReading(url: sidecar).fields.title == "Imported XMP title")
        #expect(entry.imageFields.title == "Imported XMP title")
        #expect(!entry.isDirty)
    }

    @Test("Import mit XMP am ersten Bild lädt nachfolgende Audioeditoren neu")
    func importWithSidecarReloadsFollowingAudio() async throws {
        let audio = try MediaTestFixtures.workingCopy()
        let folder = audio.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("cover.jpg")
        try FileManager.default.copyItem(at: AppTestFixtures.directory.appendingPathComponent("cover.jpg"), to: image)
        let sidecar = MediaFormats.sidecarURL(for: image)
        let originalSidecar = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>".utf8)
        try originalSidecar.write(to: sidecar)
        var archive = try TagArchiveIO.build(files: [image, audio], baseDirectory: folder, includeCovers: true)
        archive.files[1].properties?["TITLE"] = ["Imported audio title"]
        let json = folder.appendingPathComponent("tags.json")
        try JSONEncoder().encode(archive).write(to: json)
        let entry = FileEntry(url: audio, loaded: .audio(try TagFile.read(at: audio)))
        let imageEntry = FileEntry(url: image, loaded: .image(try ExifTool.readCoreReading(url: image)))
        let model = AppModel()
        model.entries = [imageEntry, entry]
        await model.importArchive(from: json)
        #expect(try TagFile.read(at: audio).firstValue(for: "TITLE") == "Imported audio title")
        #expect(entry.firstValue("TITLE") == "Imported audio title")
        #expect(!entry.isDirty)
        #expect(try Data(contentsOf: sidecar) == originalSidecar)
        #expect(!imageEntry.isDirty)
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
          .enabled(if: MediaTestFixtures.isAvailable, "Audio-Fixtures fehlen (ffmpeg)"))
    func retargetedImportDuringConflictDialogIsRejected() async throws {
        // Zwischen der geprüften Zielliste und dem eigentlichen Schreiben liegt
        // der Save/Discard-Dialog. Wird das Ziel in diesem Fenster auf eine
        // ANDERE geöffnete Datei umgebogen, darf der Import sie weder ändern
        // noch ihren ungespeicherten Puffer per Neuladen verwerfen — auch wenn
        // gar kein Ziel außerhalb des Archivordners im Spiel ist.
        let source = try MediaTestFixtures.workingCopy()
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
}

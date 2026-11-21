import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

extension TagArchiveTests {
    // MARK: - XMP-Ziele

    @Test("Backup mit gemeinsamem XMP-Ziel scheitert vor dem Anlegen einer Sicherung")
    func sharedSidecarBackupFailsBeforePublication() throws {
        let folder = try makeFolder(["cover.jpg", "cover.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let sidecar = folder.appendingPathComponent("cover.xmp")
        try Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>".utf8).write(to: sidecar)
        let files = [folder.appendingPathComponent("cover.jpg"), folder.appendingPathComponent("cover.png")]
        let export = folder.appendingPathComponent("tags.json")
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.export(files: files, to: export, includeCovers: true) }
        #expect(!FileManager.default.fileExists(atPath: export.path))
        #expect(throws: TagArchiveError.self) { _ = try TagArchiveIO.writeBackups(files: files) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("tags-backup-") }.isEmpty)
    }

    @Test("Externe XMP-Verknüpfungen gehören zur Zielfreigabe und werden erneut geprüft")
    func externalSidecarRequiresApproval() throws {
        let folder = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let image = base.appendingPathComponent("cover.jpg")
        try FileManager.default.copyItem(at: folder.appendingPathComponent("cover.jpg"), to: image)
        let external = folder.appendingPathComponent("external.xmp")
        let second = folder.appendingPathComponent("second.xmp")
        let xmp = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'/></x:xmpmeta>".utf8)
        try xmp.write(to: external)
        try xmp.write(to: second)
        let sidecar = MediaFormats.sidecarURL(for: image)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: external)
        let archive = TagArchive(created: "2026-10-06T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: ImageCoreFields(title: "Neuer Titel")),
        ])
        #expect(throws: TagArchiveError.self) {
            _ = try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false)
        }
        #expect(try Data(contentsOf: external) == xmp)
        let targets = try TagArchiveIO.validatedTargets(archive, relativeTo: base, allowExternalTargets: true)
        #expect(targets == [MediaFormats.canonicalFileURL(image), MediaFormats.canonicalFileURL(external)])
        #expect(TagArchiveIO.externalTargets(targets, relativeTo: base) == [external])
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: second)
        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            _ = try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
                approvedTargets: targets, allowExternalTargets: true,
                afterValidation: {}, backUp: { _ in Issue.record("Nicht freigegebenes Ziel erreicht Backup") })
        }
        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: external)
        let report = try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
            approvedTargets: targets, allowExternalTargets: true, afterValidation: {
                try FileManager.default.removeItem(at: sidecar)
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: second)
            }, backUp: { _ in Issue.record("Umgebogenes Ziel erreicht Backup") })
        #expect(report.failures.count == 1)
        #expect(try Data(contentsOf: external) == xmp)
        #expect(try Data(contentsOf: second) == xmp)
    }

    @Test("Gemeinsame XMP-Ziele werden vor der ersten Archivmutation abgelehnt", arguments: [false, true])
    func sharedSidecarTargetsAreRejected(hardlink: Bool) throws {
        let folder = try makeFolder(["cover.jpg", "cover.png"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("cover.jpg")
        let second = folder.appendingPathComponent(hardlink ? "second.png" : "cover.png")
        if hardlink { try FileManager.default.moveItem(at: folder.appendingPathComponent("cover.png"), to: second) }
        let xmp = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)
        let sidecar = MediaFormats.sidecarURL(for: first)
        try xmp.write(to: sidecar)
        if hardlink { try FileManager.default.linkItem(at: sidecar, to: MediaFormats.sidecarURL(for: second)) }
        let firstBytes = try Data(contentsOf: first), secondBytes = try Data(contentsOf: second)
        let archive = TagArchive(created: "2026-10-06T00:00:00Z", files: [
            .init(path: first.lastPathComponent, kind: .image, image: ImageCoreFields(title: "Eins")),
            .init(path: second.lastPathComponent, kind: .image, image: ImageCoreFields(title: "Zwei")),
        ])
        #expect(throws: TagArchiveError.self) {
            _ = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false,
                afterValidation: {}, backUp: { _ in Issue.record("Doppeltes Ziel erreicht Backup") })
        }
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
        #expect(try Data(contentsOf: sidecar) == xmp)
    }

    @Test("Ein Archiv-No-op erkennt fremde XMP-Änderungen unmittelbar vor Erfolg", arguments: [false, true])
    func sidecarNoopRetargetIsRejected(retarget: Bool) throws {
        let folder = try makeFolder(["cover.jpg"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("cover.jpg")
        let sidecar = MediaFormats.sidecarURL(for: image)
        let xmp = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)
        try xmp.write(to: sidecar)
        let archive = try TagArchiveIO.build(files: [image], baseDirectory: folder, includeCovers: false)
        let second = folder.appendingPathComponent("other.xmp")
        let foreign = Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><!--fremd--></x:xmpmeta>".utf8)
        try foreign.write(to: second)
        let report = try TagArchiveIO.apply(archive, relativeTo: folder, dryRun: false,
            afterValidation: {}, beforeNoopReturn: { _ in
                if retarget {
                    try FileManager.default.removeItem(at: sidecar)
                    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: second)
                } else { try foreign.write(to: sidecar) }
            }, backUp: { _ in Issue.record("Geändertes No-op-Ziel erreicht Backup") })
        #expect(report.unchanged.isEmpty)
        #expect(report.failures.map(\.path) == ["cover.jpg"])
        #expect(try Data(contentsOf: sidecar) == foreign)
    }

    // MARK: - Mediendateien

    @Test("Symlink-Ziele im Archiv werden vor der ersten Mutation dedupliziert")
    func symlinkArchiveTargetsDoNotMutateFirstEntry() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let alias = dir.appendingPathComponent("alias.mp3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mp3)
        let bytesBefore = try Data(contentsOf: mp3)
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "alias.mp3", kind: .audio,
                  properties: ["TITLE": ["Zweites Ziel"]]),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "alias.mp3",
            detail: "different paths resolve to the same target"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Original")
    }

    @Test("Hardlink-Ziele im Archiv werden vor der ersten Mutation dedupliziert")
    func hardlinkArchiveTargetsDoNotMutateFirstEntry() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let alias = dir.appendingPathComponent("hardlink.mp3")
        try FileManager.default.linkItem(at: mp3, to: alias)
        let bytesBefore = try Data(contentsOf: mp3)
        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Darf nicht geschrieben werden"]]),
            .init(path: "hardlink.mp3", kind: .audio,
                  properties: ["TITLE": ["Zweites Ziel"]]),
        ])

        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "hardlink.mp3",
            detail: "different paths resolve to the same target"
        )) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == bytesBefore)
    }

    @Test("Atomare Ersetzung am gleichen Pfad nach der Zielprüfung wird abgelehnt")
    func samePathReplacementAfterValidationIsRejected() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Geprüfter Stand")],
            artworks: [], to: target)
        let replacement = dir.appendingPathComponent("replacement.mp3")
        try FileManager.default.copyItem(at: target, to: replacement)
        try TagFile.write(
            properties: [TagProperty(key: "TITLE", value: "Fremder Ersatz")],
            artworks: [], to: replacement)
        let replacementBytes = try Data(contentsOf: replacement)
        let archive = TagArchive(created: "2026-08-10T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Archivwert"]], artworks: []),
        ])

        let report = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: false,
            afterValidation: {
                try TestFiles.replaceAtomically(target, with: replacement)
            })

        #expect(report.applied.isEmpty)
        #expect(report.failures.map(\.path) == ["sample.mp3"])
        #expect(report.failures.first?.message.contains("targetChangedAfterValidation") == true)
        #expect(try Data(contentsOf: target) == replacementBytes)
        #expect(try TagFile.read(at: target).firstValue(for: "TITLE") == "Fremder Ersatz")
    }

    @Test("Ein Archiv-No-op prüft den verglichenen Stand unmittelbar vor Erfolg")
    func noopChangedAfterComparisonIsRejected() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("sample.mp3")
        let archive = try TagArchiveIO.build(
            files: [target], baseDirectory: dir, includeCovers: true)

        let report = try TagArchiveIO.apply(
            archive, relativeTo: dir, dryRun: false,
            afterValidation: {},
            beforeNoopReturn: { url in
                try TagFile.write(
                    properties: [TagProperty(key: "TITLE", value: "Fremd nach Vergleich")],
                    artworks: [], to: url)
            })

        #expect(report.unchanged.isEmpty)
        #expect(report.failures.map(\.path) == ["sample.mp3"])
        #expect(try TagFile.read(at: target).firstValue(for: "TITLE")
                == "Fremd nach Vergleich")
    }

    @Test("Externe Archivziele brauchen eine ausdrückliche Freigabe")
    func externalArchiveTargetRequiresApproval() throws {
        let parent = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let base = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let external = parent.appendingPathComponent("sample.mp3")
        let bytesBefore = try Data(contentsOf: external)
        let archive = TagArchive(created: "2026-07-22T00:00:00Z", files: [
            .init(path: "../sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Explizit freigegeben"]]),
        ])

        #expect(throws: TagArchiveError.externalTargetRequiresApproval(
            path: "../sample.mp3", resolvedPath: external.path
        )) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false)
        }
        #expect(try Data(contentsOf: external) == bytesBefore)

        let targets = try TagArchiveIO.validatedTargets(
            archive, relativeTo: base, allowExternalTargets: true)
        #expect(targets == [MediaFormats.canonicalFileURL(external)])
        #expect(TagArchiveIO.externalTargets(targets, relativeTo: base) == targets)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(
                archive, relativeTo: base, dryRun: false,
                approvedTargets: [base.appendingPathComponent("anderes-ziel.mp3")],
                allowExternalTargets: true)
        }
        #expect(try Data(contentsOf: external) == bytesBefore)

        let report = try TagArchiveIO.apply(
            archive, relativeTo: base, dryRun: false,
            approvedTargets: targets, allowExternalTargets: true)
        #expect(report.applied == ["../sample.mp3"])
        #expect(try TagFile.read(at: external).firstValue(for: "TITLE")
                == "Explizit freigegeben")
    }

    @Test("Ein nach der Freigabe untergeschobener Symlink stoppt den Import")
    func symlinkSwappedAfterApprovalIsRejected() throws {
        // Angriffsbild: Zwischen Anzeige/Freigabe der Zielliste und dem
        // Schreiben wird das bestätigte Ziel durch einen Symlink auf eine
        // andere Datei ersetzt. Würden die freigegebenen Pfade beim Vergleich
        // erneut kanonisiert, ergäben beide Seiten denselben NEUEN Pfad und
        // das nie angezeigte Ziel würde überschrieben.
        let parent = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: parent) }
        let base = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let victim = parent.appendingPathComponent("sample.mp3")
        let victimBytes = try Data(contentsOf: victim)
        let entry = base.appendingPathComponent("entry.mp3")
        try FileManager.default.copyItem(at: victim, to: entry)
        let archive = TagArchive(created: "2026-08-02T00:00:00Z", files: [
            .init(path: "entry.mp3", kind: .audio,
                  properties: ["TITLE": ["Nur für das freigegebene Ziel"]]),
        ])

        // Freigabe auf Basis der ehrlich aufgelösten Liste …
        let approved = try TagArchiveIO.validatedTargets(
            archive, relativeTo: base, allowExternalTargets: true)
        #expect(approved == [MediaFormats.canonicalFileURL(entry)])

        // … dann der Austausch: entry.mp3 zeigt jetzt woandershin.
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: victim)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
                                   approvedTargets: approved,
                                   allowExternalTargets: true)
        }
        #expect(try Data(contentsOf: victim) == victimBytes)

        // Ohne die Freigabe für externe Ziele fällt derselbe Austausch schon
        // eine Stufe früher auf: Das neue Ziel liegt außerhalb des Archivordners.
        #expect(throws: TagArchiveError.externalTargetRequiresApproval(
            path: "entry.mp3", resolvedPath: MediaFormats.canonicalFileURL(victim).path
        )) {
            try TagArchiveIO.apply(archive, relativeTo: base, dryRun: false,
                                   approvedTargets: approved)
        }
        #expect(try Data(contentsOf: victim) == victimBytes)
    }

    @Test("Ein umgebogener interner Symlink stoppt den Import auch ohne externe Ziele")
    func internalRetargetingIsRejectedWithApprovedTargets() throws {
        // Zwischen Prüfung und Schreibweg liegt in der App der Save/Discard-
        // Dialog. Wird das Ziel in diesem Fenster auf eine ANDERE Datei im
        // selben Ordner umgebogen, fällt das nur auf, wenn die geprüfte
        // Zielliste mitgegeben wird — externe Ziele sind hier keine im Spiel.
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = dir.appendingPathComponent("sample.mp3")
        let other = dir.appendingPathComponent("sample.flac")
        let otherBytes = try Data(contentsOf: other)
        let archive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Nur für das geprüfte Ziel"]]),
        ])
        let approved = try TagArchiveIO.validatedTargets(archive, relativeTo: dir)

        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: other)

        #expect(throws: TagArchiveError.approvedTargetListChanged) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false,
                                   approvedTargets: approved)
        }
        #expect(try Data(contentsOf: other) == otherBytes)
    }
}

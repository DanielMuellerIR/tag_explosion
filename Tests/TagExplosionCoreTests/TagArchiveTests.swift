import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("TagArchive", .serialized)
struct TagArchiveTests {
    @Test("Archivberichte vergleichen auch den Wortlaut fehlgeschlagener Einträge")
    func failureMessageParticipatesInReportEquality() throws {
        let original = TagArchiveReport.Failure(path: "sample.mp3", message: "Ziel geändert")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TagArchiveReport.Failure.self, from: encoded)
        var report = TagArchiveReport()
        report.failures = [original]
        var sameReport = report
        sameReport.failures = [decoded]
        #expect(report == sameReport)
        sameReport.failures = [.init(path: original.path, message: "Sicherung fehlgeschlagen")]
        #expect(report != sameReport)
        let legacy: [(path: String, message: String)] = report.failed
        #expect(legacy.first?.path == original.path)
        report.failed.append((path: "other.flac", message: "Datei fehlt"))
        #expect(report.failures.last == .init(path: "other.flac", message: "Datei fehlt"))
    }

    /// Kopiert mehrere Fixtures zusammen in EIN frisches Temp-Verzeichnis.
    func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(
                at: Fixtures.directory.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test("Eine schreibgeschützte Datei stoppt den Batch nicht")
    func batchContinuesAfterOneFailure() throws {
        let dir = try makeFolder(["sample.mp3", "sample.flac"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let flac = dir.appendingPathComponent("sample.flac")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Soll")], to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Soll")], to: flac)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3, flac], to: json, includeCovers: false)

        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Weg")], to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Weg")], to: flac)
        // Eine der beiden Dateien lässt sich nicht schreiben.
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: flac.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: flac.path)
        }

        let report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
                                            relativeTo: dir, dryRun: false)
        #expect(report.applied == ["sample.mp3"])
        #expect(report.failures.map(\.path) == ["sample.flac"])
        // Die gute Datei ist vollständig wiederhergestellt, die andere unberührt.
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Soll")
        #expect(try TagFile.read(at: flac).firstValue(for: "TITLE") == "Weg")
    }

    @Test("Fehlende und zusätzliche Dateien werden gemeldet, dry-run schreibt nicht")
    func missingExtraAndDryRun() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")],
                          artworks: [], to: mp3)
        let json = dir.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [mp3], to: json, includeCovers: true)

        // Datei umbenennen: Archiv-Eintrag wird "fehlend", neue Datei "zusätzlich"
        let renamed = dir.appendingPathComponent("umbenannt.mp3")
        try FileManager.default.moveItem(at: mp3, to: renamed)
        var report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
                                        relativeTo: dir, dryRun: false)
        #expect(report.missing == ["sample.mp3"])
        #expect(report.extra == ["umbenannt.mp3"])

        // dry-run: meldet Änderung, schreibt aber nicht
        try FileManager.default.moveItem(at: renamed, to: mp3)
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Kaputt")],
                          artworks: [], to: mp3)
        report = try TagArchiveIO.apply(try TagArchiveIO.load(json),
                                    relativeTo: dir, dryRun: true)
        #expect(report.applied == ["sample.mp3"])
        #expect(try TagFile.read(at: mp3).firstValue(for: "TITLE") == "Kaputt")
    }

    @Test("Relative Pfade auch oberhalb des JSON-Ordners")
    func relativePaths() {
        let base = URL(fileURLWithPath: "/a/b/c")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/b/c/x.mp3"), to: base) == "x.mp3")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/b/c/sub/x.mp3"), to: base) == "sub/x.mp3")
        #expect(TagArchiveIO.relativePath(
            of: URL(fileURLWithPath: "/a/other/x.mp3"), to: base) == "../../other/x.mp3")
    }

    @Test("Ungültiges Archiv wird vor jeder Mutation vollständig abgelehnt")
    func invalidArchiveDoesNotChangeEarlierEntries() throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        try TagFile.write(properties: [TagProperty(key: "TITLE", value: "Original")], to: mp3)
        let before = try Data(contentsOf: mp3)
        let archive = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "sample.mp3", kind: .audio,
                  properties: ["TITLE": ["Wäre geändert worden"]]),
            .init(path: "zweiter-eintrag.mp3", kind: .audio, properties: nil),
        ])

        #expect(throws: TagArchiveError.self) {
            try TagArchiveIO.apply(archive, relativeTo: dir, dryRun: false)
        }
        #expect(try Data(contentsOf: mp3) == before)
    }

    @Test("Cover: erkennbare Bildformate bleiben gültig, Nicht-Bilder werden abgelehnt")
    func archiveCoverRequiresRecognizableImage() throws {
        // EPUBs können gültige GIF-Cover enthalten — sie müssen archivierbar
        // bleiben (v1-Kompatibilität); die engere JPEG/PNG-Regel gilt nur
        // beim tatsächlichen Cover-Setzen im Schreibweg.
        var gifBytes: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        gifBytes.append(contentsOf: Array(repeating: 0, count: 8))
        let gif = Artwork(data: Data(gifBytes), mimeType: "image/gif",
                          pictureType: "Front Cover")
        let gifArchive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "book2.epub", kind: .ebook, artworks: [gif],
                  ebook: EbookCoreFields()),
        ])
        #expect(throws: Never.self) { try TagArchiveIO.validate(gifArchive) }

        let junk = Artwork(data: Data("kein Bild, nur Text".utf8), mimeType: "image/jpeg",
                           pictureType: "Front Cover")
        let archive = TagArchive(created: "2026-08-11T00:00:00Z", files: [
            .init(path: "book2.epub", kind: .ebook, artworks: [junk],
                  ebook: EbookCoreFields()),
        ])
        #expect(throws: TagArchiveError.inconsistentEntry(
            path: "book2.epub", detail: "ebook cover data is not a recognizable image"
        )) {
            try TagArchiveIO.validate(archive)
        }
    }

    // MARK: - Sicherungen

    @Test("Backup-Fallback ersetzt auch bei nachträglicher Kollision keine fremde Datei",
          arguments: [ENOTSUP, EOPNOTSUPP, EPERM])
    func backupFallbackKeepsConcurrentDestination(linkError: Int32) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("backup.json")
        let foreign = Data("fremder Stand".utf8)
        #expect(throws: TagError.self) {
            try FileExport.createArchiveBackup(Data("vollständiges Archiv".utf8), at: target, linkFile: { _, _ in
                try! foreign.write(to: target)
                errno = linkError
                return -1
            })
        }
        #expect(try Data(contentsOf: target) == foreign)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["backup.json"])
    }

    @Test("Auto-Backup funktioniert ohne Hardlinks und überspringt belegte Medien-Aliase",
          arguments: [ENOTSUP, EOPNOTSUPP, EPERM])
    func backupWithoutHardlinksPreservesAliasAndCompleteArchive(linkError: Int32) throws {
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")
        let original = try Data(contentsOf: mp3)
        let alias = dir.appendingPathComponent("tags-backup-fixture.json")
        try FileManager.default.linkItem(at: mp3, to: alias)
        let written = try TagArchiveIO.writeBackups(files: [mp3], stamp: "fixture", linkFile: { _, _ in
            errno = linkError
            return -1
        })
        #expect(written.count == 1)
        #expect(written[0].lastPathComponent == "tags-backup-fixture-2.json")
        #expect(try TagArchiveIO.load(written[0]).files.map(\.path) == ["sample.mp3"])
        #expect(try Data(contentsOf: alias) == original)
        #expect(try Data(contentsOf: mp3) == original)
    }

    @Test("Normale Neuanlagen erlauben keinen Backup-Fallback",
          arguments: [ENOTSUP, EOPNOTSUPP, EPERM])
    func normalCreationRejectsStreamingFallback(linkError: Int32) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("export.json")
        do {
            try AtomicFileRewrite.create(url: target, replacingOriginal: true,
                                         linkFile: { _, _ in errno = linkError; return -1 },
                                         beforeReplace: {},
                                         mutate: { try Data("Export".utf8).write(to: $0) },
                                         validate: { _ in })
            Issue.record("Normale Exporte dürfen nicht auf direktes Schreiben ausweichen")
        } catch TagError.fileSystemWriteFailed(let path, let reason) {
            #expect(path == target.path)
            #expect(reason.contains("errno \(linkError)"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("Schnell aufeinanderfolgende Backups überschreiben sich nicht")
    func rapidBackupsGetDistinctFileNames() throws {
        // Der Namens-Zeitstempel ist nur sekundengenau — mehrere Backups
        // desselben Ordners innerhalb einer Sekunde brauchen trotzdem je
        // eine eigene Datei.
        let dir = try makeFolder(["sample.mp3"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp3 = dir.appendingPathComponent("sample.mp3")

        var written: [URL] = []
        for _ in 1...3 {
            written.append(contentsOf: try TagArchiveIO.writeBackups(files: [mp3]))
        }

        #expect(Set(written.map(\.path)).count == 3)
        for url in written {
            // Jede Datei existiert und ist ein vollständiges, ladbares Archiv
            // (keine leere Reservierung, kein überschriebener Stand).
            let archive = try TagArchiveIO.load(url)
            #expect(archive.files.map(\.path) == ["sample.mp3"])
        }
    }

    @Test("Nur bekannte Archivversionen und passende Pflichtdaten werden akzeptiert")
    func archiveSchemaValidation() throws {
        let unsupported = TagArchive(version: TagArchive.currentVersion + 1,
                                     created: "2026-07-19T00:00:00Z", files: [])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(unsupported) }

        let entries: [TagArchive.Entry] = [
            .init(path: "audio.mp3", kind: .audio, properties: [:]),
            .init(path: "image.jpg", kind: .image, image: ImageCoreFields()),
            .init(path: "ebook.epub", kind: .ebook, ebook: EbookCoreFields()),
            .init(path: "document.docx", kind: .document, document: DocumentCoreFields()),
        ]
        for var entry in entries {
            entry.nfo = NFOFields(title: "Würde still ignoriert")
            #expect(throws: TagArchiveError.self) {
                try TagArchiveIO.validate(TagArchive(created: "2026-09-08T00:00:00Z", files: [entry]))
            }
        }

        let missingImage = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "cover.jpg", kind: .image, image: nil),
        ])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(missingImage) }

        let missingEbook = TagArchive(created: "2026-07-19T00:00:00Z", files: [
            .init(path: "book.epub", kind: .ebook, ebook: nil),
        ])
        #expect(throws: TagArchiveError.self) { try TagArchiveIO.validate(missingEbook) }
    }
}

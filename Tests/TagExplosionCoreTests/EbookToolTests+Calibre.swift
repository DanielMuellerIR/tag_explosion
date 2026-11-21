import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

extension EbookToolTests {
    /// Testing überspringt die optionalen Calibre-Prüfungen sichtbar statt sie
    /// mit `guard { return }` still grün erscheinen zu lassen.
    private static let calibreFixtureAvailable = EbookTool.calibreAvailable
        && FileManager.default.fileExists(
            atPath: Fixtures.directory.appendingPathComponent("book.azw3").path)

    @Test("AZW3 lehnt Serienänderungen vor dem Schreiben ab", .enabled(if: Self.calibreFixtureAvailable))
    func azw3RejectsSeriesChanges() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        var fields = original
        fields.series = "Nicht speicherbar"
        let before = try Data(contentsOf: url)
        #expect(!EbookTool.supportsSeries(url: url))
        #expect(throws: TagError.self) { try EbookTool.write(url: url, fields: fields, original: original, coverUpdate: .unchanged) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("Calibre: gemeinsames Lesen und Schreiben benötigen jeweils einen Prozess")
    func combinedCalibreInvocation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tagx-calibre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cover = try Fixtures.coverData("cover.png")
        try cover.write(to: folder.appendingPathComponent("cover.png"))
        let tool = folder.appendingPathComponent("ebook-meta")
        try """
        #!/bin/sh
        set -eu
        folder=$(dirname "$0")
        printf 'call\\n' >> "$folder/calls"
        printf '%s\\n' "$@" > "$folder/arguments"
        cover_path=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --get-cover) shift; cover_path="$1"; cp "$folder/cover.png" "$1" ;;
                --cover) shift; cp "$1" "$folder/written-cover.png" ;;
            esac
            shift
        done
        printf 'Title               : Combined title\\nPublisher           : Test publisher\\nAuthor(s)           : Unknown\\nComments            : First line\\nNote: keep this\\nCover saved to /a/real/comment.jpg\\nLast line\\n'
        if [ -n "$cover_path" ]; then printf 'Titelbild gespeichert unter %s\\n' "$cover_path"; fi
        """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let target = folder.appendingPathComponent("book.azw3")
        let contents = try EbookTool.readCalibreContents(url: target, includeCover: true, executable: tool.path)
        #expect(contents.fields.title == "Combined title")
        #expect(contents.fields.publisher == "Test publisher")
        #expect(contents.fields.description == "First line\nNote: keep this\nCover saved to /a/real/comment.jpg\nLast line")
        #expect(contents.cover?.data == cover)
        var edited = contents.fields
        edited.title = "New title"
        try EbookTool.writeCalibre(url: target, fields: edited, original: contents.fields,
                                  coverUpdate: .set(cover), executable: tool.path)
        let args = try String(contentsOf: folder.appendingPathComponent("arguments"), encoding: .utf8)
        #expect(args.contains("--title\nNew title\n"))
        #expect(args.contains("--cover\n"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("written-cover.png")) == cover)
        let calls = try String(contentsOf: folder.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 2)
        let tempCoverPath = args.split(separator: "\n").last.map(String.init)!
        #expect(!FileManager.default.fileExists(atPath: tempCoverPath))
    }

    @Test("Calibre: Coverabruf und unveränderter AZW3-Archivimport erhalten alle Felder", .enabled(
        if: Self.calibreFixtureAvailable, "Calibre oder die azw3-Fixture fehlt"))
    func combinedAZW3MetadataAndArchivePreserveFields() throws {
        try combinedCalibreMetadataAndArchivePreserveFields("azw3")
    }

    @Test("Calibre: Coverabruf und unveränderter FB2-Archivimport erhalten alle Felder", .enabled(
        if: EbookTool.calibreAvailable, "Calibre fehlt"))
    func combinedFB2MetadataAndArchivePreserveFields() throws {
        try combinedCalibreMetadataAndArchivePreserveFields("fb2")
    }

    private func combinedCalibreMetadataAndArchivePreserveFields(_ format: String) throws {
        let url = try format == "azw3" ? Fixtures.workingCopy("book.azw3") : makeFB2WorkingCopy()
        defer { if format == "fb2" { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        if format == "fb2" {
            let original = try EbookTool.readCoreFields(url: url)
            var fields = original
            fields.description = "Synthetischer Klappentext."
            try EbookTool.writeCoreFields(url: url, fields: fields, original: original)
            try EbookTool.writeCover(url: url, data: Fixtures.coverData("cover.jpg"))
        }
        let plain = try EbookTool.readCoreFields(url: url)
        #expect(!plain.description.isEmpty)
        let rawBefore = try directCalibreOutput(url: url)
        let combined = try EbookTool.readSnapshot(url: url, includeCover: true)
        #expect(combined.value.cover != nil)
        #expect(combined.value.fields == plain)
        let folder = url.deletingLastPathComponent()
        let archiveURL = folder.appendingPathComponent("tags.json")
        try TagArchiveIO.export(files: [url], to: archiveURL, includeCovers: true)
        let report = try TagArchiveIO.apply(try TagArchiveIO.load(archiveURL),
                                            relativeTo: folder, dryRun: false)
        #expect(report.failed.isEmpty)
        #expect(try EbookTool.readCoreFields(url: url) == plain)
        #expect(try directCalibreOutput(url: url) == rawBefore)
    }

    @Test("Calibre: Doppelpunkt im Klappentext wird vollständig aus dem Archiv restauriert", .enabled(
        if: Self.calibreFixtureAvailable, "Calibre fehlt"))
    func calibreMultilineCommentsArchiveRestore() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        var fields = original
        fields.description = "First line\nNote: keep this\nLast line"
        try EbookTool.writeCoreFields(url: url, fields: fields, original: original)
        #expect(try directCalibreOutput(url: url).contains(fields.description))
        #expect(try EbookTool.readCoreFields(url: url).description == fields.description)
        let archiveURL = url.deletingLastPathComponent().appendingPathComponent("multiline.json")
        try TagArchiveIO.export(files: [url], to: archiveURL, includeCovers: true)
        var changed = fields
        changed.description = "Changed"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: fields)
        let report = try TagArchiveIO.apply(try TagArchiveIO.load(archiveURL), relativeTo: url.deletingLastPathComponent(), dryRun: false)
        #expect(report.failed.isEmpty)
        #expect(try directCalibreOutput(url: url).contains(fields.description))
    }

    @Test("Calibre: coverfreies FB2 und skalare Sprache bleiben beim Archivimport unverändert", .enabled(
        if: EbookTool.calibreAvailable, "Calibre fehlt"))
    func calibreCoverlessArchiveAndScalarNoOp() throws {
        let url = try makeFB2WorkingCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fields = try EbookTool.readCoreFields(url: url)
        #expect(fields.description.isEmpty)
        #expect(fields.language == "de")
        #expect(try EbookTool.readCover(url: url) == nil)
        let before = try Data(contentsOf: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64
        let archiveURL = url.deletingLastPathComponent().appendingPathComponent("coverless.json")
        try TagArchiveIO.export(files: [url], to: archiveURL, includeCovers: true)
        let archive = try TagArchiveIO.load(archiveURL)
        for dryRun in [true, false] {
            let report = try TagArchiveIO.apply(archive, relativeTo: url.deletingLastPathComponent(), dryRun: dryRun)
            #expect(report.failed.isEmpty)
            #expect(report.unchanged == [url.lastPathComponent])
        }
        try EbookTool.writeCoreFields(url: url, fields: fields, original: fields)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64 == inode)
    }

    @Test("Calibre: gemeinsame Tags und Cover bestehen den echten Roundtrip", .enabled(
        if: Self.calibreFixtureAvailable, "Calibre oder die azw3-Fixture fehlt"))
    func combinedCalibreRoundtrip() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readSnapshot(url: url, includeCover: true)
        var fields = original.value.fields
        fields.title = "Gemeinsamer Schreibvorgang"
        let cover = try Fixtures.coverData("cover.png")
        try EbookTool.write(url: url, fields: fields, original: original.value.fields,
                            coverUpdate: .set(cover), expecting: original.stamp)
        let result = try EbookTool.readSnapshot(url: url, includeCover: true)
        #expect(result.value.fields.title == fields.title)
        #expect(result.value.cover != nil)
        #expect(Artwork.sniffMimeType(from: result.value.cover!.data) != nil)
    }

    @Test("azw3: Roundtrip via ebook-meta", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func azw3Roundtrip() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        var edited = editedFields
        edited.series = original.series
        edited.seriesIndex = original.seriesIndex
        // ebook-meta normalisiert Sprachcodes auf ISO-639-2 ("fra")
        edited.language = "fra"
        try EbookTool.writeCoreFields(url: url, fields: edited, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.title == edited.title)
        #expect(readBack.authors == edited.authors)
        // Serie wird von ebook-meta bei azw3 nicht persistiert (verifiziert mit
        // Calibre 7.7; EPUB kann es) — siehe knowledge/ebook-meta-calibre-quirks.md.
        #expect(readBack.isbn == edited.isbn)
        #expect(readBack.publisher == edited.publisher)
        #expect(readBack.subjects == edited.subjects)
        #expect(readBack.date == edited.date)
    }

    @Test("E-Book-Transaktion rollt Kernfelder bei Cover-Fehler zurück", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func ebookTransactionRollsBackFieldsWhenCoverStepFails() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let original = try EbookTool.readCoreFields(url: url)
        let bytesBefore = try Data(contentsOf: url)
        var changed = original
        changed.title = "Darf nicht teilweise bleiben"

        #expect(throws: TagError.self) {
            try EbookTool.write(
                url: url, fields: changed, original: original,
                coverUpdate: .remove)
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
        #expect(try EbookTool.readCoreFields(url: url).title == original.title)
    }

    @Test("Calibre: leeres Datum ersetzt den alten Wert durch den Undefined-Date-Sentinel", .enabled(
        if: Self.calibreFixtureAvailable,
        "Calibre oder die azw3-Fixture fehlt"
    ))
    func calibreEmptyDateUsesUndefinedSentinel() throws {
        let url = try Fixtures.workingCopy("book.azw3")
        let oldDate = "2023-11-05"
        var changed = try EbookTool.readCoreFields(url: url)
        changed.date = oldDate
        try EbookTool.writeCoreFields(url: url, fields: changed,
                                      original: try EbookTool.readCoreFields(url: url))
        #expect(try directCalibreOutput(url: url).contains(oldDate))

        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.date = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)

        // ebook-meta selbst ist der maßgebliche Read-back: Der alte Wert darf
        // nicht nur im eigenen Parser verschwinden.
        let output = try directCalibreOutput(url: url)
        #expect(!output.contains(oldDate))
        #expect(output.contains("Published"))
        #expect(output.contains("0101-01-01"))
        #expect(try EbookTool.readCoreFields(url: url).date.isEmpty)
    }

    @Test("Calibre: leerer Serienindex normalisiert einen alten Wert zu #1", .enabled(
        if: EbookTool.calibreAvailable,
        "Calibre fehlt"
    ))
    func calibreEmptySeriesIndexUsesDefaultOne() throws {
        let url = try makeFB2WorkingCopy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.title == "Testbuch")
        var indexed = original
        indexed.series = "Testreihe"
        indexed.seriesIndex = "7"
        try EbookTool.writeCoreFields(url: url, fields: indexed, original: original)
        #expect(try directCalibreOutput(url: url).contains("Series              : Testreihe #7"))

        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.seriesIndex = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)

        // Calibre bietet für eine vorhandene Serie keinen Null-Index. #1 ist
        // daher der dokumentierte Ersatz und beweist zugleich, dass #7 weg ist.
        let output = try directCalibreOutput(url: url)
        #expect(!output.contains("#7"))
        #expect(output.contains("Series              : Testreihe #1"))
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series == "Testreihe")
        #expect(readBack.seriesIndex == "1")
    }

    /// Führt ebook-meta direkt aus. Der Test kontrolliert damit den externen
    /// Dateizustand und nicht nur die eigene Parser-Interpretation.
    private func directCalibreOutput(url: URL) throws -> String {
        let executable = try EbookTool.locateCalibre()
        let result = try runCapturedProcess(executable: executable, arguments: [url.path],
            currentDirectory: TagxTestProcess.repoRoot, environment: ["LC_ALL": "C"])
        guard result.status == 0 else {
            throw NSError(domain: "EbookToolTests", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: result.stderr])
        }
        return result.stdout
    }

    /// Minimales FB2 für den Serienindex-Test. Der Test benötigt ebook-meta,
    /// keine EPUB-Konvertierung und kein Cover aus einem anderen Format.
    private func makeFB2WorkingCopy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-calibre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = dir.appendingPathComponent("book.fb2")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
          <description>
            <title-info><genre>antique</genre>
              <author><first-name>Erika</first-name><last-name>Beispiel</last-name></author>
              <book-title>Testbuch</book-title><lang>de</lang>
            </title-info>
            <document-info>
              <author><first-name>Erika</first-name><last-name>Beispiel</last-name></author>
              <date value="2026-09-08">2026-09-08</date>
              <id>tagx-test</id><version>1.0</version>
            </document-info>
          </description>
          <body><section><p>Synthetischer Testtext.</p></section></body>
        </FictionBook>
        """
        try Data(xml.utf8).write(to: result)
        return result
    }
}

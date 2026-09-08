// Dokument-Metadaten: Lesen, Roundtrip und Löschen für docx (OOXML), odt
// (OpenDocument), cbz (ComicInfo.xml) und Markdown-Frontmatter. Dazu die
// Container-Invarianten: Der restliche ZIP-Inhalt bleibt byte-identisch in
// gleicher Reihenfolge, ODF behält `mimetype` unkomprimiert an erster Stelle.
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("DocumentTool", .serialized)
struct DocumentToolTests {

    /// Alle Einträge eines Archivs (Pfad, Kompression, Inhalt) in Reihenfolge.
    private func archiveContents(_ url: URL) throws -> [(String, Bool, Data)] {
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        return try archive.map { entry in
            (entry.path, entry.isCompressed, try ZipContainer.data(of: entry, in: archive))
        }
    }

    /// Prüft, dass alle Einträge außer `changed` unverändert sind — gleiche
    /// Reihenfolge, gleiche Kompressionsart, gleiche Bytes.
    private func expectUntouched(before: [(String, Bool, Data)], after: [(String, Bool, Data)],
                                 except changed: Set<String>) {
        #expect(before.map(\.0) == after.map(\.0))
        for (old, new) in zip(before, after) where !changed.contains(old.0) {
            #expect(old.0 == new.0)
            #expect(old.1 == new.1, "Kompression von \(old.0)")
            #expect(old.2 == new.2, "Inhalt von \(old.0)")
        }
    }

    #if canImport(Darwin)
    @Test("ZIP-Dokumente behalten Außenrechte, ACL und xattr", arguments: ["doc.docx", "doc.odt", "comic.cbz"])
    func zipPreservesExternalMetadata(fixture: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        func command(_ executable: String, _ arguments: [String]) throws -> String {
            let result = try runCapturedProcess(executable: executable, arguments: arguments,
                                                currentDirectory: TagxTestProcess.repoRoot)
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            return result.stdout
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        _ = try command("/usr/bin/xattr", ["-w", "com.test.tagx", "synthetic metadata", url.path])
        _ = try command("/bin/chmod", ["+a", "everyone deny execute", url.path])
        let beforeACL = try command("/bin/ls", ["-le", url.path]).split(separator: "\n").dropFirst()
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Private document updated"
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try command("/usr/bin/xattr", ["-p", "com.test.tagx", url.path]) == "synthetic metadata\n")
        #expect(try command("/bin/ls", ["-le", url.path]).split(separator: "\n").dropFirst() == beforeACL)
    }
    #endif

    // MARK: - OOXML (docx)

    @Test("docx: core.xml und app.xml lesen")
    func docxRead() throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: true).value
        let fields = contents.fields
        #expect(fields.title == "Testdokument")
        #expect(fields.subject == "Thema")
        #expect(fields.authors == ["Erika Beispiel", "Max Muster"])
        #expect(fields.keywords == ["Test", "Fixtures"])
        #expect(fields.description == "Ein kleines Testdokument.")
        #expect(fields.category == "Bericht")
        #expect(fields.language == "de-DE")
        #expect(fields.created == "2020-01-01T10:00:00Z")
        #expect(fields.modified == "2021-06-15T12:30:00Z")
        #expect(fields.customValue(for: "lastModifiedBy") == "Max Muster")
        #expect(fields.customValue(for: "revision") == "3")
        #expect(contents.cover == nil)
        // app.xml: einfache Textelemente, verschachtelte (HeadingPairs) nicht.
        #expect(contents.info.contains(DocumentInfoItem(label: "Application", value: "Tag Explosion Fixture")))
        #expect(contents.info.contains(DocumentInfoItem(label: "Pages", value: "2")))
        #expect(!contents.info.contains { $0.label == "HeadingPairs" })
        #expect(DocumentTool.supportedFields(url: url).contains(.category))
        #expect(!DocumentTool.supportedFields(url: url).contains(.publisher))
    }

    @Test("docx: Roundtrip aller Felder, Rest des Archivs byte-identisch")
    func docxRoundtrip() throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let before = try archiveContents(url)
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Änderungstest № 1"
        edited.subject = "Neues Thema"
        edited.authors = ["Neue Autorin", "Zweiter Autor"]
        edited.keywords = ["Neu", "Geändert"]
        edited.description = "Geänderte Beschreibung mit Ümläuten."
        edited.category = "Notiz"
        edited.language = "fr"
        edited.created = "2023-11-05T08:00:00Z"
        edited.modified = "2023-11-06"
        edited.setCustom("lastModifiedBy", "Dritte Person")
        edited.setCustom("revision", "4")
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        expectUntouched(before: before, after: try archiveContents(url),
                        except: ["docProps/core.xml"])
    }

    @Test("Große ZIP-Einträge behalten Inhalt, Kompression und Rechte", arguments: [false, true])
    func largeZipEntrySurvives(compressed: Bool) throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let payload = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
        let entryPath = "word/media/large.bin"
        do {
            let archive = try ZipContainer.open(url: url, accessMode: .update)
            try archive.addEntry(with: entryPath, type: .file, uncompressedSize: Int64(payload.count),
                permissions: 0o640, compressionMethod: compressed ? .deflate : .none
            ) { position, size in payload.subdata(in: Int(position)..<(Int(position) + size)) }
        }
        let original = try DocumentTool.readCoreFields(url: url)
        var fields = original
        fields.title = "Großer Anhang"
        try DocumentTool.write(url: url, fields: fields, original: original)
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let entry = try #require(archive[entryPath])
        #expect(entry.isCompressed == compressed)
        #expect((entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try ZipContainer.data(of: entry, in: archive) == payload)
        #expect(try DocumentTool.readCoreFields(url: url) == fields)
    }

    @Test("docx: Felder löschen entfernt die Elemente")
    func docxDelete() throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let original = try DocumentTool.readCoreFields(url: url)
        var cleared = original
        cleared.subject = ""
        cleared.keywords = []
        cleared.category = ""
        cleared.modified = ""
        cleared.setCustom("revision", "")
        try DocumentTool.write(url: url, fields: cleared, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == cleared)
        let core = try #require(try ZipContainer.data(
            at: "docProps/core.xml", in: ZipContainer.open(url: url, accessMode: .read)))
        let xml = String(decoding: core, as: UTF8.self)
        #expect(!xml.contains("cp:keywords"))
        #expect(!xml.contains("cp:revision"))
        #expect(xml.contains("dcterms:created"))
    }

    @Test("docx ohne core.xml: Schreiben legt es an und registriert es")
    func docxCreatesMissingCore() throws {
        let url = try Fixtures.workingCopy("doc-nocore.docx")
        let original = try DocumentTool.readCoreFields(url: url)
        #expect(original == DocumentCoreFields())
        var edited = original
        edited.title = "Neu angelegt"
        edited.created = "2024-02-03"
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let types = String(decoding: try #require(try ZipContainer.data(at: "[Content_Types].xml", in: archive)), as: UTF8.self)
        let rels = String(decoding: try #require(try ZipContainer.data(at: "_rels/.rels", in: archive)), as: UTF8.self)
        let core = String(decoding: try #require(try ZipContainer.data(at: "docProps/core.xml", in: archive)), as: UTF8.self)
        #expect(types.contains("/docProps/core.xml"))
        #expect(rels.contains("metadata/core-properties"))
        #expect(core.contains("xsi:type=\"dcterms:W3CDTF\""))
    }

    @Test("Nicht speicherbare Felder und Werte scheitern vor jeder Mutation", arguments: ["doc.docx", "doc.odt"])
    func rejectsUnsupportedFieldsBeforeWriting(fixture: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        let bytes = try Data(contentsOf: url)
        let original = try DocumentTool.readCoreFields(url: url)

        var publisher = original
        publisher.publisher = "Kein Speicherort"
        #expect(throws: TagError.unsupportedDocumentField(name: "publisher")) {
            try DocumentTool.write(url: url, fields: publisher, original: original)
        }
        var unknownCustom = original
        unknownCustom.setCustom("Fantasie", "x")
        #expect(throws: TagError.unsupportedDocumentField(name: "Fantasie")) {
            try DocumentTool.write(url: url, fields: unknownCustom, original: original)
        }
        for value in ["5.11.2023", "2026-02-31", "2025-02-29", "2026-13-01", "2026-02-31T12:00:00Z"] {
            var badDate = original
            badDate.created = value
            #expect(throws: TagError.self) {
                try DocumentTool.write(url: url, fields: badDate, original: original)
            }
        }
        var badAuthor = original
        badAuthor.authors = ["Muster; Max"]
        #expect(throws: TagError.self) {
            try DocumentTool.write(url: url, fields: badAuthor, original: original)
        }
        #expect(try Data(contentsOf: url) == bytes)
        var leapDay = original
        leapDay.created = "2024-02-29T12:00:00Z"
        try DocumentTool.write(url: url, fields: leapDay, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == leapDay)
    }

    // MARK: - OpenDocument (odt)

    @Test("odt: meta.xml lesen")
    func odtRead() throws {
        let url = try Fixtures.workingCopy("doc.odt")
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: true).value
        let fields = contents.fields
        #expect(fields.title == "Testtext")
        #expect(fields.subject == "Thema")
        #expect(fields.authors == ["Max Muster"])
        #expect(fields.customValue(for: "initial-creator") == "Erika Beispiel")
        #expect(fields.customValue(for: "generator") == "Tag Explosion Fixture/1.0")
        #expect(fields.keywords == ["Test", "Fixtures"])
        #expect(fields.description == "Ein kleiner Testtext.")
        #expect(fields.language == "de-DE")
        #expect(fields.created == "2020-01-01T10:00:00")
        #expect(fields.modified == "2021-06-15T12:30:00")
        #expect(contents.info.contains(DocumentInfoItem(label: "page-count", value: "1")))
        #expect(contents.info.contains(DocumentInfoItem(label: "editing-cycles", value: "3")))
    }

    @Test("odt: Roundtrip, mimetype bleibt unkomprimiert an erster Stelle")
    func odtRoundtrip() throws {
        let url = try Fixtures.workingCopy("doc.odt")
        let before = try archiveContents(url)
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Neuer Titel"
        edited.subject = ""
        edited.authors = ["Neue Autorin"]
        edited.keywords = ["Eins", "Zwei", "Drei"]
        edited.description = "Neu."
        edited.language = "en"
        edited.created = "2022-02-02T02:02:02"
        edited.modified = "2022-03-03"
        edited.setCustom("initial-creator", "Ursprung")
        edited.setCustom("generator", "")
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        let after = try archiveContents(url)
        expectUntouched(before: before, after: after, except: ["meta.xml"])
        let first = try #require(after.first)
        #expect(first.0 == "mimetype")
        #expect(first.1 == false)
        #expect(String(decoding: first.2, as: UTF8.self) == "application/vnd.oasis.opendocument.text")
    }

    @Test("odt: publisher und category haben keinen Speicherort")
    func odtRejectsCategory() throws {
        let url = try Fixtures.workingCopy("doc.odt")
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.category = "x"
        #expect(throws: TagError.unsupportedDocumentField(name: "category")) {
            try DocumentTool.write(url: url, fields: edited, original: original)
        }
    }

    // MARK: - Comic (cbz)

    @Test("cbz: ComicInfo.xml lesen, Cover = erste Seite in natürlicher Sortierung")
    func cbzRead() throws {
        let url = try Fixtures.workingCopy("comic.cbz")
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: true).value
        let fields = contents.fields
        #expect(fields.title == "Testheft")
        #expect(fields.authors == ["Erika Beispiel", "Max Muster"])
        #expect(fields.description == "Ein kleines Testheft.")
        #expect(fields.publisher == "Testverlag")
        #expect(fields.language == "de")
        #expect(fields.created == "2020-03-05")
        #expect(fields.custom == [
            DocumentCustomField(key: "Series", value: "Testreihe"),
            DocumentCustomField(key: "Number", value: "2"),
            DocumentCustomField(key: "Volume", value: "1"),
            DocumentCustomField(key: "Penciller", value: "Zeichnerin"),
            DocumentCustomField(key: "Genre", value: "Abenteuer"),
            DocumentCustomField(key: "PageCount", value: "2"),
        ])
        // page-2.jpg (rot, JPEG) kommt vor page-10.png — nicht lexikografisch.
        let cover = try #require(contents.cover)
        let expectedCover = try Fixtures.coverData("cover.jpg")
        #expect(cover.data == expectedCover)
        #expect(cover.resolvedMimeType == "image/jpeg")
        #expect(contents.info.contains(DocumentInfoItem(label: "Pages", value: "2")))
    }

    @Test("cbz: Roundtrip inkl. Datum ohne Tag, Seiten bleiben byte-identisch")
    func cbzRoundtrip() throws {
        let url = try Fixtures.workingCopy("comic.cbz")
        let before = try archiveContents(url)
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Neues Heft"
        edited.authors = ["Autor A", "Autor B", "Autor C"]
        edited.description = ""
        edited.publisher = "Neuer Verlag"
        edited.language = "en"
        edited.created = "2021-07"
        edited.setCustom("Series", "Neue Reihe")
        edited.setCustom("Number", "3.5")
        edited.setCustom("Volume", "")
        edited.setCustom("Genre", "Krimi, Humor")
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        expectUntouched(before: before, after: try archiveContents(url), except: ["ComicInfo.xml"])
        #expect(try DocumentTool.readCover(url: url)?.data == Fixtures.coverData("cover.jpg"))
    }

    @Test("cbz ohne ComicInfo.xml: Schreiben legt die Datei an")
    func cbzCreatesComicInfo() throws {
        let url = try Fixtures.workingCopy("comic-noinfo.cbz")
        let before = try archiveContents(url)
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: true).value
        #expect(contents.fields == DocumentCoreFields())
        #expect(contents.cover != nil)
        #expect(contents.info.contains(DocumentInfoItem(label: "ComicInfo.xml", value: "missing")))
        var edited = contents.fields
        edited.title = "Erstmals getaggt"
        edited.created = "2019"
        edited.setCustom("Series", "Serie")
        try DocumentTool.write(url: url, fields: edited, original: contents.fields)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        let after = try archiveContents(url)
        #expect(after.map(\.0) == before.map(\.0) + ["ComicInfo.xml"])
        expectUntouched(before: before, after: Array(after.prefix(before.count)), except: [])
        // Schemareihenfolge: Title vor Series vor Year.
        let xml = String(decoding: try #require(after.last?.2), as: UTF8.self)
        let title = try #require(xml.range(of: "<Title>"))
        let series = try #require(xml.range(of: "<Series>"))
        let year = try #require(xml.range(of: "<Year>"))
        #expect(title.lowerBound < series.lowerBound && series.lowerBound < year.lowerBound)
    }

    @Test("cbz: Autor mit Komma und ungültiges Datum werden abgelehnt")
    func cbzRejectsInvalidValues() throws {
        let url = try Fixtures.workingCopy("comic.cbz")
        let original = try DocumentTool.readCoreFields(url: url)
        var author = original
        author.authors = ["Muster, Max"]
        #expect(throws: TagError.self) {
            try DocumentTool.write(url: url, fields: author, original: original)
        }
        let before = try Data(contentsOf: url)
        for value in ["2020-3-5", "2026-02-31", "2025-02-29", "2026-13"] {
            var date = original
            date.created = value
            #expect(throws: TagError.self) {
                try DocumentTool.write(url: url, fields: date, original: original)
            }
        }
        #expect(try Data(contentsOf: url) == before)
        var keywords = original
        keywords.keywords = ["kein Speicherort"]
        #expect(throws: TagError.unsupportedDocumentField(name: "keywords")) {
            try DocumentTool.write(url: url, fields: keywords, original: original)
        }
    }

    // MARK: - Markdown

    private func markdownFile(_ text: String, name: String = "note.md") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static let sampleFrontmatter = """
    ---
    # Kommentar bleibt
    title: "Hallo: Welt"
    author: Erika Beispiel
    date: 2024-01-05
    tags: [a, "b, c", 'd']
    description: Eine Beschreibung # mit Kommentar
    draft: true
    weight: 10
    categories:
      - Eins
      - Zwei
    nested:
      key: value
      other: 2
    ---
    # Überschrift

    Body mit --- Trennlinie
    ---
    und: Doppelpunkt am Ende.

    """

    @Test("Markdown: Frontmatter lesen (Skalare, Listen, Kommentare, komplexe Einträge)")
    func markdownRead() throws {
        let url = try markdownFile(Self.sampleFrontmatter)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: true).value
        let fields = contents.fields
        #expect(fields.title == "Hallo: Welt")
        #expect(fields.authors == ["Erika Beispiel"])
        #expect(fields.created == "2024-01-05")
        #expect(fields.keywords == ["a", "b, c", "d"])
        #expect(fields.description == "Eine Beschreibung")
        #expect(fields.custom == [
            DocumentCustomField(key: "draft", value: "true"),
            DocumentCustomField(key: "weight", value: "10"),
            DocumentCustomField(key: "categories", value: "Eins, Zwei"),
        ])
        #expect(contents.info.contains(DocumentInfoItem(label: "preserved (not editable)", value: "nested")))
        #expect(DocumentTool.customKeys(url: url) == nil)
    }

    @Test("Markdown: Roundtrip erhält Reihenfolge, Fremdschlüssel und Body byte-identisch")
    func markdownRoundtrip() throws {
        let url = try markdownFile(Self.sampleFrontmatter)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Neuer Titel"
        edited.authors = ["A", "B"]
        edited.keywords = ["x", "y: z"]
        edited.description = ""
        edited.created = "2025-02-03"
        edited.setCustom("weight", "20")
        edited.setCustom("draft", "")
        edited.setCustom("custom-new", "  gepolstert ")
        try DocumentTool.write(url: url, fields: edited, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)

        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let expected = """
        ---
        # Kommentar bleibt
        title: Neuer Titel
        author: [A, B]
        date: 2025-02-03
        tags: [x, "y: z"]
        weight: "20"
        categories:
          - Eins
          - Zwei
        nested:
          key: value
          other: 2
        custom-new: "  gepolstert "
        ---
        # Überschrift

        Body mit --- Trennlinie
        ---
        und: Doppelpunkt am Ende.

        """
        #expect(text == expected)
    }

    @Test("Markdown ohne Frontmatter: Block entsteht, Body bleibt; CRLF und BOM bleiben")
    func markdownCreatesFrontmatter() throws {
        let body = "\u{FEFF}# Nur Body\r\n\r\nText.\r\n"
        let url = try markdownFile(body)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let contents = try DocumentTool.readSnapshot(url: url, includeCover: false).value
        #expect(contents.fields == DocumentCoreFields())
        #expect(contents.info.contains(DocumentInfoItem(label: "frontmatter", value: "none")))
        var edited = contents.fields
        edited.title = "Neu"
        edited.authors = ["Eins", "Zwei"]
        try DocumentTool.write(url: url, fields: edited, original: contents.fields)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text == "\u{FEFF}---\r\ntitle: Neu\r\nauthors: [Eins, Zwei]\r\n---\r\n# Nur Body\r\n\r\nText.\r\n")
    }

    @Test("Markdown ohne abschließenden Zeilenumbruch erhält Frontmatter", arguments: ["# Kurz", ""])
    func markdownWithoutNewline(body: String) throws {
        let url = try markdownFile(body)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try DocumentTool.readCoreFields(url: url)
        var fields = original
        fields.title = "Neu"
        try DocumentTool.write(url: url, fields: fields, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == fields)
        #expect(try Data(contentsOf: url) == Data(("---\ntitle: Neu\n---\n" + body).utf8))
    }

    @Test("Markdown-Listen erhalten Kommas und abschließende Backslashes")
    func markdownListEscapes() throws {
        let url = try markdownFile("# Text\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try DocumentTool.readCoreFields(url: url)
        var fields = original
        fields.authors = ["Nachname, Vorname", "Ende, \\", "[Name]", "O'Connor"]
        try DocumentTool.write(url: url, fields: fields, original: original)
        #expect(try DocumentTool.readCoreFields(url: url) == fields)
    }

    @Test("Markdown: Komplexe Einträge lassen sich nicht überschreiben, Schlüsselform wird geprüft")
    func markdownProtectsComplexEntries() throws {
        let url = try markdownFile(Self.sampleFrontmatter)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: url)
        let original = try DocumentTool.readCoreFields(url: url)
        var nested = original
        nested.setCustom("nested", "flach")
        #expect(throws: TagError.self) {
            try DocumentTool.write(url: url, fields: nested, original: original)
        }
        var badKey = original
        badKey.setCustom("kein schlüssel", "x")
        #expect(throws: TagError.self) {
            try DocumentTool.write(url: url, fields: badKey, original: original)
        }
        var mapped = original
        mapped.setCustom("tags", "x")
        #expect(throws: TagError.self) {
            try DocumentTool.write(url: url, fields: mapped, original: original)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Frontmatter-Parser: Randfälle")
    func frontmatterParserEdgeCases() throws {
        func parse(_ text: String) throws -> MarkdownDocument {
            try MarkdownFrontmatter.parse(Data(text.utf8), path: "test.md")
        }
        // Kein schließender Trenner → kein Block, alles ist Body.
        let open = try parse("---\ntitle: x\nBody")
        #expect(open.entries == nil)
        #expect(open.body == Data("---\ntitle: x\nBody".utf8))
        // "..." schließt ebenfalls; Body kann leer sein.
        let dots = try parse("---\ntitle: x\n...")
        #expect(dots.entry("title")?.value == .scalar("x"))
        #expect(dots.body.isEmpty)
        // Erste Zeile muss der Trenner sein.
        #expect(try parse("\n---\ntitle: x\n---\n").entries == nil)
        // Quoting: Escapes, einfache Anführungszeichen. Eine Zeile, die kein
        // Schlüssel ist (URL mit Doppelpunkt), hängt als Fortsetzung am
        // vorigen Eintrag und macht ihn komplex — er bleibt erhalten.
        let quoted = try parse("---\na: \"Zeile\\nzwei \\\"z\\\"\"\nb: 'it''s'\nc: 42\nhttp://x: y\n---\n")
        #expect(quoted.entry("a")?.value == .scalar("Zeile\nzwei \"z\""))
        #expect(quoted.entry("b")?.value == .scalar("it's"))
        #expect(quoted.entry("http://x") == nil)
        #expect(quoted.entry("c")?.value == .complex)
        #expect(quoted.entry("c")?.rawLines == ["c: 42", "http://x: y"])
        // Blockskalar und Fließmap sind komplex; leerer Wert ist leerer Skalar.
        let complex = try parse("---\nd: |\n  Zeile\ne: {a: 1}\nf:\ng: [unvollständig\n---\n")
        #expect(complex.entry("d")?.value == .complex)
        #expect(complex.entry("e")?.value == .complex)
        #expect(complex.entry("f")?.value == .scalar(""))
        #expect(complex.entry("g")?.value == .complex)
        #expect(complex.entry("d")?.rawLines == ["d: |", "  Zeile"])
        #expect(try parse("---\na: \"Text\" unklar\n---\n").entry("a")?.value == .complex)
        // Serialisierung quotiert nur, was nötig ist.
        #expect(MarkdownFrontmatter.yamlScalar("Einfach") == "Einfach")
        #expect(MarkdownFrontmatter.yamlScalar("2024-01-05") == "2024-01-05")
        #expect(MarkdownFrontmatter.yamlScalar("true") == "\"true\"")
        #expect(MarkdownFrontmatter.yamlScalar("3.5") == "\"3.5\"")
        #expect(MarkdownFrontmatter.yamlScalar("a: b") == "\"a: b\"")
        #expect(MarkdownFrontmatter.yamlScalar("#x") == "\"#x\"")
        #expect(MarkdownFrontmatter.yamlScalar("") == "\"\"")
        // Anführungszeichen mitten im Text sind in einem unquotierten Skalar
        // erlaubt; nur am Anfang erzwingen sie Quoting.
        #expect(MarkdownFrontmatter.yamlScalar("a \"b\"") == "a \"b\"")
        #expect(MarkdownFrontmatter.yamlScalar("\"b\"") == "\"\\\"b\\\"\"")
    }

    // MARK: - Gemeinsames

    @Test("Medienart document und Endungen")
    func mediaKind() {
        for ext in ["docx", "xlsx", "pptx", "odt", "ods", "odp", "cbz", "md"] {
            #expect(MediaFormats.kind(of: URL(fileURLWithPath: "/tmp/x.\(ext)")) == .document)
        }
        #expect(MediaFormats.isArchivable(.document))
        #expect(DocumentTool.supportsCover(url: URL(fileURLWithPath: "/tmp/x.cbz")))
        #expect(!DocumentTool.supportsCover(url: URL(fileURLWithPath: "/tmp/x.docx")))
    }

    @Test("Unveränderte Felder schreiben nichts (Datei bleibt byte-gleich)")
    func noopDoesNotRewrite() throws {
        let url = try Fixtures.workingCopy("doc.docx")
        let bytes = try Data(contentsOf: url)
        let stamp = try #require(FileStamp.current(of: url))
        let original = try DocumentTool.readCoreFields(url: url)
        try DocumentTool.write(url: url, fields: original, original: original, expecting: stamp)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(FileStamp.current(of: url) == stamp)
    }


    @Test("Markdown: Leer- und Kommentarzeilen hinter einem geänderten oder entfernten Wert bleiben stehen")
    func markdownKeepsCommentsAfterChangedValue() throws {
        let url = try markdownFile("""
        ---
        title: Alt
        # Kommentar zum Titel

        author: Erika
        weight: 10
        # Kommentar zum Gewicht
        ---
        Body

        """)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try DocumentTool.readCoreFields(url: url)
        var edited = original
        edited.title = "Neu"
        edited.setCustom("weight", "")
        try DocumentTool.write(url: url, fields: edited, original: original)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text == """
        ---
        title: Neu
        # Kommentar zum Titel

        author: Erika
        # Kommentar zum Gewicht
        ---
        Body

        """)
        #expect(try DocumentTool.readCoreFields(url: url) == edited)
    }
}

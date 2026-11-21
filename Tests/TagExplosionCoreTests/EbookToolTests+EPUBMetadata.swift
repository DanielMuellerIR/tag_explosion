import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore
import ZIPFoundation

extension EbookToolTests {
    @Test("EPUB lehnt externe Entities beim Lesen und Schreiben unverändert ab",
          arguments: ["META-INF/container.xml", "OEBPS/content.opf"])
    func epubRejectsExternalEntities(_ path: String) throws {
        let url = try Fixtures.workingCopy("book2.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try EbookTool.readCoreFields(url: url)
        let marker = url.deletingLastPathComponent().appendingPathComponent("private.txt")
        try Data("Privater Marker".utf8).write(to: marker)
        try rewriteOpf(in: url, path: path) { xml in
            let root = path.hasSuffix("container.xml") ? "container" : "package"
            let declaration = "<!DOCTYPE \(root) [<!ENTITY secret SYSTEM '\(marker.absoluteString)'>]>"
            let start = xml.range(of: "<\(root)")!
            var result = xml
            result.insert(contentsOf: declaration, at: start.lowerBound)
            if root == "package" {
                result = result.replacingOccurrences(of: #"<dc:title>[^<]*</dc:title>"#,
                    with: "<dc:title>&secret;</dc:title>", options: .regularExpression)
            } else {
                result = result.replacingOccurrences(of: "</container>", with: "&secret;</container>")
            }
            return result
        }
        let before = try Data(contentsOf: url)
        #expect(throws: TagError.self) { _ = try EbookTool.readSnapshot(url: url, includeCover: true) }
        var edited = original
        edited.title = "Neuer Titel"
        #expect(throws: TagError.self) {
            try EbookTool.write(url: url, fields: edited, original: original, coverUpdate: .unchanged)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("EPUB 2 erhält keine EPUB-3-Attribute beim Anlegen von Serie und Cover")
    func epub2WritesVersionCompatibleMetadata() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        var fields = original
        fields.series = "Neue Reihe"
        fields.seriesIndex = "2"
        try EbookTool.writeCoreFields(url: url, fields: fields, original: original)
        try EbookTool.removeCover(url: url)
        try EbookTool.writeCover(url: url, data: try Data(contentsOf: Fixtures.directory.appendingPathComponent("cover.png")))
        let archive = try ZipContainer.open(url: url, accessMode: .read)
        let data = try #require(try ZipContainer.data(at: "OEBPS/content.opf", in: archive))
        let document = try XMLTools.document(from: data, path: url.path)
        let root = try #require(document.rootElement())
        let metadata = try #require(XMLTools.firstElement(named: "metadata", in: root))
        for meta in XMLTools.elements(named: "meta", in: metadata) {
            #expect(XMLTools.attribute(meta, "property") == nil)
            #expect(XMLTools.attribute(meta, "refines") == nil)
        }
        let manifest = try #require(XMLTools.firstElement(named: "manifest", in: root))
        #expect(XMLTools.elements(named: "item", in: manifest).allSatisfy { XMLTools.attribute($0, "properties") == nil })
        #expect(try EbookTool.readCoreFields(url: url).series == fields.series)
    }

    @Test("EPUB-Metadaten bewahren gleichnamige Fremdelemente")
    func foreignEpubMetadataSurvives() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let path = "OEBPS/content.opf"
        try rewriteOpf(in: url, path: path) { xml in
            xml.replacingOccurrences(of: "<dc:title>", with:
                "<vendor:title xmlns:vendor=\"urn:test:vendor\">Fremder Titel</vendor:title>"
                + "<vendor:creator xmlns:vendor=\"urn:test:vendor\">Fremder Autor</vendor:creator><dc:title>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.title != "Fremder Titel")
        #expect(!original.authors.contains("Fremder Autor"))
        var edited = original
        edited.title = ""
        edited.authors = ["Neuer Autor"]
        try EbookTool.writeCoreFields(url: url, fields: edited, original: original)
        let xml = try opfContents(of: url, path: path)
        #expect(xml.contains("Fremder Titel"))
        #expect(xml.contains("Fremder Autor"))
        #expect(try EbookTool.readCoreFields(url: url) == edited)
    }

    @Test("Präfigierte OPF erhält neue Serien- und Coverelemente im OPF-Namensraum")
    func prefixedOPFCreatesMetadata() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let path = "OEBPS/content.opf"
        try rewriteOpf(in: url, path: path) { xml in
            var result = xml.replacingOccurrences(of: "xmlns=\"http://www.idpf.org/2007/opf\"",
                                                   with: "")
            for name in ["package", "metadata", "manifest", "item", "spine", "itemref", "meta", "guide", "reference"] {
                result = result.replacingOccurrences(of: "(<[/]?)" + name + "(?=[ > /])", with: "$1opf:" + name,
                                                     options: .regularExpression)
            }
            return result
        }
        let original = try EbookTool.readCoreFields(url: url)
        var edited = original
        edited.series = "Neue Reihe"
        edited.seriesIndex = "4"
        try EbookTool.write(url: url, fields: edited, original: original, coverUpdate: .remove)
        let cover = try Data(contentsOf: Fixtures.directory.appendingPathComponent("cover.jpg"))
        try EbookTool.write(url: url, fields: edited, original: edited, coverUpdate: .set(cover))
        #expect(try EbookTool.readCoreFields(url: url) == edited)
        #expect(try EbookTool.readCover(url: url)?.data == cover)
    }

    // MARK: - EPUB 2

    @Test("EPUB 2: bekannte Felder lesen")
    func epub2Read() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let fields = try EbookTool.readCoreFields(url: url)
        #expect(fields.title == "Testbuch Zwei")
        #expect(fields.authors == ["Erika Beispiel"])
        #expect(fields.series == "Testreihe")
        #expect(fields.seriesIndex == "2")
        #expect(fields.description == "Ein kleines Testbuch.")
        #expect(fields.isbn == "9783161484100")
        #expect(fields.publisher == "Testverlag")
        #expect(fields.language == "de")
        #expect(fields.date == "2020-01-01")
        #expect(fields.subjects == ["Test", "Fixtures"])
    }

    @Test("EPUB 2: Roundtrip aller Felder")
    func epub2Roundtrip() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == editedFields)
    }

    @Test("EPUB 2: Felder löschen")
    func epub2Delete() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        var cleared = original
        cleared.series = ""
        cleared.seriesIndex = ""
        cleared.description = ""
        cleared.isbn = ""
        cleared.subjects = []
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == cleared)
        // Titel/Autor blieben unangetastet
        #expect(readBack.title == "Testbuch Zwei")
    }

    @Test("EPUB: Read-Pfade funktionieren bei schreibgeschützter Datei")
    func epubReadOnlyStillReadsMetadataAndCover() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let bytesBefore = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
        #expect(try EbookTool.readCover(url: url)?.data == Fixtures.coverData("cover.jpg"))
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Darf nicht speichern"
        #expect(throws: TagError.saveFailed(path: url.path)) {
            try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
        }
        #expect(throws: TagError.saveFailed(path: url.path)) {
            try EbookTool.writeCover(url: url, data: try Fixtures.coverData("cover.png"))
        }
        #expect(try Data(contentsOf: url) == bytesBefore)
    }

    @Test("Felder und Cover können nicht aus zwei EPUB-Fassungen gemischt werden")
    func ebookSnapshotRejectsReplacementBetweenFieldAndCoverRead() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let replacement = try Fixtures.workingCopy("book3.epub")
        let replacementBytes = try Data(contentsOf: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            _ = try EbookTool.readSnapshot(
                url: url, includeCover: true,
                betweenReads: {
                    try TestFiles.replaceAtomically(url, with: replacement)
                })
        }
        #expect(try Data(contentsOf: url) == replacementBytes)
    }

    @Test("E-Book-No-op bestätigt keinen inzwischen ersetzten Pfad")
    func ebookNoopRejectsStaleSnapshot() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let snapshot = try EbookTool.readSnapshot(url: url, includeCover: true)
        let replacement = try Fixtures.workingCopy("book2.epub")
        try TestFiles.replaceAtomically(url, with: replacement)

        #expect(throws: TagError.fileChangedOnDisk(path: url.path)) {
            try EbookTool.write(
                url: url, fields: snapshot.value.fields,
                original: snapshot.value.fields, coverUpdate: .unchanged,
                expecting: snapshot.stamp)
        }
    }

    // MARK: - EPUB 3

    @Test("EPUB 3: bekannte Felder lesen")
    func epub3Read() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let fields = try EbookTool.readCoreFields(url: url)
        #expect(fields.title == "Testbuch Drei")
        #expect(fields.authors == ["Max Muster", "Erika Beispiel"])
        #expect(fields.series == "Dreierreihe")
        #expect(fields.seriesIndex == "3")
        #expect(fields.isbn == "9780306406157")
        #expect(fields.language == "en")
        #expect(fields.date == "2021-06-15")
    }

    @Test("EPUB 3: Roundtrip aller Felder")
    func epub3Roundtrip() throws {
        let url = try Fixtures.workingCopy("book3.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        let readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack == editedFields)
    }

    @Test("EPUB: mimetype bleibt erster, unkomprimierter Eintrag")
    func epubMimetypeStaysFirst() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let original = try EbookTool.readCoreFields(url: url)
        try EbookTool.writeCoreFields(url: url, fields: editedFields, original: original)
        // Ein konformes EPUB beginnt mit dem Local-File-Header von "mimetype"
        // (Offset 30: Dateiname) und direkt danach dem unkomprimierten Inhalt.
        let data = try Data(contentsOf: url)
        let prefix = String(decoding: data[30..<(30 + 8 + 20)], as: UTF8.self)
        #expect(prefix == "mimetypeapplication/epub+zip")
    }

    @Test("EPUB: fehlgeschlagene Temp-Mutation lässt das Original bytegleich")
    func epubAtomicRewriteFailureKeepsOriginal() throws {
        let url = try Fixtures.workingCopy("book2.epub")
        let before = try Data(contentsOf: url)

        #expect(throws: TagError.self) {
            try AtomicFileRewrite.run(url: url) { temp in
                try Data("kein EPUB".utf8).write(to: temp)
            } validate: { _ in
                throw TagError.cannotOpen(path: url.path)
            }
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(try EbookTool.readCoreFields(url: url).title == "Testbuch Zwei")
    }

    // MARK: - EPUB: fremde Metadaten überleben eigene Änderungen

    @Test("EPUB 2: Eine Autorenänderung erhält Creator mit anderer Rolle")
    func epub2AuthorChangeKeepsOtherRoles() throws {
        // Editoren/Übersetzer sind eigene Metadaten. Eine reine
        // Autorenänderung darf sie nicht mitlöschen.
        let url = try Fixtures.workingCopy("book2.epub")
        try rewriteOpf(in: url, path: "OEBPS/content.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator opf:role=\"aut\">Erika Beispiel</dc:creator>",
                with: "<dc:creator opf:role=\"aut\">Erika Beispiel</dc:creator>"
                    + "<dc:creator opf:role=\"edt\">Eddie Editor</dc:creator>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.authors == ["Erika Beispiel"]) // edt ist kein Autor

        var changed = original
        changed.authors = ["Neue Autorin"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).authors == ["Neue Autorin"])
        let xml = try opfContents(of: url, path: "OEBPS/content.opf")
        #expect(xml.contains("Eddie Editor"))
        #expect(!xml.contains("Erika Beispiel"))
    }

    @Test("EPUB 3: Eine per refines markierte Rolle bleibt samt Verfeinerung erhalten")
    func epub3AuthorChangeKeepsRefinedRoles() throws {
        // EPUB 3 markiert Rollen über <meta refines="#id" property="role">.
        // Solche Creator sind keine Autoren und bleiben mitsamt ihrer
        // Verfeinerung stehen.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator>Erika Beispiel</dc:creator>",
                with: "<dc:creator>Erika Beispiel</dc:creator>"
                    + "<dc:creator id=\"ed1\">Eddie Editor</dc:creator>"
                    + "<meta refines=\"#ed1\" property=\"role\" scheme=\"marc:relators\">edt</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        #expect(original.authors == ["Max Muster", "Erika Beispiel"])

        var changed = original
        changed.authors = ["Nur Noch Eine"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).authors == ["Nur Noch Eine"])
        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Eddie Editor"))
        #expect(xml.contains("refines=\"#ed1\""))
    }

    @Test("EPUB 3: Eine Titeländerung erhält weitere Titel samt Verfeinerungen")
    func epub3TitleChangeKeepsAlternateTitles() throws {
        // Das öffentliche Titelfeld bildet nur den ersten dc:title ab. Ein
        // Untertitel ist fremder, nicht dargestellter Zustand und darf bei
        // einer Änderung des Haupttitels nicht verschwinden.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:title>Testbuch Drei</dc:title>",
                with: "<dc:title id=\"main-title\">Testbuch Drei</dc:title>"
                    + "<meta refines=\"#main-title\" property=\"title-type\">main</meta>"
                    + "<dc:title id=\"subtitle\">Bleibender Untertitel</dc:title>"
                    + "<meta refines=\"#subtitle\" property=\"title-type\">subtitle</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Neuer Haupttitel"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Neuer Haupttitel"))
        #expect(xml.contains("Bleibender Untertitel"))
        #expect(xml.contains("refines=\"#subtitle\""))
        #expect(try EbookTool.readCoreFields(url: url).title == "Neuer Haupttitel")

        // Beim ausdrücklichen Löschen verschwinden dagegen alle Titel. Dann
        // müssen auch deren Verfeinerungen mit entfernt werden.
        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.title = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)
        let clearedXML = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(!clearedXML.contains("main-title"))
        #expect(!clearedXML.contains("subtitle"))
        #expect(try EbookTool.readCoreFields(url: url).title.isEmpty)
    }

    @Test("EPUB 3: Ersetzte Schlagwörter hinterlassen keine Verfeinerungen")
    func epub3SubjectChangeRemovesRefinements() throws {
        // dc:subject kann per refines um Normvokabular und Code ergänzt sein.
        // Wird das Schlagwort ersetzt, darf diese Verfeinerung nicht auf eine
        // inzwischen entfernte XML-ID zeigen.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:identifier id=\"uid\">urn:isbn:9780306406157</dc:identifier>",
                with: "<dc:subject id=\"subject-old\">Alte Klassifikation</dc:subject>"
                    + "<meta refines=\"#subject-old\" property=\"authority\">BISAC</meta>"
                    + "<dc:identifier id=\"uid\">urn:isbn:9780306406157</dc:identifier>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.subjects = ["Neues Schlagwort"]
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(!xml.contains("subject-old"))
        #expect(!xml.contains("BISAC"))
        #expect(try EbookTool.readCoreFields(url: url).subjects == ["Neues Schlagwort"])
    }

    @Test("EPUB 3: Serienänderung und -löschung erhalten fremde Sammlungen")
    func epub3SeriesChangeKeepsUnrelatedCollections() throws {
        // Ein Buch kann neben der Serie weiteren Sammlungen angehören
        // (collection-type != "series"). Die dürfen weder beim Ändern noch
        // beim Löschen der Serie verschwinden.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<meta property=\"belongs-to-collection\" id=\"c01\">Dreierreihe</meta>",
                with: "<meta property=\"belongs-to-collection\" id=\"c01\">Dreierreihe</meta>"
                    + "<meta property=\"belongs-to-collection\" id=\"set1\">Gesamtausgabe</meta>"
                    + "<meta refines=\"#set1\" property=\"collection-type\">set</meta>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        // Die typlose Sammlung c01 bleibt die Serie; "set" zählt nicht.
        #expect(original.series == "Dreierreihe")

        var changed = original
        changed.series = "Neue Reihe"
        changed.seriesIndex = "9"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
        var readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series == "Neue Reihe")
        #expect(readBack.seriesIndex == "9")
        var xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Gesamtausgabe"))
        #expect(xml.contains("collection-type"))
        #expect(!xml.contains("Dreierreihe"))

        // Serie ganz löschen — die fremde Sammlung bleibt trotzdem.
        let beforeClear = try EbookTool.readCoreFields(url: url)
        var cleared = beforeClear
        cleared.series = ""
        cleared.seriesIndex = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: beforeClear)
        readBack = try EbookTool.readCoreFields(url: url)
        #expect(readBack.series.isEmpty)
        xml = try opfContents(of: url, path: "OEBPS/package.opf")
        #expect(xml.contains("Gesamtausgabe"))
    }

    @Test("EPUB 3: Die neue Serien-id weicht auch einer id außerhalb der meta-Elemente aus")
    func epub3SeriesIdAvoidsIdsOutsideMetaElements() throws {
        // Die Kollisionsprüfung sah früher nur die <meta>-Kinder von
        // <metadata>. Trägt ein anderes Element — hier ein dc:creator — die id
        // "series-tagx" bereits, entstünde eine doppelte XML-ID und die neu
        // geschriebenen refines-Verweise wären mehrdeutig.
        let url = try Fixtures.workingCopy("book3.epub")
        try rewriteOpf(in: url, path: "OEBPS/package.opf") { xml in
            xml.replacingOccurrences(
                of: "<dc:creator>Erika Beispiel</dc:creator>",
                with: "<dc:creator id=\"series-tagx\">Erika Beispiel</dc:creator>")
        }
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.series = "Neue Reihe"
        changed.seriesIndex = "2"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        let xml = try opfContents(of: url, path: "OEBPS/package.opf")
        // Die fremde id bleibt genau einmal vergeben …
        #expect(xml.components(separatedBy: "id=\"series-tagx\"").count - 1 == 1)
        // … und die eigene Sammlung weicht samt ihrer Verweise darauf aus.
        #expect(xml.contains("id=\"series-tagx-2\""))
        #expect(xml.contains("refines=\"#series-tagx-2\""))
        #expect(try EbookTool.readCoreFields(url: url).series == "Neue Reihe")
    }

    @Test("EPUB: Platzmangel bleibt als solcher erkennbar",
          .enabled(if: TestVolume.isSupported, "hdiutil nicht verfügbar"))
    func epubOutOfSpaceKeepsTypedError() throws {
        // `notEnoughSpace` trägt die konkrete Ursache (und den Originalpfad).
        // Die EPUB-Fehlervereinheitlichung darf ihn nicht zu einem
        // nichtssagenden `saveFailed` verwischen.
        let volume = try TestVolume(megabytes: 12)
        defer { volume.detach() }
        let url = volume.mountPoint.appendingPathComponent("book2.epub")
        try FileManager.default.copyItem(
            at: Fixtures.directory.appendingPathComponent("book2.epub"), to: url)
        try volume.fillRemainingSpace()

        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.title = "Passt nicht mehr"
        do {
            try EbookTool.writeCoreFields(url: url, fields: changed, original: original)
            Issue.record("Das Schreiben hätte am Platz scheitern müssen")
        } catch TagError.notEnoughSpace {
            // erwartet: der konkrete Grund bleibt sichtbar
        }
        #expect(try EbookTool.readCoreFields(url: url).title == original.title)
    }

    // MARK: - Struktur-Invarianten der OPF

    @Test("EPUB: Geänderte ISBN bleibt der Paket-Identifier",
          arguments: [("book2.epub", "OEBPS/content.opf"), ("book3.epub", "OEBPS/package.opf")])
    func epubIsbnChangeKeepsPackageIdentifier(fixture: String, opfPath: String) throws {
        // Beide Fixtures verwenden den ISBN-Knoten als <package
        // unique-identifier="uid">. Wird er beim Schreiben ersetzt, muss der
        // Verweis mitwandern — sonst entsteht ein strukturell ungültiges EPUB,
        // das der reine Feld-Roundtrip nicht bemerkt.
        let url = try Fixtures.workingCopy(fixture)
        let original = try EbookTool.readCoreFields(url: url)
        var changed = original
        changed.isbn = "9780306406157X"
        try EbookTool.writeCoreFields(url: url, fields: changed, original: original)

        #expect(try EbookTool.readCoreFields(url: url).isbn == "9780306406157X")
        #expect(try packageIdentifierValue(of: url, opfPath: opfPath)
                == "urn:isbn:9780306406157X")
    }

    @Test("EPUB: Gelöschte ISBN hinterlässt keinen verwaisten Paket-Identifier",
          arguments: [("book2.epub", "OEBPS/content.opf"), ("book3.epub", "OEBPS/package.opf")])
    func epubIsbnDeletionKeepsPackageIdentifier(fixture: String, opfPath: String) throws {
        let url = try Fixtures.workingCopy(fixture)
        let original = try EbookTool.readCoreFields(url: url)
        var cleared = original
        cleared.isbn = ""
        try EbookTool.writeCoreFields(url: url, fields: cleared, original: original)

        #expect(try EbookTool.readCoreFields(url: url).isbn == "")
        // Der Verweis muss weiterhin auflösen — jetzt auf einen neutralen
        // UUID-Identifier, nicht mehr auf eine ISBN.
        let value = try packageIdentifierValue(of: url, opfPath: opfPath)
        #expect(value.hasPrefix("urn:uuid:"))
    }

    /// Prüft die EPUB-Grundregel und liefert den Wert des Paket-Identifiers:
    /// `<package unique-identifier="…">` muss auf einen vorhandenen
    /// `dc:identifier` mit genau dieser id zeigen.
    private func packageIdentifierValue(of url: URL, opfPath: String) throws -> String {
        let document = try XMLDocument(xmlString: try opfContents(of: url, path: opfPath))
        let package = try #require(document.rootElement())
        // Über die Attributliste statt `attribute(forName:)`: FoundationXML
        // (Linux) findet Attribute eines Elements mit Standard-Namespace so nicht.
        let uid = try #require(package.attributes?.first { $0.name == "unique-identifier" }?.stringValue)
        let metadata = try #require(package.elements(forName: "metadata").first)
        // In Einzelschritten, sonst gibt der Linux-Compiler (6.0) beim
        // Typprüfen dieser Kette auf.
        let elements = (metadata.children ?? []).compactMap { $0 as? XMLElement }
        let identifiers = elements.filter { element in
            let localName = (element.name ?? "").split(separator: ":").last.map(String.init) ?? ""
            return localName == "identifier"
        }
        let match = try #require(
            identifiers.first { element in
                element.attributes?.first { $0.name == "id" }?.stringValue == uid
            })
        return match.stringValue ?? ""
    }

    /// Schreibt die OPF-Datei eines Test-EPUBs als rohen XML-Text um — zum
    /// Einschleusen von Metadaten, die die Fixtures nicht enthalten.
    func rewriteOpf(in url: URL, path: String,
                            _ transform: (String) -> String) throws {
        let archive = try Archive(url: url, accessMode: .update)
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = transform(String(decoding: data, as: UTF8.self))
        try archive.remove(entry)
        let newData = Data(xml.utf8)
        try archive.addEntry(with: path, type: .file,
                             uncompressedSize: Int64(newData.count),
                             compressionMethod: .deflate) { position, size in
            newData.subdata(in: Int(position)..<(Int(position) + size))
        }
    }

    /// Liest die OPF-Datei als Text (für Erhaltungs-Prüfungen am rohen XML).
    func opfContents(of url: URL, path: String) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }
}

@testable import EInvoiceCore
import Foundation
import Testing

extension EInvoiceTests {
    @Test("PDF: eingebettete Rechnung samt XMP-Deklaration; PDF ohne Rechnung meldet Fehler",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfExtraction() throws {
        try withTempDirectory { dir in
            let pdfURL = dir.appendingPathComponent("rechnung.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8), fileName: "factur-x.xml")
                .write(to: pdfURL)

            let doc = try EInvoiceReader.read(url: pdfURL)
            #expect(doc.syntax == .cii)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
            #expect(doc.pdfDeclaration?.conformanceLevel == "EN 16931")
            #expect(doc.pdfDeclaration?.documentFileName == "factur-x.xml")

            let plainURL = dir.appendingPathComponent("leer.pdf")
            try Self.makePDF(embedding: nil, fileName: nil).write(to: plainURL)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: plainURL)
            }
        }
    }

    @Test("PDF: eingebettete Order-X-Bestellung (order-x.xml) wird als Bestellung gelesen",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfWithOrderX() throws {
        try withTempDirectory { dir in
            let pdfURL = dir.appendingPathComponent("bestellung.pdf")
            try Self.makePDF(embedding: Data(Self.orderXXML.utf8), fileName: "order-x.xml")
                .write(to: pdfURL)
            let doc = try EInvoiceReader.read(url: pdfURL)
            #expect(doc.syntax == .ciiOrder)
            #expect(doc.documentKind == .order)
            #expect(doc.source == .pdfEmbedded(fileName: "order-x.xml"))
            #expect(doc.summary.invoiceNumber == "B-2026-7")
        }
    }

    @Test("containsInvoice(url:) bleibt als Übergangs-API mit altem Verhalten",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    @available(*, deprecated) // Absicht: Der Test ruft die veraltete Methode auf.
    func containsInvoiceCompatibilityWrapper() throws {
        try withTempDirectory { dir in
            // XML: Rechnung ja, Fremd-XML nein.
            let xmlURL = dir.appendingPathComponent("rechnung.xml")
            try Data(Self.ciiXML.utf8).write(to: xmlURL)
            #expect(EInvoiceReader.containsInvoice(url: xmlURL))
            let foreignURL = dir.appendingPathComponent("fremd.xml")
            try Data("<?xml version=\"1.0\"?><plist/>".utf8).write(to: foreignURL)
            #expect(!EInvoiceReader.containsInvoice(url: foreignURL))

            // PDF: mit eingebetteter Rechnung ja, ohne nein.
            let pdfURL = dir.appendingPathComponent("rechnung.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8), fileName: "factur-x.xml")
                .write(to: pdfURL)
            #expect(EInvoiceReader.containsInvoice(url: pdfURL))
            let plainURL = dir.appendingPathComponent("leer.pdf")
            try Self.makePDF(embedding: nil, fileName: nil).write(to: plainURL)
            #expect(!EInvoiceReader.containsInvoice(url: plainURL))

            // Andere Endungen galten schon immer als "keine Rechnung".
            let txtURL = dir.appendingPathComponent("rechnung.txt")
            try Data(Self.ciiXML.utf8).write(to: txtURL)
            #expect(!EInvoiceReader.containsInvoice(url: txtURL))
        }
    }

    @Test("XMP-Deklaration: Namensraum entscheidet, nicht das Präfix",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfDeclarationResolvesAttributeNamespaces() throws {
        try withTempDirectory { dir in
            // Kurzform (Werte als Attribute) mit frei gewähltem Präfix "inv":
            // muss erkannt werden, weil der Namensraum der Factur-X-URI ist.
            let customPrefix = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:inv="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
                  inv:DocumentFileName="factur-x.xml"
                  inv:ConformanceLevel="EN 16931"/>
              </rdf:RDF>
            </x:xmpmeta>
            """
            let customURL = dir.appendingPathComponent("custom-prefix.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8),
                             fileName: "factur-x.xml", xmp: customPrefix)
                .write(to: customURL)
            let doc = try EInvoiceReader.read(url: customURL)
            #expect(doc.pdfDeclaration?.documentFileName == "factur-x.xml")
            #expect(doc.pdfDeclaration?.conformanceLevel == "EN 16931")

            // Ein fremdes Schema darf auch dann KEINE Deklaration vortäuschen,
            // wenn seine URI den auffälligen Mittelteil des echten Namensraums
            // absichtlich übernimmt.
            let foreignNamespace = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                  xmlns:fx="urn:example:pdfa:CrossIndustryDocument:fake#"
                  fx:Version="99" fx:ConformanceLevel="FAKE"/>
              </rdf:RDF>
            </x:xmpmeta>
            """
            let foreignURL = dir.appendingPathComponent("foreign-prefix.pdf")
            try Self.makePDF(embedding: Data(Self.ciiXML.utf8),
                             fileName: "factur-x.xml", xmp: foreignNamespace)
                .write(to: foreignURL)
            let foreignDoc = try EInvoiceReader.read(url: foreignURL)
            #expect(foreignDoc.pdfDeclaration == nil)
        }
    }

    @Test("PDF: XMP-Dateiname gewinnt; ohne Deklaration bleibt die Anhangsreihenfolge",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfCandidateOrderFollowsDeclarationAndPDF() throws {
        try withTempDirectory { dir in
            let declaredXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-XMP")
            let declaredXMP = Self.invoiceXMP(fileName: "declared.xml")
            let declaredURL = dir.appendingPathComponent("declared.pdf")
            try Self.makePDF(embeddings: [
                (Data(Self.ciiXML.utf8), "factur-x.xml"),
                (Data(declaredXML.utf8), "declared.xml"),
            ], xmp: declaredXMP).write(to: declaredURL)

            let declared = try EInvoiceReader.read(url: declaredURL)
            #expect(declared.source == .pdfEmbedded(fileName: "declared.xml"))
            #expect(declared.summary.invoiceNumber == "R-XMP")

            let firstXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-FIRST")
            let secondXML = Self.ciiXML.replacingOccurrences(of: "R-1", with: "R-SECOND")
            let orderedURL = dir.appendingPathComponent("ordered.pdf")
            try Self.makePDF(embeddings: [
                (Data(firstXML.utf8), "zuerst.xml"),
                (Data(secondXML.utf8), "alphabetisch-frueher.xml"),
            ], xmp: Self.foreignXMP).write(to: orderedURL)

            let ordered = try EInvoiceReader.read(url: orderedURL)
            #expect(ordered.source == .pdfEmbedded(fileName: "zuerst.xml"))
            #expect(ordered.summary.invoiceNumber == "R-FIRST")
        }
    }

    // MARK: - Such- und Entpackgrenzen

    @Test("PDF: Rechnung im AF-Array gewinnt gegen einen gefluteten Namensbaum",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfAFInvoiceSurvivesFloodedNameTree() throws {
        try withTempDirectory { dir in
            // 33 fremde XML-Anhänge im Namensbaum liegen ÜBER dem Dateibudget
            // (32); die echte Rechnung steht nur im AF-Array — genau dort, wo
            // ZUGFeRD/Factur-X sie verlangen. Sie muss trotzdem gefunden werden.
            let url = dir.appendingPathComponent("geflutet-af.pdf")
            try Self.makeFloodedPDF(junkCount: 33, invoiceViaAF: true, xmp: nil)
                .write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Die XMP-deklarierte Datei bekommt einen reservierten Budget-Platz",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfDeclaredFileBypassesFileBudget() throws {
        try withTempDirectory { dir in
            // Kein AF-Array; die deklarierte Rechnung steht als LETZTER von 34
            // Namensbaum-Einträgen, hinter 33 fremden XMLs. Der reservierte
            // Platz für die deklarierte Datei muss sie trotzdem aufnehmen.
            let url = dir.appendingPathComponent("geflutet-deklariert.pdf")
            try Self.makeFloodedPDF(junkCount: 33, invoiceViaAF: false,
                                    xmp: Self.invoiceXMP(fileName: "factur-x.xml"))
                .write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.source == .pdfEmbedded(fileName: "factur-x.xml"))
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein sich selbst referenzierender Namensbaum blockiert nicht",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"),
          .timeLimit(.minutes(1)))
    func pdfCyclicNameTreeTerminates() throws {
        try withTempDirectory { dir in
            // Objekt 4 verweist unter /Kids ZWEIMAL auf sich selbst: Mit einer
            // reinen Tiefengrenze (32) wären das 2^32 Besuche. Das
            // Knoten-Budget bricht die Wanderung ab; die Rechnung im AF-Array
            // muss trotzdem gefunden werden.
            let xml = Self.ciiXML
            let objects = [
                "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles 4 0 R >> /AF [ 6 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Kids [ 4 0 R 4 0 R ] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) /EF << /F 5 0 R /UF 5 0 R >> >>",
            ]
            let url = dir.appendingPathComponent("zyklus.pdf")
            try Self.assemblePDF(objects: objects).write(to: url)
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: überlange, kaskadierte oder Überlauf ankündigende Streams werden übersprungen",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfOversizedStreamsAreSkipped() throws {
        try withTempDirectory { dir in
            // CGPDFStreamCopyData dekomprimiert immer vollständig im Speicher.
            // Die Vorprüfung muss solche Streams deshalb VOR dem Entpacken
            // aussortieren; ohne verwertbaren Anhang ist das Ergebnis ehrlich
            // "keine E-Rechnung".
            let xml = Self.ciiXML
            func poisonedPDF(streamDict: String) -> Data {
                Self.assemblePDF(objects: [
                    "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles "
                        + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                    "\(streamDict)\nstream\n\(xml)\nendstream",
                    "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                        + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                ])
            }
            // Deklarierte Größe über dem Gesamtbudget (64 MiB) …
            let lengthLie = dir.appendingPathComponent("laenge.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length 104857600 >>")
                .write(to: lengthLie)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: lengthLie)
            }
            // … kaskadierte Filter (potenzierte Entpackungsrate) …
            let chain = dir.appendingPathComponent("filterkette.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                + "/Filter [ /FlateDecode /FlateDecode ] >>").write(to: chain)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: chain)
            }
            // … und ein angekündigtes Entpackungs-Volumen über dem Gesamtbudget.
            let sizeLie = dir.appendingPathComponent("params.pdf")
            try poisonedPDF(streamDict: "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                + "/Params << /Size 104857600 >> >>").write(to: sizeLie)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: sizeLie)
            }
        }
    }

#if canImport(CoreGraphics)
    @Test("PDF: Auch verworfene Anhaenge verbrauchen das Entpack-Budget",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfDroppedAttachmentsConsumeBudget() throws {
        try withTempDirectory { dir in
            // Ein Anhang, der das Budget sprengt, wird nicht uebernommen —
            // entpackt (und damit im Speicher materialisiert) war er trotzdem.
            // Zaehlte nur das Behaltene, durfte dieselbe Dekompressionsbombe
            // beliebig oft im Namensbaum stehen und die App lange beschaeftigen
            // (Review-Fund 2026-08-18). Das Budget ist hier klein gesetzt, damit
            // der Test ohne 64-MiB-Fixture auskommt.
            let filler = Data(String(repeating: "a", count: 600).utf8)
            let url = dir.appendingPathComponent("budget.pdf")
            try Self.makePDF(embeddings: [
                (filler, "fuell-1.xml"),
                (filler, "fuell-2.xml"),
                (Data(String(repeating: "b", count: 100).utf8), "spaet.xml"),
            ]).write(to: url)

            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000)

            // fuell-2 sprengt das Anzeigebudget und wird verworfen — die Suche
            // laeuft aber weiter, und „spaet" passt noch hinein.
            #expect(extraction.files.map(\.name) == ["fuell-1.xml", "spaet.xml"])
        }
    }
#endif

#if canImport(CoreGraphics)
    @Test("PDF: Ein zu grosser Anhang beendet die Suche nach der Rechnung nicht",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfOversizedAttachmentDoesNotHideInvoice() throws {
        try withTempDirectory { dir in
            // Der Angriff: EIN Fuellanhang, der allein das Anzeigebudget
            // sprengt, VOR der deklarierten Rechnung. Zaehlte die Entpackarbeit
            // gegen dasselbe Budget, war danach jeder weitere Kandidat gesperrt
            // — die Datei galt als „keine E-Rechnung", waehrend andere Leser
            // dieselbe Rechnung anzeigten (Review-Fund 2026-08-20).
            let url = dir.appendingPathComponent("versteckt.pdf")
            try Self.makePDF(embeddings: [
                (Data(String(repeating: "a", count: 4000).utf8), "fuell-1.xml"),
                (Data(String(repeating: "b", count: 4500).utf8), "fuell-2.xml"),
                (Data(Self.ciiXML.utf8), "factur-x.xml"),
            ]).write(to: url)

            // fuell-2 wird entpackt und dann verworfen; danach liegt die
            // Entpackmenge (8500) ueber dem Anzeigebudget (8000) — genau der
            // Zustand, der frueher jede weitere Suche abwuergte.
            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 8000)
            #expect(extraction.files.map(\.name) == ["fuell-1.xml", "factur-x.xml"])

            let document = try EInvoiceReader.read(url: url)
            #expect(document.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Derselbe Stream unter vielen Namen erschoepft das Arbeitsbudget",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfRepeatedStreamHitsWorkBudget() throws {
        try withTempDirectory { dir in
            // Wiederholungsschutz: Ein Filespec-Array, das vielfach auf
            // denselben grossen Stream zeigt, jeweils unter einem anderen Namen.
            // `seenNames` greift hier nicht — nur das Arbeitsbudget begrenzt,
            // wie oft entpackt wird.
            let payload = String(repeating: "a", count: 600)
            var objects: [String] = [
                "KATALOG-PLATZHALTER",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(payload.utf8.count) >>\nstream\n"
                    + payload + "\nendstream",
            ]
            let streamID = 4
            var af: [String] = []
            for i in 1...20 {
                objects.append("<< /Type /Filespec /F (kopie-\(i).xml) /UF (kopie-\(i).xml) "
                    + "/EF << /F \(streamID) 0 R /UF \(streamID) 0 R >> >>")
                af.append("\(objects.count) 0 R")
            }
            // Ein kleiner Anhang GANZ am Ende: Er passte ins Anzeigebudget,
            // darf aber nicht mehr erreicht werden.
            let spaet = "<klein/>"
            objects.append("<< /Type /EmbeddedFile /Length \(spaet.utf8.count) >>\nstream\n"
                + spaet + "\nendstream")
            let spaetStreamID = objects.count
            objects.append("<< /Type /Filespec /F (spaet.xml) /UF (spaet.xml) "
                + "/EF << /F \(spaetStreamID) 0 R /UF \(spaetStreamID) 0 R >> >>")
            af.append("\(objects.count) 0 R")
            objects[0] = "<< /Type /Catalog /Pages 2 0 R /AF [ \(af.joined(separator: " ")) ] >>"
            let url = dir.appendingPathComponent("wiederholung.pdf")
            try Self.assemblePDF(objects: objects).write(to: url)

            let extraction = try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000)

            // Behalten wird nur, was ins Anzeigebudget passt — und nach dem
            // Vierfachen an Entpackarbeit (sieben der zwanzig Kopien) endet die
            // Suche, „spaet.xml" wird nicht mehr erreicht.
            #expect(extraction.files.map(\.name) == ["kopie-1.xml"])
        }
    }

    @Test("PDF: Eine unkomprimiert eingebettete Rechnung ueber 256 KiB bleibt lesbar",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfLargeUncompressedInvoiceIsRead() throws {
        try withTempDirectory { dir in
            // /Length ist bei einem Stream OHNE /Filter bereits die entpackte
            // Groesse; die Bomben-Schranke von 256 KiB gehoert dort nicht hin.
            // Factur-X schreibt keine Kompression vor, und eine Rechnung mit
            // vielen Positionen wird unkomprimiert schnell groesser
            // (Review-Fund 2026-08-20).
            let padding = String(repeating: " ", count: 300 * 1024)
            let big = Self.ciiXML + "\n<!--" + padding + "-->"
            #expect(big.utf8.count > PDFEmbeddedInvoice.maxCompressedBytes)
            let url = dir.appendingPathComponent("gross-unkomprimiert.pdf")
            try Self.makePDF(embedding: Data(big.utf8), fileName: "factur-x.xml").write(to: url)

            let document = try EInvoiceReader.read(url: url)
            #expect(document.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein angekuendigtes /Params/Size ueber dem uebergebenen Budget zaehlt",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfParamsSizeUsesPassedBudget() throws {
        try withTempDirectory { dir in
            // Frueher pruefte dieser Pfad gegen die Konstante statt gegen das
            // uebergebene Budget — ein Test mit kleinem Budget beruehrte ihn
            // deshalb nie (Review-Fund 2026-08-20).
            let xml = Self.ciiXML
            let url = dir.appendingPathComponent("params-klein.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /AF [ 5 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) "
                    + "/Params << /Size 5000 >> >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
            ]).write(to: url)

            // Mit grossem Budget lesbar …
            #expect(try PDFEmbeddedInvoice.extract(url: url).files.count == 1)
            // … mit einem Budget unter der angekuendigten Groesse nicht.
            #expect(try PDFEmbeddedInvoice.extract(url: url, byteBudget: 1000).files.isEmpty)
        }
    }
#endif

    @Test("PDF: Ein Anhangs-Stream ohne gueltige /Length wird uebersprungen",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfStreamWithoutLengthIsSkipped() throws {
        try withTempDirectory { dir in
            // Fehlte die Laengenangabe oder war sie keine Ganzzahl, liess die
            // Vorpruefung den Stream einfach durch — er umging damit jede
            // Groessenschranke, obwohl CGPDFStreamCopyData ihn vollstaendig im
            // Speicher materialisiert.
            let xml = Self.ciiXML
            func pdf(streamDict: String) -> Data {
                Self.assemblePDF(objects: [
                    "<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles "
                        + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                    "\(streamDict)\nstream\n\(xml)\nendstream",
                    "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                        + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                ])
            }
            // Gar keine /Length …
            let ohneLaenge = dir.appendingPathComponent("ohne-laenge.pdf")
            try pdf(streamDict: "<< /Type /EmbeddedFile >>").write(to: ohneLaenge)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: ohneLaenge)
            }
            // … und eine /Length von 0 (unehrliche Angabe).
            let nullLaenge = dir.appendingPathComponent("null-laenge.pdf")
            try pdf(streamDict: "<< /Type /EmbeddedFile /Length 0 >>").write(to: nullLaenge)
            #expect(throws: EInvoiceError.notAnInvoice) {
                try EInvoiceReader.read(url: nullLaenge)
            }
        }
    }

    @Test("PDF: Ein uebergrosser XMP-Metadatenstrom wird gar nicht erst gelesen",
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfOversizedMetadataIsSkipped() throws {
        try withTempDirectory { dir in
            // `readDeclaration` las den /Metadata-Strom vorher OHNE jede
            // Schranke und baute daraus einen vollstaendigen XML-Baum — schon
            // das blosse Oeffnen eines PDFs war damit angreifbar. Der Inhalt
            // hier ist eine gueltige Factur-X-Deklaration, die deklarierte
            // Laenge liegt aber ueber der XMP-Schranke: Wird der Strom
            // uebersprungen, fehlt die Deklaration — genau der beobachtbare
            // Unterschied. Der Anhang selbst bleibt lesbar.
            let xml = Self.ciiXML
            let xmp = Self.invoiceXMP(fileName: "factur-x.xml")
            let url = dir.appendingPathComponent("xmp-bombe.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /Metadata 6 0 R /Names << /EmbeddedFiles "
                    + "<< /Names [ (factur-x.xml) 5 0 R ] >> >> /AF [ 5 0 R ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                "<< /Type /Metadata /Subtype /XML /Length 9437184 >>\nstream\n\(xmp)\nendstream",
            ]).write(to: url)

            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.pdfDeclaration == nil,
                    "Ein Metadatenstrom ueber der Schranke darf nicht gelesen werden.")
            // Die Rechnung wird trotzdem ueber den Anhang gefunden.
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    @Test("PDF: Ein breites /AF-Array bleibt im Arbeitsbudget", .timeLimit(.minutes(1)),
          .enabled(if: EInvoiceReader.isPDFExtractionAvailable, "PDF-Extraktion braucht CoreGraphics"))
    func pdfWideAFArrayTerminates() throws {
        try withTempDirectory { dir in
            // Waechter fuer das gemeinsame Arbeitsbudget (Review-Fund
            // 2026-08-17): Das Knotenbudget zaehlte nur rekursive Dictionaries,
            // ein breites /AF-Array lief trotzdem vollstaendig durch. Dieser
            // Test faellt nicht gegen den alten Stand — er haelt fest, dass die
            // Rechnung trotz Budgetgrenze weiterhin gefunden wird, damit die
            // Grenze nicht heimlich wieder verschwindet oder zu eng wird.
            let xml = Self.ciiXML
            let verweise = Array(repeating: "6 0 R", count: 40_000).joined(separator: " ")
            let url = dir.appendingPathComponent("breites-af.pdf")
            try Self.assemblePDF(objects: [
                "<< /Type /Catalog /Pages 2 0 R /AF [ 5 0 R \(verweise) ] >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
                "<< /Type /EmbeddedFile /Length \(xml.utf8.count) >>\nstream\n\(xml)\nendstream",
                "<< /Type /Filespec /F (factur-x.xml) /UF (factur-x.xml) "
                    + "/EF << /F 4 0 R /UF 4 0 R >> >>",
                "<< /Type /Filespec /F (fuell.xml) /UF (fuell.xml) >>",
            ]).write(to: url)

            // Die echte Rechnung steht vorn und wird trotzdem gefunden.
            let doc = try EInvoiceReader.read(url: url)
            #expect(doc.summary.invoiceNumber == "R-1")
        }
    }

    /// Baut ein minimales, gültiges PDF — optional mit eingebetteten Dateien
    /// (Namensbaum + AF-Array wie bei ZUGFeRD) und Factur-X-XMP-Deklaration
    /// (überschreibbar, um Präfix-/Namensraum-Varianten zu testen).
    /// Handgeschrieben statt Bibliothek: Der Test soll genau die Strukturen
    /// erzeugen, die der Leser abläuft.
    private static func makePDF(embedding payload: Data?, fileName: String?,
                                xmp customXMP: String? = nil) -> Data {
        let embeddings: [(Data, String)]
        if let payload, let fileName {
            embeddings = [(payload, fileName)]
        } else {
            embeddings = []
        }
        return makePDF(embeddings: embeddings, xmp: customXMP)
    }

    private static func makePDF(embeddings: [(payload: Data, fileName: String)],
                                xmp customXMP: String? = nil) -> Data {
        var objects: [String] = []
        let xmp = customXMP ?? invoiceXMP(fileName: "factur-x.xml")

        if !embeddings.isEmpty {
            let filespecIDs = embeddings.indices.map { 5 + $0 * 2 }
            let names = zip(embeddings, filespecIDs).map {
                "(\($0.0.fileName)) \($0.1) 0 R"
            }.joined(separator: " ")
            let af = filespecIDs.map { "\($0) 0 R" }.joined(separator: " ")
            let metadataID = 4 + embeddings.count * 2
            objects.append("""
            << /Type /Catalog /Pages 2 0 R /Metadata \(metadataID) 0 R \
            /Names << /EmbeddedFiles << /Names [ \(names) ] >> >> \
            /AF [ \(af) ] >>
            """)
            objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")

            for embedding in embeddings {
                let streamID = objects.count + 1
                objects.append("<< /Type /EmbeddedFile /Length \(embedding.payload.count) >>\nstream\n"
                    + String(decoding: embedding.payload, as: UTF8.self) + "\nendstream")
                objects.append("""
                << /Type /Filespec /F (\(embedding.fileName)) /UF (\(embedding.fileName)) \
                /AFRelationship /Alternative /EF << /F \(streamID) 0 R \
                /UF \(streamID) 0 R >> >>
                """)
            }
            objects.append("<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n"
                + xmp + "\nendstream")
        } else {
            objects.append("<< /Type /Catalog /Pages 2 0 R >>")
            objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")
        }

        return assemblePDF(objects: objects)
    }

    /// PDF mit `junkCount` fremden XML-Anhängen im Namensbaum und einer
    /// echten Rechnung, die je nach Test NUR im AF-Array oder als LETZTER
    /// Namensbaum-Eintrag steht — die Flutungs-Szenarien gegen das Dateibudget.
    private static func makeFloodedPDF(junkCount: Int, invoiceViaAF: Bool,
                                       xmp customXMP: String?) -> Data {
        var objects: [String] = []
        func addObject(_ body: String) -> Int {
            objects.append(body)
            return objects.count // Objektnummern sind 1-basiert
        }
        // Katalog zuerst reservieren (Objekt 1); er braucht die erst später
        // bekannten Verweise und wird am Ende ersetzt.
        _ = addObject("KATALOG-PLATZHALTER")
        _ = addObject("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        _ = addObject("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>")

        func addAttachment(payload: String, name: String) -> Int {
            let streamID = addObject(
                "<< /Type /EmbeddedFile /Length \(payload.utf8.count) >>\nstream\n"
                    + payload + "\nendstream")
            return addObject("<< /Type /Filespec /F (\(name)) /UF (\(name)) "
                + "/EF << /F \(streamID) 0 R /UF \(streamID) 0 R >> >>")
        }

        var nameEntries: [String] = []
        for i in 1...junkCount {
            let id = addAttachment(payload: "<fremd-\(i)/>", name: "fremd-\(i).xml")
            nameEntries.append("(fremd-\(i).xml) \(id) 0 R")
        }
        let invoiceID = addAttachment(payload: ciiXML, name: "factur-x.xml")
        var af = ""
        if invoiceViaAF {
            af = " /AF [ \(invoiceID) 0 R ]"
        } else {
            nameEntries.append("(factur-x.xml) \(invoiceID) 0 R")
        }
        var metadata = ""
        if let customXMP {
            let id = addObject("<< /Type /Metadata /Subtype /XML /Length "
                + "\(customXMP.utf8.count) >>\nstream\n" + customXMP + "\nendstream")
            metadata = " /Metadata \(id) 0 R"
        }
        objects[0] = "<< /Type /Catalog /Pages 2 0 R\(metadata) /Names "
            + "<< /EmbeddedFiles << /Names [ \(nameEntries.joined(separator: " ")) ] >> >>\(af) >>"
        return assemblePDF(objects: objects)
    }

    /// Setzt nummerierte Objekte (1 = Katalog) zu einem PDF mit korrekter
    /// xref-Tabelle zusammen. Getrennt von makePDF, damit Tests auch bewusst
    /// präparierte Strukturen (Zyklen, gelogene Stream-Größen) bauen können.
    private static func assemblePDF(objects: [String]) -> Data {
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xrefOffset = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n"
        pdf += "0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        pdf += "startxref\n\(xrefOffset)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    private static func invoiceXMP(fileName: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">
              <fx:DocumentType>INVOICE</fx:DocumentType>
              <fx:DocumentFileName>\(fileName)</fx:DocumentFileName>
              <fx:Version>1.0</fx:Version>
              <fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private static let foreignXMP = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:other="urn:example:metadata"
          other:DocumentFileName="zuerst.xml"/>
      </rdf:RDF>
    </x:xmpmeta>
    """
}

// CLI-Regressionen für `tagx invoice` und den Umgang des Archivs mit
// E-Rechnungen: --terms-only muss auch die JSON-Ausgabe filtern, und
// `tagx export` darf Rechnungen weder mitzählen noch still überspringen.
import EInvoiceCore
import Foundation
import TagExplosionTestSupport
import Testing

@Suite("tagx invoice CLI")
struct InvoiceCommandTests {

    /// Minimale CII-Rechnung: ein gemapptes Feld (BT-1) und bewusst ein
    /// Element ohne EN-16931-Zuordnung (ram:Fantasiefeld).
    private static let ciiXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rsm:CrossIndustryInvoice
      xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100">
      <rsm:ExchangedDocumentContext>
        <ram:GuidelineSpecifiedDocumentContextParameter>
          <ram:ID>urn:cen.eu:en16931:2017</ram:ID>
        </ram:GuidelineSpecifiedDocumentContextParameter>
      </rsm:ExchangedDocumentContext>
      <rsm:ExchangedDocument>
        <ram:ID>R-42</ram:ID>
        <ram:Fantasiefeld>nur Anzeige</ram:Fantasiefeld>
      </rsm:ExchangedDocument>
    </rsm:CrossIndustryInvoice>
    """

    /// Minimale Order-X-Bestellung (BASIC): keine BT-Nummern, keine
    /// Rechnungs-Hinweise.
    private static let orderXXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rsm:SCRDMCCBDACIOMessageStructure
      xmlns:rsm="urn:un:unece:uncefact:data:SCRDMCCBDACIOMessageStructure:100"
      xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:128">
      <rsm:ExchangedDocumentContext>
        <ram:GuidelineSpecifiedDocumentContextParameter>
          <ram:ID>urn:order-x.eu:1p0:basic</ram:ID>
        </ram:GuidelineSpecifiedDocumentContextParameter>
      </rsm:ExchangedDocumentContext>
      <rsm:ExchangedDocument>
        <ram:ID>B-1</ram:ID>
        <ram:TypeCode>220</ram:TypeCode>
      </rsm:ExchangedDocument>
    </rsm:SCRDMCCBDACIOMessageStructure>
    """

    private func withInvoiceFile<T>(xml content: String = InvoiceCommandTests.ciiXML,
                                    _ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-invoice-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = dir.appendingPathComponent("rechnung.xml")
        try Data(content.utf8).write(to: xml)
        return try body(xml)
    }

    @Test("--json --terms-only filtert ungemappte Felder auch in der JSON-Ausgabe")
    func jsonRespectsTermsOnly() throws {
        try withInvoiceFile { xml in
            let full = try runTagx(arguments: ["invoice", xml.path, "--json"])
            #expect(full.status == 0)
            #expect(try invoice(from: full.stdout).fields.contains { $0.element == "ram:Fantasiefeld" })

            let filtered = try runTagx(arguments: [
                "invoice", xml.path, "--json", "--terms-only",
            ])
            #expect(filtered.status == 0)
            let document = try invoice(from: filtered.stdout)
            #expect(document.firstValue(term: "BT-1") == "R-42")
            #expect(!document.fields.contains { $0.element == "ram:Fantasiefeld" })
        }
    }

    @Test("Hinweise: Textausgabe und JSON nennen Dokumentart und Warnungen; --strict liefert Exit 3")
    func warningsAndStrictExitCode() throws {
        try withInvoiceFile { xml in
            // Die Minimalrechnung hat absichtlich fast keine Pflichtfelder.
            let text = try runTagx(arguments: ["invoice", xml.path])
            #expect(text.status == 0)
            #expect(text.stdout.contains("KIND: invoice"))
            #expect(text.stdout.contains("WARNINGS: 9"))
            #expect(text.stdout.contains("WARNING [BR-03] BT-2: Pflichtfeld fehlt: BT-2 Rechnungsdatum"))
            #expect(!text.stdout.contains("[BR-02]"))  // BT-1 ist vorhanden

            let json = try runTagx(arguments: ["invoice", xml.path, "--json", "--strict"])
            #expect(json.status == 3)
            let document = try invoice(from: json.stdout)
            #expect(document.documentKind == .invoice)
            #expect(document.warnings.count == 9)
            #expect(document.warnings.contains { $0.code == "BR-03" && $0.term == "BT-2" })

            // --strict: Ausgabe bleibt vollständig, nur der Exit-Code ändert sich.
            let strict = try runTagx(arguments: ["invoice", xml.path, "--strict"])
            #expect(strict.status == 3)
            #expect(strict.stdout.contains("WARNINGS: 9"))
        }
    }

    @Test("Order-X: Dokumentart order, Order-X-Bezeichnungen, keine Hinweise, --strict Exit 0")
    func orderXOutput() throws {
        try withInvoiceFile(xml: Self.orderXXML) { xml in
            let text = try runTagx(arguments: ["invoice", xml.path, "--strict"])
            #expect(text.status == 0)
            #expect(text.stdout.contains("STANDARD: Order-X"))
            #expect(text.stdout.contains("PROFILE: BASIC"))
            #expect(text.stdout.contains("KIND: order"))
            #expect(text.stdout.contains("WARNINGS: 0"))
            #expect(text.stdout.contains("ram:ID = B-1  [Bestellnummer]"))
            #expect(text.stdout.contains("[Code für die Dokumentart]  → Bestellung"))

            // --terms-only behält beschriftete Order-X-Felder.
            let filtered = try runTagx(arguments: ["invoice", xml.path, "--json", "--terms-only"])
            #expect(filtered.status == 0)
            let document = try invoice(from: filtered.stdout)
            #expect(document.documentKind == .order)
            #expect(document.fields.contains { $0.termName == "Bestellnummer" && $0.value == "B-1" })
        }
    }

    @Test("export zählt E-Rechnungen nicht als archivierte Dateien")
    func exportRejectsInvoiceOnlyInput() throws {
        try withInvoiceFile { xml in
            let target = xml.deletingLastPathComponent()
                .appendingPathComponent("tags.json").path
            let result = try runTagx(arguments: ["export", xml.path, "-o", target])
            #expect(result.status != 0)
            #expect(result.stderr.contains("display-only"))
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    private func invoice(from output: String) throws -> EInvoiceDocument {
        struct Report: Decodable { let invoice: EInvoiceDocument }
        let reports = try JSONDecoder().decode([Report].self, from: Data(output.utf8))
        return try #require(reports.first).invoice
    }

}

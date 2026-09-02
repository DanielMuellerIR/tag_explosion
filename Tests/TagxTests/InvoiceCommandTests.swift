// CLI-Regressionen für `tagx invoice` und den Umgang des Archivs mit
// E-Rechnungen: --terms-only muss auch die JSON-Ausgabe filtern, und
// `tagx export` darf Rechnungen weder mitzählen noch still überspringen.
import Foundation
import Testing

@Suite("tagx invoice CLI", .serialized)
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
            #expect(full.stdout.contains("Fantasiefeld"))

            let filtered = try runTagx(arguments: [
                "invoice", xml.path, "--json", "--terms-only",
            ])
            #expect(filtered.status == 0)
            #expect(filtered.stdout.contains("BT-1"))
            #expect(!filtered.stdout.contains("Fantasiefeld"))
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

            let json = try runTagx(arguments: ["invoice", xml.path, "--json"])
            #expect(json.status == 0)
            #expect(json.stdout.contains("\"documentKind\" : \"invoice\""))
            #expect(json.stdout.contains("\"code\" : \"BR-03\""))
            #expect(json.stdout.contains("\"term\" : \"BT-2\""))

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
            #expect(filtered.stdout.contains("\"documentKind\" : \"order\""))
            #expect(filtered.stdout.contains("Bestellnummer"))
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

    // MARK: - Prozess-Helfer (gleiches Muster wie die übrigen CLI-Tests)

    private func runTagx(arguments: [String]) throws
    -> CapturedProcessResult {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runCapturedProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try runCapturedProcess(
            executable: URL(fileURLWithPath: binaryDirectory)
                .appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
    }

}

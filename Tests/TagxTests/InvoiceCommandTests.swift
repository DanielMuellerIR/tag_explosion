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

    private func withInvoiceFile<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagx-invoice-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = dir.appendingPathComponent("rechnung.xml")
        try Data(Self.ciiXML.utf8).write(to: xml)
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
    -> (status: Int32, stdout: String, stderr: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binPath = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["swift", "build", "--product", "tagx", "--show-bin-path"],
            currentDirectory: root
        )
        let binaryDirectory = binPath.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try runProcess(
            executable: URL(fileURLWithPath: binaryDirectory)
                .appendingPathComponent("tagx").path,
            arguments: arguments,
            currentDirectory: root
        )
    }

    private func runProcess(executable: String, arguments: [String], currentDirectory: URL) throws
    -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self))
    }
}

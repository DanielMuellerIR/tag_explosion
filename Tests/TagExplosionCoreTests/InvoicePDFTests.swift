import EInvoiceCore
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("PDF-Prüfbericht: Vollständigkeit")
struct InvoicePDFReportTests {
    private var valid: String {
        """
        <report><buildInformation><releaseDetails id="core" version="1.30.3"/><releaseDetails id="validation-model" version="1.30.3"/><releaseDetails id="apps" version="1.30.3"/></buildInformation><jobs><job><validationReport jobEndStatus="normal" profileName="PDF/A-3b validation profile" isCompliant="true"><details passedRules="146" failedRules="0" passedChecks="201" failedChecks="0"/></validationReport></job></jobs><batchSummary totalJobs="1" failedToParse="0" encrypted="0" outOfMemory="0" veraExceptions="0"><validationReports compliant="1" nonCompliant="0" failedJobs="0">1</validationReports></batchSummary></report>
        """
    }
    @Test("Nur vollständiger, konsistenter Einzelauftrag bestätigt PDF/A")
    func completeReport() throws {
        #expect(try InvoicePDFValidator.parseReport(Data(valid.utf8)).compliant)
        for invalid in [
            valid.replacingOccurrences(of: "totalJobs=\"1\"", with: "totalJobs=\"2\""),
            valid.replacingOccurrences(of: "version=\"1.30.3\"", with: "version=\"1.30.2\""),
            valid.replacingOccurrences(of: "jobEndStatus=\"normal\"", with: "jobEndStatus=\"failed\""),
            valid.replacingOccurrences(of: "outOfMemory=\"0\"", with: "outOfMemory=\"1\""),
            valid.replacingOccurrences(of: "failedChecks=\"0\"", with: "failedChecks=\"1\""),
            valid.replacingOccurrences(of: "passedChecks=\"201\"", with: "passedChecks=\"0\""),
            valid.replacingOccurrences(of: "</jobs>", with: "<job/></jobs>"),
        ] {
            #expect(throws: (any Error).self) { try InvoicePDFValidator.parseReport(Data(invalid.utf8)) }
        }
    }

    @Test("AF und Namensbaum müssen dieselbe Einbettung enthalten", .enabled(if: EInvoiceReader.isPDFExtractionAvailable))
    func attachmentIdentity() throws {
        let xml = Data(InvoiceValidationFixtures.facturX(profile: "EN16931").utf8)
        let valid = try EInvoiceReader.inspectPDF(InvoiceValidationFixtures.hybridPDF(xml: xml), selectedXML: xml)
        #expect(valid.complete)
        #expect(valid.attachments.count == 1)
        #expect(valid.attachments[0].inAssociatedFiles && valid.attachments[0].inNameTree)
        #expect(valid.attachments[0].matchesSelectedXML)
        let duplicate = try EInvoiceReader.inspectPDF(InvoiceValidationFixtures.hybridPDF(xml: xml, variant: "duplicate-invoice"), selectedXML: xml)
        #expect(duplicate.attachments.filter(\.isInvoice).count == 2)
    }
}

@Suite("Hybride Rechnung: echte KoSIT-/veraPDF-Laufzeit", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["TAGX_PDF_VALIDATION_BUNDLE"] != nil && EInvoiceReader.isPDFExtractionAvailable))
struct InvoicePDFRuntimeTests {
    private var core: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAGX_VALIDATION_BUNDLE"]!) }
    private var pdf: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAGX_PDF_VALIDATION_BUNDLE"]!) }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hybrid-invoice-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Gültiges XML und gültiger PDF/A-3b-/4f-Träger bleiben getrennt nachweisbar", arguments: ["valid", "pdfa3a", "pdfa3u", "pdfa4f", "legacy"])
    func validHybrid(_ variant: String) throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("invoice.pdf")
        let bytes = InvoiceValidationFixtures.hybridPDF(xml: Data(InvoiceValidationFixtures.facturX(profile: "EN16931").utf8), variant: variant)
        try bytes.write(to: file)
        let result = InvoiceValidationService.validate(url: file, bundle: core, pdfBundle: pdf)
        #expect(result.status == (variant == "legacy" ? .passedWithWarnings : .passed), "\(result.issues)")
        #expect(result.xmlStatus == .passed)
        #expect(result.pdf?.status == (variant == "legacy" ? .passedWithWarnings : .passed))
        let profileName = ["pdfa4f": "PDF/A-4f", "pdfa3a": "PDF/A-3a", "pdfa3u": "PDF/A-3u"][variant] ?? "PDF/A-3b"
        #expect(result.pdf?.profile == profileName + " validation profile")
        #expect(result.steps.allSatisfy { $0.status == .passed })
        #expect(result.source?.fileSHA256 == validationDigest(bytes))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Metadaten, AF, MIME und zusätzliche Anhänge erzeugen eigene Funde")
    func invalidContainers() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("invoice.pdf")
        let xml = Data(InvoiceValidationFixtures.facturX(profile: "EN16931").utf8)
        for (variant, code, status): (String, String, InvoiceValidationStatus) in [
            ("wrong-name", "BR-HYBRID-13", .failed), ("missing-schema", "BR-HYBRID-03", .failed),
            ("missing-af", "BR-HYBRID-12", .failed), ("missing-names", "BR-HYBRID-12", .failed),
            ("wrong-mime", "BR-HYBRID-12", .failed), ("duplicate-invoice", "BR-HYBRID-12", .failed),
            ("wrong-attachment", "HYBRID_ATTACHMENT_TYPE", .failed),
            ("wrong-profile", "BR-HYBRID-15", .passedWithWarnings),
            ("wrong-relation", "BR-HYBRID-11", .passedWithWarnings),
            ("missing-pdfa", "PDFA:", .failed),
        ] {
            try InvoiceValidationFixtures.hybridPDF(xml: xml, variant: variant).write(to: file)
            let result = InvoiceValidationService.validate(url: file, bundle: core, pdfBundle: pdf)
            #expect(result.xmlStatus == .passed, "\(variant): \(result.issues)")
            #expect(result.status == status, "\(variant): \(result.status), \(result.issues)")
            #expect(result.issues.contains { $0.code?.hasPrefix(code) == true }, "\(variant): \(result.issues)")
        }
    }

    @Test("Fehlendes oder manipuliertes PDF-Werkzeug bestätigt keinen Container und erhält das XML-Ergebnis")
    func unavailablePDFTool() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("invoice.pdf")
        try InvoiceValidationFixtures.hybridPDF(xml: Data(InvoiceValidationFixtures.facturX(profile: "EN16931").utf8)).write(to: file)
        let missing = InvoiceValidationService.validate(url: file, bundle: core, pdfBundle: dir.appendingPathComponent("missing"))
        #expect(missing.status == .technicalError)
        #expect(missing.xmlStatus == .passed)
        #expect(missing.pdf?.pdfaStatus == .notChecked)
        let changed = dir.appendingPathComponent("changed")
        try FileManager.default.copyItem(at: pdf, to: changed)
        try Data("changed".utf8).write(to: changed.appendingPathComponent("validator.jar"))
        let result = InvoiceValidationService.validate(url: file, bundle: core, pdfBundle: changed)
        #expect(result.status == .technicalError)
        #expect(result.xmlStatus == .passed)
        #expect(result.pdf?.embeddingStatus == .notChecked)
    }

    @Test("Allgemeine CLI prüft den PDF-Träger, der bisherige XRechnung-Befehl bleibt kompatibel")
    func cliAndLegacy() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let invoice = dir.appendingPathComponent("invoice.pdf")
        try InvoiceValidationFixtures.hybridPDF(xml: Data(InvoiceValidationFixtures.facturX(profile: "EN16931").utf8)).write(to: invoice)
        let coreLink = dir.appendingPathComponent("XRechnungValidator")
        try FileManager.default.createSymbolicLink(at: coreLink, withDestinationURL: core)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("PDFValidator"), withDestinationURL: pdf)
        struct Output: Decodable { let validation: InvoiceValidationResult }
        let full = try runTagx(arguments: ["validate-invoice", invoice.path, "--bundle", coreLink.path, "--json"])
        #expect(full.status == 0)
        let result = try JSONDecoder().decode([Output].self, from: Data(full.stdout.utf8))[0].validation
        #expect(result.pdf?.status == .passed)
        let legacy = try runTagx(arguments: ["validate-xrechnung", invoice.path, "--bundle", coreLink.path, "--format", "common", "--json"])
        #expect(legacy.status == 5)
        #expect(try JSONDecoder().decode([Output].self, from: Data(legacy.stdout.utf8))[0].validation.pdf == nil)
    }
}

import EInvoiceCore
import Foundation
import TagExplosionTestSupport
import Testing
@testable import TagExplosionCore

@Suite("KoSIT gemeinsamer Dienst: echte Laufzeit",
       .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["TAGX_VALIDATION_BUNDLE"] != nil))
struct InvoiceValidationRuntimeTests {
    private var bundle: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAGX_VALIDATION_BUNDLE"]!) }
    private var fixtures: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["TAGX_VALIDATION_FIXTURES"]!) }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("invoice-runtime-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Alle aktuellen Factur-X-Profile: Erfolg, Schemafehler und Geschäftsregelfehler",
          arguments: ["MINIMUM", "BASICWL", "BASIC", "EN16931", "EXTENDED"])
    func facturXProfiles(_ profile: String) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = InvoiceValidationFixtures.facturX(profile: profile)
        let file = dir.appendingPathComponent("invoice.xml")
        for variant in ["valid", "schema", "rule"] {
            var xml = original
            if variant == "schema" {
                xml = xml.replacingOccurrences(of: "<ram:TypeCode>380", with: "<ram:Unexpected/><ram:TypeCode>380")
            } else if variant == "rule" {
                xml = xml.replacingOccurrences(of: "<ram:SpecifiedLegalOrganization><ram:ID>TEST-SELLER</ram:ID></ram:SpecifiedLegalOrganization>", with: "")
                    .replacingOccurrences(of: "<ram:SpecifiedTaxRegistration><ram:ID schemeID=\"VA\">DE123456789</ram:ID></ram:SpecifiedTaxRegistration>", with: "")
            }
            let bytes = Data(xml.utf8)
            try bytes.write(to: file)
            let result = InvoiceValidationService.validate(url: file, bundle: bundle)
            #expect(result.ruleSet == .facturX)
            #expect(result.scenario == "Factur-X 1.09.2 / ZUGFeRD 2.5.2 (\(profile))")
            #expect(try Data(contentsOf: file) == bytes)
            if variant == "valid" {
                #expect(result.status == .passed)
                #expect(Set(result.steps.map(\.id)) == Set(InvoiceValidationRuleSet.facturX.requiredSteps))
                #expect(result.issues.contains { $0.code == "RULE_VERSION_SCOPE" })
                #expect(result.issues.contains { $0.code == "REDUCED_PROFILE_SCOPE" } == ["MINIMUM", "BASICWL", "BASIC"].contains(profile))
                #expect(try EInvoiceReader.read(url: file).warnings.isEmpty)
                struct Output: Decodable { let validation: InvoiceValidationResult }
                let cli = try runTagx(arguments: ["validate-invoice", file.path, "--bundle", bundle.path, "--json"])
                #expect(cli.status == 0)
                #expect(try JSONDecoder().decode([Output].self, from: Data(cli.stdout.utf8))[0].validation.status == .passed)
                #expect(try runTagx(arguments: ["validate-xrechnung", file.path, "--bundle", bundle.path, "--json"]).status == 4)
            } else {
                #expect(result.status == .failed)
                #expect(result.steps.contains { $0.id == (variant == "schema" ? "val-xsd" : "val-sch.1") && $0.status == .failed })
                if variant == "rule" { #expect(result.issues.contains { $0.code == "BR-CO-26" && $0.severity == .error }) }
            }
        }
    }

    @Test("Echte Factur-X-Warnung bleibt sichtbar und verhindert keinen Erfolg")
    func facturXWarning() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = InvoiceValidationFixtures.facturX(profile: "BASIC")
            .replacingOccurrences(of: "<ram:ActualDeliverySupplyChainEvent><ram:OccurrenceDateTime><udt:DateTimeString format=\"102\">20261016</udt:DateTimeString></ram:OccurrenceDateTime></ram:ActualDeliverySupplyChainEvent>", with: "")
        let file = dir.appendingPathComponent("warning.xml")
        try Data(xml.utf8).write(to: file)
        let result = InvoiceValidationService.validate(url: file, bundle: bundle)
        #expect(result.status == .passedWithWarnings)
        #expect(result.issues.contains { $0.code == "PEPPOL-EN16931-R008" && $0.severity == .warning })
        #expect(result.steps.allSatisfy { $0.status == .passed })
        if EInvoiceReader.isPDFExtractionAvailable {
            let pdf = dir.appendingPathComponent("invoice.pdf")
            try InvoiceValidationFixtures.pdf(attachments: [("factur-x.xml", Data(xml.utf8))]).write(to: pdf)
            let embedded = InvoiceValidationService.validate(url: pdf, bundle: bundle)
            #expect(embedded.status == .partial)
            #expect(embedded.xmlStatus == .passedWithWarnings)
        }
    }

    @Test("CII und UBL prüfen unveränderte Bytes aus XML und PDF", arguments: ["ubl", "cii"])
    func xmlAndPDF(_ syntax: String) throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = try Data(contentsOf: fixtures.appendingPathComponent(syntax + ".xml"))
        let url = dir.appendingPathComponent("invoice.xml")
        try xml.write(to: url)
        let input = try InvoiceValidationInput.capture(at: url)
        let result = InvoiceValidationService.validate(input: input, bundle: bundle)
        #expect([.passed, .passedWithWarnings].contains(result.status))
        #expect(result.xmlStatus == result.status)
        #expect(result.ruleSet == .xrechnung)
        #expect(result.source?.xmlSHA256 == validationDigest(xml))
        #expect(result.isCurrent(at: url))
        #expect(result.steps.count == 4)
        #expect(try Data(contentsOf: url) == xml)
        let extensionURL = dir.appendingPathComponent("extension.xml")
        let extensionXML = Data(String(decoding: xml, as: UTF8.self).replacingOccurrences(of: InvoiceValidationFixtures.guideline,
            with: InvoiceValidationFixtures.guideline + "#conformant#urn:xeinkauf.de:kosit:extension:xrechnung_3.0").utf8)
        try extensionXML.write(to: extensionURL)
        let extensionResult = InvoiceValidationService.validate(url: extensionURL, bundle: bundle)
        #expect([.passed, .passedWithWarnings].contains(extensionResult.status))
        #expect(extensionResult.scenario?.contains("XRechnung Extension") == true)
        guard EInvoiceReader.isPDFExtractionAvailable else { return }
        let pdfURL = dir.appendingPathComponent("invoice.pdf")
        let pdf = InvoiceValidationFixtures.pdf(attachments: [("xrechnung.xml", xml)])
        try pdf.write(to: pdfURL)
        let pdfInput = try InvoiceValidationInput.capture(at: pdfURL)
        #expect(pdfInput.payload.xml == input.payload.xml)
        #expect(try pdfInput.payload.document().summary == input.payload.document().summary)
        let pdfResult = InvoiceValidationService.validate(input: pdfInput, bundle: bundle)
        #expect(pdfResult.status == .partial)
        #expect(pdfResult.xmlStatus == result.xmlStatus)
        #expect(pdfResult.source?.xmlSHA256 == result.source?.xmlSHA256)
        #expect(pdfResult.source?.fileSHA256 != result.source?.fileSHA256)
        #expect(pdfResult.steps.filter { $0.status == .notChecked }.map(\.id) == ["pdfa", "pdf-embedding"])
        #expect(try Data(contentsOf: pdfURL) == pdf)
    }

    @Test("UBL CreditNote verwendet das eigene XRechnung-Szenario")
    func creditNote() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = try Data(contentsOf: fixtures.appendingPathComponent("ubl.xml"))
        let root = try #require(XMLTools.document(from: xml, path: "Testrechnung").rootElement())
        let name = try #require(root.name)
        let prefix = name.contains(":") ? name.components(separatedBy: ":")[0] + ":" : ""
        let creditNote = String(decoding: xml, as: UTF8.self)
            .replacingOccurrences(of: "<" + name, with: "<" + prefix + "CreditNote")
            .replacingOccurrences(of: "</" + name + ">", with: "</" + prefix + "CreditNote>")
            .replacingOccurrences(of: "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2", with: "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2")
            .replacingOccurrences(of: "InvoiceTypeCode", with: "CreditNoteTypeCode")
            .replacingOccurrences(of: "InvoiceLine", with: "CreditNoteLine")
            .replacingOccurrences(of: "InvoicedQuantity", with: "CreditedQuantity")
            .replacingOccurrences(of: ">380</cbc:CreditNoteTypeCode>", with: ">381</cbc:CreditNoteTypeCode>")
        let url = dir.appendingPathComponent("creditnote.xml")
        try Data(creditNote.utf8).write(to: url)
        let result = InvoiceValidationService.validate(url: url, bundle: bundle)
        #expect([.passed, .passedWithWarnings].contains(result.status))
        #expect(result.scenario == "EN16931 XRechnung (UBL CreditNote)")
    }

    @Test("Erforderliche Regeln, JAR, Runtime und Inventar können nicht still ausgetauscht werden")
    func damagedPackages() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("bundle")
        try FileManager.default.copyItem(at: bundle, to: copy)
        let originalTree = try InvoiceValidationPackage.treeDigest(bundle.appendingPathComponent("configuration"))
        let copiedTree = try InvoiceValidationPackage.treeDigest(copy.appendingPathComponent("configuration"))
        #expect(originalTree == copiedTree, "Kopie: \(copiedTree); Original: \(originalTree)")
        #expect(try InvoiceValidationPackage.inspect(copy) == .xrechnung)
        for relative in ["configuration/resources/xrechnung/3.0.2/xsl/XRechnung-UBL-validation.xsl",
                         "configuration/resources/facturx/MINIMUM/Factur-X_1.09.2_MINIMUM.xsd",
                         "configuration/resources/facturx/MINIMUM/_XSLT_MINIMUM/FACTUR-X_MINIMUM_codedb.xml",
                         "validator.jar", "runtime/Contents/Home/release", "legal/components.lock.json"] {
            let file = copy.appendingPathComponent(relative)
            let original = try Data(contentsOf: file)
            try Data("changed".utf8).write(to: file)
            #expect(throws: (any Error).self) { try InvoiceValidationPackage.inspect(copy) }
            let result = InvoiceValidationService.validate(url: fixtures.appendingPathComponent("ubl.xml"), bundle: copy)
            #expect(result.status == .technicalError)
            #expect(result.xmlStatus == nil)
            try original.write(to: file)
        }
        #expect(try InvoiceValidationPackage.inspect(copy) == .xrechnung)
    }

    @Test("Zeitüberschreitung und Abbruch der echten Prüfung sind eigene Ergebnisse")
    func stoppedValidation() throws {
        let url = fixtures.appendingPathComponent("ubl.xml")
        #expect(InvoiceValidationService.validate(url: url, bundle: bundle, timeout: 0.001).status == .timedOut)
        #expect(InvoiceValidationService.validate(url: url, bundle: bundle, timeout: 0).status == .technicalError)
        let control = ExternalToolRunner.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { control.cancel() }
        let result = InvoiceValidationService.validate(url: url, bundle: bundle, cancellation: control)
        #expect(result.status == .cancelled)
        #expect(result.xmlStatus == nil)
    }

    @Test("CLI hält das alte JSON stabil und ergänzt gemeinsame Status-/Exit-Codes")
    func cliFormats() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Common: Decodable { let validation: InvoiceValidationResult }
        struct Legacy: Decodable { let validation: XRechnungValidationReport }
        let source = fixtures.appendingPathComponent("ubl.xml")
        let original = try Data(contentsOf: source)
        let legacy = try runTagx(arguments: ["validate-xrechnung", source.path, "--bundle", bundle.path, "--json"])
        #expect(legacy.status == 0)
        #expect(try JSONDecoder().decode([Legacy].self, from: Data(legacy.stdout.utf8))[0].validation.status == .passed)
        for (name, xml, exit, expected) in [
            ("valid.xml", original, Int32(0), InvoiceValidationStatus.passed),
            ("broken.xml", Data("<broken>".utf8), 3, .failed),
            ("unknown.xml", Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "xrechnung_3.0", with: "xrechnung_9.9").utf8), 4, .unsupported),
            ("invoice.pdf", InvoiceValidationFixtures.pdf(attachments: [("xrechnung.xml", original)]), 5, .partial),
        ] {
            let file = dir.appendingPathComponent(name)
            try xml.write(to: file)
            let process = try runTagx(arguments: ["validate-xrechnung", file.path, "--bundle", bundle.path, "--format", "common", "--json"])
            #expect(process.status == exit)
            let result = try JSONDecoder().decode([Common].self, from: Data(process.stdout.utf8))[0].validation
            #expect(result.status == expected)
            #expect(result.notice.contains("ohne Gewähr"))
            #expect(result.source?.fileSHA256 == validationDigest(xml))
        }
        let environment = ["JAVA_TOOL_OPTIONS": "--tagx-invalid-option", "JDK_JAVA_OPTIONS": "--tagx-invalid-option",
                           "_JAVA_OPTIONS": "--tagx-invalid-option"]
        let isolated = try runTagx(arguments: ["validate-xrechnung", source.path, "--bundle", bundle.path,
                                               "--format", "common", "--json"], environment: environment)
        #expect(isolated.status == 0)
        let missing = try runTagx(arguments: ["validate-xrechnung", source.path, "--bundle", dir.path, "--format", "common", "--json"])
        #expect(missing.status == 1)
        #expect(try JSONDecoder().decode([Common].self, from: Data(missing.stdout.utf8))[0].validation.status == .technicalError)
    }
}

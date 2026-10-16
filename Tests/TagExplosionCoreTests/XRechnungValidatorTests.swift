import Foundation
@testable import TagExplosionCore
import Testing

@Suite("KoSIT-Berichtsauswertung")
struct XRechnungValidatorTests {
    private func report(scenario: String = "EN16931 XRechnung (UBL Invoice)",
                        steps: String = "", accepted: Bool = true, namespace: String = "http://www.xoev.de/de/validator/varl/1") -> Data {
        Data("""
        <r:report xmlns:r="\(namespace)" xmlns:s="http://www.xoev.de/de/validator/framework/1/scenarios" valid="\(accepted)">
          <r:engine><r:name>KoSIT Validator 1.6.3</r:name></r:engine>
          <r:scenarioMatched><s:scenario><s:name>\(scenario)</s:name></s:scenario>
            \(steps)
          </r:scenarioMatched>
          <r:assessment><r:\(accepted ? "accept" : "reject")/></r:assessment>
        </r:report>
        """.utf8)
    }

    private var completeSteps: String {
        ["val-xml", "val-xsd", "val-sch.1", "val-sch.2"].map {
            "<r:validationStepResult id=\"\($0)\" valid=\"true\"/>"
        }.joined()
    }

    @Test("Erfolg verlangt XRechnung, XML, XSD und beide Schematron-Schritte")
    func completeValidation() throws {
        let result = try XRechnungValidator.parseReport(report(steps: completeSteps), configurationRelease: "2026-08-31")
        #expect(result.status == .passed)
        #expect(result.steps.count == 4)
        #expect(result.notice.contains("zwingende gesetzliche Haftung"))
        #expect(throws: XRechnungValidator.Failure.incompleteReport) {
            try XRechnungValidator.parseReport(report(), configurationRelease: "2026-08-31")
        }
    }

    @Test("Factur-X verlangt seine vollständige Profilprüfung und bestätigt keine XRechnung")
    func facturXReport() throws {
        let steps = ["val-xml", "val-xsd", "val-sch.1"].map {
            "<r:validationStepResult id=\"\($0)\" valid=\"true\"/>"
        }.joined()
        let data = report(scenario: "Factur-X 1.09.2 / ZUGFeRD 2.5.2 (MINIMUM)", steps: steps)
        #expect(try XRechnungValidator.parseReport(data, configurationRelease: "2026-08-04", ruleSet: .facturX).status == .passed)
        #expect(try XRechnungValidator.parseReport(data, configurationRelease: "2026-08-31").status == .unsupported)
        for id in ["val-xml", "val-xsd", "val-sch.1"] {
            let incomplete = Data(String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "<r:validationStepResult id=\"\(id)\" valid=\"true\"/>", with: "").utf8)
            #expect(throws: XRechnungValidator.Failure.incompleteReport) {
                try XRechnungValidator.parseReport(incomplete, configurationRelease: "2026-08-04", ruleSet: .facturX)
            }
        }
    }

    @Test("Reine EN-16931-Prüfung bestätigt keine XRechnung")
    func genericScenario() throws {
        let result = try XRechnungValidator.parseReport(
            report(scenario: "EN16931 (UBL Invoice)", steps: completeSteps), configurationRelease: "2026-08-31")
        #expect(result.status == .unsupported)
    }

    @Test("Warnungen und Informationen bleiben unterscheidbar; Extension ist ein eigenes Profil")
    func warningLevelsAndExtension() throws {
        for (level, expected) in [("warning", InvoiceValidationStatus.passedWithWarnings), ("info", .passed)] {
            let steps = completeSteps + """
            <r:validationStepResult id="extra" valid="true"><r:message level="\(level)" code="TEST">Hinweis</r:message></r:validationStepResult>
            """
            let parsed = try XRechnungValidator.parseReport(report(steps: steps), configurationRelease: "2026-08-31")
            #expect(InvoiceValidationService.xmlStatus(for: parsed) == expected)
            #expect(parsed.issues.first?.severity == level)
        }
        let extensionReport = try XRechnungValidator.parseReport(
            report(scenario: "EN16931 XRechnung Extension (CII)", steps: completeSteps), configurationRelease: "2026-08-31")
        #expect(extensionReport.status == .passed)
        let unknownSeverity = completeSteps + """
        <r:validationStepResult id="extra" valid="true"><r:message level="unrecognized">Hinweis</r:message></r:validationStepResult>
        """
        #expect(throws: XRechnungValidator.Failure.invalidReport) {
            try XRechnungValidator.parseReport(report(steps: unknownSeverity), configurationRelease: "2026-08-31")
        }
    }

    @Test("Regelcode, Schweregrad und Fundstelle stammen nur aus dem eigentlichen Prüfschritt")
    func rejectedInvoice() throws {
        let steps = """
        <r:validationStepResult id="val-sch.2" valid="false">
          <r:message level="error" code="BR-DE-15" xpathLocation="/Invoice/BuyerReference">Käuferreferenz fehlt.</r:message>
        </r:validationStepResult>
        """
        let result = try XRechnungValidator.parseReport(report(steps: steps, accepted: false), configurationRelease: "2026-08-31")
        #expect(result.status == .failed)
        #expect(result.issues.first?.code == "BR-DE-15")
        #expect(result.issues.first?.severity == "error")
        #expect(result.issues.first?.location == "/Invoice/BuyerReference")
    }

    @Test("Fremder Namensraum und widersprüchlicher Erfolgsbericht werden abgelehnt")
    func invalidReports() {
        let variants = [
            report(steps: completeSteps, namespace: "urn:foreign"),
            report(steps: completeSteps.replacingOccurrences(of: "valid=\"true\"", with: "valid=\"false\"")),
            report(steps: completeSteps + "<r:validationStepResult id=\"val-xsd\" valid=\"true\"/>"),
            report(steps: completeSteps + "<r:validationStepResult id=\"extra\" valid=\"false\"/>"),
            Data("<broken".utf8),
        ]
        for data in variants {
            #expect(throws: XRechnungValidator.Failure.invalidReport) {
                try XRechnungValidator.parseReport(data, configurationRelease: "2026-08-31")
            }
        }
    }

    @Test("Kein Szenario und kaputtes XML werden unterschieden")
    func unmatchedReports() throws {
        for xmlValid in [true, false] {
            let data = Data("""
            <report xmlns="http://www.xoev.de/de/validator/varl/1" valid="false">
              <engine><name>KoSIT Validator 1.6.3</name></engine>
              <noScenarioMatched><validationStepResult id="val-xml" valid="\(xmlValid)"/></noScenarioMatched>
              <assessment><reject/></assessment>
            </report>
            """.utf8)
            let result = try XRechnungValidator.parseReport(data, configurationRelease: "2026-08-31")
            #expect(result.status == (xmlValid ? .unsupported : .failed))
        }
    }
}

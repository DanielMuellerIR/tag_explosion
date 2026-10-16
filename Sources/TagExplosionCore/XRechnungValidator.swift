// KoSIT-Ausführung: Original-XML und mitgelieferte Laufzeit bleiben getrennt
// vom Anzeigemodell. Ein fehlender Prüfschritt darf niemals Erfolg bedeuten.
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct XRechnungValidationReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case passed, failed, unsupported
    }

    public struct Step: Codable, Sendable {
        public let id: String
        public let valid: Bool
    }

    public struct Issue: Codable, Sendable {
        public let severity: String
        public let code: String?
        public let location: String?
        public let message: String
    }

    public let status: Status
    public let engine: String
    public let configurationRelease: String
    public let scenario: String?
    public let steps: [Step]
    public let issues: [Issue]
    public let notice: String

    public static let notice = """
        Technische Prüfung ausschließlich gegen das genannte Regelpaket. Keine Zusicherung \
        rechtlicher oder steuerlicher Gültigkeit und keine Garantie der Annahme durch einen \
        Empfänger. Die Software und ihre Prüfergebnisse werden ohne Gewähr für Richtigkeit, \
        Vollständigkeit oder Eignung für einen bestimmten Zweck bereitgestellt. \
        Gewährleistung und Haftung sind nach Maßgabe der MIT-Lizenz im gesetzlich zulässigen \
        Umfang ausgeschlossen; zwingende gesetzliche Haftung bleibt unberührt.
        """
}

public enum XRechnungValidator {
    public enum Failure: Error, LocalizedError {
        case unavailableBundle, inputTooLarge, doctypeNotAllowed, invalidReport, incompleteReport, invalidTimeLimit, pdfNotSupported

        public var errorDescription: String? {
            switch self {
            case .unavailableBundle: "Das KoSIT-Prüfpaket fehlt oder ist unvollständig."
            case .inputTooLarge: "Die Prüfung unterstützt XML-Dateien bis 16 MiB."
            case .doctypeNotAllowed: "XML-Dateien mit DOCTYPE werden nicht geprüft."
            case .invalidReport: "KoSIT lieferte keinen vollständigen, auswertbaren Prüfbericht."
            case .incompleteReport: "KoSIT hat nicht alle erforderlichen Prüfschritte bestätigt."
            case .invalidTimeLimit: "Das Zeitlimit muss eine positive, endliche Zahl sein."
            case .pdfNotSupported: "Für PDF-Anhänge die gemeinsame Ausgabe mit --format common verwenden."
            }
        }
    }

    /// Kein Rückgriff auf System-Java, PATH oder JAVA_HOME. Das Paket ist
    /// explizit angegeben und kann später unverändert im App-Bundle liegen.
    public static func validate(url: URL, bundle: URL,
                                cancellation: ExternalToolRunner.Cancellation? = nil) throws -> XRechnungValidationReport {
        guard url.pathExtension.lowercased() != "pdf" else { throw Failure.pdfNotSupported }
        let input = try InvoiceValidationInput.capture(at: url, cancellation: cancellation)
        let report: XRechnungValidationReport
        do {
            report = try validate(xml: input.payload.xml, bundle: bundle, cancellation: cancellation)
        } catch Failure.incompleteReport {
            throw Failure.invalidReport
        }
        guard input.source.isCurrent(at: url) else { throw InvoiceValidationInput.Failure.changed }
        return report
    }

    static func checkInput(_ data: Data) throws {
        guard data.count <= InvoiceValidationInput.maximumXMLBytes else { throw Failure.inputTooLarge }
        // Konservativer Vorfilter auch für UTF-16/32: Die ASCII-Bytes einer
        // DOCTYPE-Deklaration bleiben nach Entfernen der Nullbytes erkennbar.
        guard Data(data.filter { $0 != 0 }).range(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw Failure.doctypeNotAllowed
        }
    }

    static func validate(xml data: Data, bundle: URL, processTimeout: TimeInterval = 60,
                         cancellation: ExternalToolRunner.Cancellation? = nil) throws -> XRechnungValidationReport {
        try cancellation?.check()
        try checkInput(data)
        guard processTimeout.isFinite, processTimeout > 0 else { throw Failure.invalidTimeLimit }
        let ruleSet = try InvoiceValidationPackage.inspect(bundle, cancellation: cancellation)
        let fm = FileManager.default
        let bundle = bundle.standardizedFileURL
        let java = bundle.appendingPathComponent("runtime/Contents/Home/bin/java")
        let jar = bundle.appendingPathComponent("validator.jar")
        let configuration = bundle.appendingPathComponent("configuration")
        let scenarios = configuration.appendingPathComponent("scenarios.xml")
        let temporary = fm.temporaryDirectory.appendingPathComponent("tagx-kosit-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        // KoSIT erhält einen konsistenten Schnappschuss, schreibt seinen Bericht
        // nie neben die Nutzerdatei und übernimmt keine Dateinamen als Optionen.
        let snapshot = temporary.appendingPathComponent("invoice.xml")
        try data.write(to: snapshot)
        let arguments = [
            "-Xmx512m", "-Djava.awt.headless=true", "-Dfile.encoding=UTF-8", "-Djansi.mode=strip",
            "-Djavax.xml.accessExternalDTD=", "-Djavax.xml.accessExternalSchema=file",
            "-Djavax.xml.accessExternalStylesheet=file",
            "-jar", jar.path, "-s", scenarios.path, "-r", configuration.path,
            "-o", temporary.path, snapshot.path,
        ]
        var processRejected = false
        var environment = ExternalToolRunner.utf8Environment()
        // JVM-Optionen aus der Login-Umgebung dürfen die festgelegten
        // Speicher-/Sicherheitseinstellungen oder den Codepfad nicht ändern.
        for name in ["JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS", "CLASSPATH"] {
            environment.removeValue(forKey: name)
        }
        do {
            _ = try ExternalToolRunner.run(java.path, arguments, processTimeout: processTimeout,
                                           outputLimit: 4 * 1024 * 1024, environment: environment, cancellation: cancellation)
        } catch TagError.toolFailed(_, let exitCode, _) where [1, 2].contains(exitCode) {
            // KoSIT 1.6.3 liefert bei regulärer Zurückweisung Exit 1 oder 2.
            // Ausschlaggebend bleibt der Bericht, nicht der Prozess-Exit allein.
            processRejected = true
        }
        try cancellation?.check()
        let reportURL = temporary.appendingPathComponent("invoice-report.xml")
        guard let reportData = try? InvoiceValidationInput.readBytes(at: reportURL, limit: 16 * 1024 * 1024,
            cancellation: cancellation) else {
            try cancellation?.check()
            throw Failure.invalidReport
        }
        try checkInput(reportData)
        let report = try parseReport(reportData, configurationRelease: ruleSet.configurationRelease)
        guard !processRejected || report.status != .passed else { throw Failure.invalidReport }
        _ = try InvoiceValidationPackage.inspect(bundle, cancellation: cancellation)
        return report
    }

    static func parseReport(_ data: Data, configurationRelease: String) throws -> XRechnungValidationReport {
        let reportNS = "http://www.xoev.de/de/validator/varl/1"
        let scenarioNS = "http://www.xoev.de/de/validator/framework/1/scenarios"
        guard let document = try? XMLTools.document(from: data, path: "KoSIT-Bericht"),
              let root = document.rootElement(), XMLTools.localName(root) == "report",
              XMLTools.namespace(of: root) == reportNS,
              let engineNode = XMLTools.firstElement(named: "engine", in: root),
              XMLTools.text(of: "name", in: engineNode) == "KoSIT Validator 1.6.3",
              let assessment = XMLTools.firstElement(named: "assessment", in: root) else {
            throw Failure.invalidReport
        }
        let matched = XMLTools.firstElement(named: "scenarioMatched", in: root)
        let unmatched = XMLTools.firstElement(named: "noScenarioMatched", in: root)
        guard (matched != nil) != (unmatched != nil) else { throw Failure.invalidReport }
        let container = matched ?? unmatched!
        let scenarioNode = XMLTools.firstElement(named: "scenario", in: matched, namespaceURI: scenarioNS)
        let scenario = scenarioNode.map { XMLTools.text(of: "name", in: $0) }
        let stepNodes = XMLTools.elements(named: "validationStepResult", in: container)
        var steps: [XRechnungValidationReport.Step] = []
        var issues: [XRechnungValidationReport.Issue] = []
        for step in stepNodes {
            guard let id = XMLTools.attribute(step, "id"),
                  let validity = XMLTools.attribute(step, "valid"), ["true", "false"].contains(validity) else {
                throw Failure.invalidReport
            }
            steps.append(.init(id: id, valid: validity == "true"))
            for message in XMLTools.elements(named: "message", in: step) {
                issues.append(.init(severity: XMLTools.attribute(message, "level") ?? "error",
                                    code: XMLTools.attribute(message, "code"),
                                    location: XMLTools.attribute(message, "xpathLocation"),
                                    message: (message.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        guard Set(steps.map(\.id)).count == steps.count else { throw Failure.invalidReport }
        guard issues.allSatisfy({ ["error", "fatal", "warning", "info", "information"].contains($0.severity) }) else {
            throw Failure.invalidReport
        }
        let accepted = XMLTools.firstElement(named: "accept", in: assessment) != nil
        let rejected = XMLTools.firstElement(named: "reject", in: assessment) != nil
        guard accepted != rejected else { throw Failure.invalidReport }

        let status: XRechnungValidationReport.Status
        if steps.contains(where: { $0.id == "val-xml" && !$0.valid }) {
            guard rejected else { throw Failure.invalidReport }
            status = .failed
        } else if !supportedScenarios.contains(scenario ?? "") {
            status = .unsupported
        } else if accepted {
            let required = ["val-xml", "val-xsd", "val-sch.1", "val-sch.2"]
            guard XMLTools.attribute(root, "valid") == "true",
                  steps.allSatisfy(\.valid),
                  !issues.contains(where: { ["error", "fatal"].contains($0.severity) }) else {
                throw Failure.invalidReport
            }
            guard required.allSatisfy({ id in steps.contains { $0.id == id && $0.valid } }) else {
                throw Failure.incompleteReport
            }
            status = .passed
        } else {
            guard XMLTools.attribute(root, "valid") == "false", steps.contains(where: { !$0.valid }) else {
                throw Failure.invalidReport
            }
            status = .failed
        }
        return .init(status: status, engine: XMLTools.text(of: "name", in: engineNode),
                     configurationRelease: configurationRelease, scenario: scenario,
                     steps: steps, issues: issues, notice: XRechnungValidationReport.notice)
    }

    private static let supportedScenarios = Set(InvoiceValidationRuleSet.xrechnung.profiles.map(\.scenario))
}

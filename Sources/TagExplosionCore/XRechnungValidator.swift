// KoSIT-Prototyp: Original-XML und mitgelieferte Laufzeit bleiben getrennt
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
        case unavailableBundle, inputTooLarge, doctypeNotAllowed, invalidReport

        public var errorDescription: String? {
            switch self {
            case .unavailableBundle: "Das KoSIT-Prüfpaket fehlt oder ist unvollständig."
            case .inputTooLarge: "Der Prototyp prüft XML-Dateien bis 16 MiB."
            case .doctypeNotAllowed: "Der Prototyp prüft keine XML-Dateien mit DOCTYPE."
            case .invalidReport: "KoSIT lieferte keinen vollständigen, auswertbaren Prüfbericht."
            }
        }
    }

    private struct Manifest: Decodable {
        let validatorVersion: String
        let configurationRelease: String
    }

    /// Kein Rückgriff auf System-Java, PATH oder JAVA_HOME. Das Paket ist
    /// explizit angegeben und kann später unverändert im App-Bundle liegen.
    public static func validate(url: URL, bundle: URL,
                                cancellation: ExternalToolRunner.Cancellation? = nil) throws -> XRechnungValidationReport {
        let fm = FileManager.default
        let bundle = bundle.standardizedFileURL
        let java = bundle.appendingPathComponent("runtime/Contents/Home/bin/java")
        let jar = bundle.appendingPathComponent("validator.jar")
        let configuration = bundle.appendingPathComponent("configuration")
        let scenarios = configuration.appendingPathComponent("scenarios.xml")
        guard fm.isExecutableFile(atPath: java.path), fm.fileExists(atPath: jar.path),
              fm.fileExists(atPath: scenarios.path),
              let manifestData = try? Data(contentsOf: bundle.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              manifest.validatorVersion == "1.6.3", manifest.configurationRelease == "2026-08-31" else {
            throw Failure.unavailableBundle
        }

        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let limit = 16 * 1024 * 1024
        let data = try input.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw Failure.inputTooLarge }
        // Konservativer Vorfilter auch für UTF-16/32: Die ASCII-Bytes einer
        // DOCTYPE-Deklaration bleiben nach Entfernen der Nullbytes erkennbar.
        guard Data(data.filter { $0 != 0 }).range(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw Failure.doctypeNotAllowed
        }
        try cancellation?.check()

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
        do {
            _ = try ExternalToolRunner.run(java.path, arguments, processTimeout: 60, cancellation: cancellation)
        } catch TagError.toolFailed(_, let exitCode, _) where [1, 2].contains(exitCode) {
            // KoSIT 1.6.3 liefert bei regulärer Zurückweisung Exit 1 oder 2.
            // Ausschlaggebend bleibt der Bericht, nicht der Prozess-Exit allein.
            processRejected = true
        }
        try cancellation?.check()
        let reportURL = temporary.appendingPathComponent("invoice-report.xml")
        guard let reportData = try? Data(contentsOf: reportURL) else { throw Failure.invalidReport }
        let report = try parseReport(reportData, configurationRelease: manifest.configurationRelease)
        guard !processRejected || report.status != .passed else { throw Failure.invalidReport }
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
        let accepted = XMLTools.firstElement(named: "accept", in: assessment) != nil
        let rejected = XMLTools.firstElement(named: "reject", in: assessment) != nil
        guard accepted != rejected else { throw Failure.invalidReport }

        let status: XRechnungValidationReport.Status
        if steps.contains(where: { $0.id == "val-xml" && !$0.valid }) {
            guard rejected else { throw Failure.invalidReport }
            status = .failed
        } else if scenario?.hasPrefix("EN16931 XRechnung ") != true {
            status = .unsupported
        } else if accepted {
            let required = ["val-xml", "val-xsd", "val-sch.1", "val-sch.2"]
            guard XMLTools.attribute(root, "valid") == "true",
                  required.allSatisfy({ id in steps.contains { $0.id == id && $0.valid } }),
                  steps.allSatisfy(\.valid),
                  !issues.contains(where: { ["error", "fatal"].contains($0.severity) }) else {
                throw Failure.invalidReport
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
}

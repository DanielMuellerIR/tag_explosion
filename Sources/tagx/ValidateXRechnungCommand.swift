import ArgumentParser
import Foundation
import TagExplosionCore

struct ValidateXRechnung: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-xrechnung",
        abstract: "Prototype: validate XRechnung XML locally with a private KoSIT/Java bundle.",
        discussion: """
            XML only. No system Java or network service is used. Exit 0: passed the bundled rules;
            3: failed; 4: unsupported profile; 1: tool/report error. No warranty of results.
            """
    )

    @Argument(help: "XRechnung XML file(s)") var files: [String]
    @Option(name: .long, help: "Prepared KoSIT bundle (scripts/prepare-xrechnung-validator.py)")
    var bundle: String
    @Flag(name: .long, help: "Output reports as JSON") var json = false

    func run() throws {
        guard !files.isEmpty else { throw ValidationError("Provide at least one XML file.") }
        struct Report: Encodable {
            let file: String
            let validation: XRechnungValidationReport
        }
        var reports: [Report] = []
        for file in files {
            let url = try resolveFile(file)
            let validation = try XRechnungValidator.validate(url: url, bundle: URL(fileURLWithPath: bundle))
            reports.append(.init(file: url.path, validation: validation))
        }
        if json {
            try printJSON(reports)
        } else {
            for report in reports {
                let result = report.validation
                print("FILE: \(report.file)")
                print("STATUS: \(result.status.rawValue)")
                print("ENGINE: \(result.engine)")
                print("CONFIGURATION: \(result.configurationRelease)")
                print("SCENARIO: \(result.scenario ?? "Kein unterstütztes XRechnung-Szenario")")
                for step in result.steps { print("STEP [\(step.id)]: \(step.valid ? "passed" : "failed")") }
                for issue in result.issues {
                    print("\(issue.severity.uppercased()) [\(issue.code ?? "XML")]: \(issue.message)")
                    if let location = issue.location { print("  \(location)") }
                }
                print("NOTICE: \(result.notice)")
            }
        }
        if reports.contains(where: { $0.validation.status == .failed }) { throw ExitCode(3) }
        if reports.contains(where: { $0.validation.status == .unsupported }) { throw ExitCode(4) }
    }
}

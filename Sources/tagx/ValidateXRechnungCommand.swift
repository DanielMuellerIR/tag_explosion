import ArgumentParser
import Foundation
import TagExplosionCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ValidateXRechnung: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate-xrechnung",
        abstract: "Validate XRechnung locally with a private KoSIT/Java bundle.",
        discussion: """
            Default format preserves the XML prototype output. --format common adds versioned
            source-bound results and PDF attachment input, including current Factur-X profiles. No system Java or network service is used.
            Exit 0: XML passed; 3: failed; 4: unsupported; 5: partial; 6: stale input;
            124: timeout; 130: cancelled; 1: tool/report error. No warranty of results.
            """
    )

    @Argument(help: "XRechnung XML file(s); PDF attachments with --format common") var files: [String]
    @Option(name: .long, help: "Prepared KoSIT bundle (scripts/prepare-xrechnung-validator.py)")
    var bundle: String
    @Flag(name: .long, help: "Output reports as JSON") var json = false
    enum Format: String, ExpressibleByArgument { case legacy, common }
    @Option(name: .long, help: "Result format: legacy (compatible XML output) or common (XML/PDF)")
    var format: Format = .legacy

    func run() throws {
        guard !files.isEmpty else { throw ValidationError("Provide at least one invoice file.") }
        let control = ExternalToolRunner.Cancellation()
        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousTermination = signal(SIGTERM, SIG_IGN)
        let signalQueue = DispatchQueue(label: "io.github.tagexplosion.invoice-cli-signals")
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
            source.setEventHandler { control.cancel() }
            source.resume()
            return source
        }
        defer {
            signals.forEach { $0.cancel() }
            signal(SIGINT, previousInterrupt)
            signal(SIGTERM, previousTermination)
        }
        if format == .common {
            try runCommon(cancellation: control)
            return
        }
        struct Report: Encodable {
            let file: String
            let validation: XRechnungValidationReport
        }
        var reports: [Report] = []
        for file in files {
            let url = try resolveFile(file)
            let validation: XRechnungValidationReport
            do {
                validation = try XRechnungValidator.validate(url: url, bundle: URL(fileURLWithPath: bundle), cancellation: control)
            } catch is CancellationError { throw ExitCode(130) }
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

    private func runCommon(cancellation: ExternalToolRunner.Cancellation) throws {
        struct Report: Encodable {
            let file: String
            let validation: InvoiceValidationResult
        }
        let reports = try files.map { file in
            let url = try resolveFile(file)
            return Report(file: url.path, validation: InvoiceValidationService.validate(
                url: url, bundle: URL(fileURLWithPath: bundle), cancellation: cancellation))
        }
        if json {
            try printJSON(reports)
        } else {
            for report in reports {
                let result = report.validation
                print("FILE: \(report.file)")
                print("STATUS: \(result.status.rawValue)")
                if let xmlStatus = result.xmlStatus { print("XML STATUS: \(xmlStatus.rawValue)") }
                if let ruleSet = result.ruleSet {
                    print("RULESET: \(ruleSet.id) · \(ruleSet.engine)")
                }
                if let source = result.source { print("XML SHA256: \(source.xmlSHA256)") }
                for step in result.steps { print("STEP [\(step.id)]: \(step.status.rawValue)") }
                for issue in result.issues {
                    print("\(issue.severity.rawValue.uppercased()) [\(issue.code ?? "XML")]: \(issue.message)")
                    if let location = issue.location { print("  \(location)") }
                }
                print("NOTICE: \(result.notice)")
            }
        }
        let statuses = Swift.Set(reports.map(\.validation.status))
        for (status, code): (InvoiceValidationStatus, Int32) in [
            (.technicalError, 1), (.timedOut, 124), (.cancelled, 130), (.stale, 6),
            (.failed, 3), (.unsupported, 4), (.partial, 5),
        ] where statuses.contains(status) { throw ExitCode(code) }
    }
}

struct ValidateInvoice: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-invoice",
        abstract: "Validate XRechnung and current ZUGFeRD/Factur-X XML or PDF locally.")
    @Argument(help: "Invoice XML or PDF file(s)") var files: [String]
    @Option(name: .long, help: "Prepared KoSIT bundle") var bundle: String
    @Flag(name: .long, help: "Output reports as JSON") var json = false

    func run() throws {
        var command = ValidateXRechnung()
        command.files = files
        command.bundle = bundle
        command.json = json
        command.format = .common
        try command.run()
    }
}

import EInvoiceCore
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum InvoiceValidationStatus: String, Codable, Sendable {
    case passed, passedWithWarnings, failed, unsupported, partial
    case cancelled, timedOut, technicalError, stale
}

public struct InvoiceValidationProfile: Codable, Sendable {
    public let syntax: EInvoiceSyntax?
    public let guidelineID: String?
}

public struct InvoiceValidationResult: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public enum Status: String, Codable, Sendable { case passed, failed, notChecked }
        public let id: String
        public let status: Status
    }

    public struct Issue: Codable, Sendable {
        public enum Severity: String, Codable, Sendable { case error, warning, information }
        public let severity: Severity
        public let code: String?
        public let location: String?
        public let message: String
    }

    public let schemaVersion: Int
    public let id: UUID
    public let checkedAt: String
    public let status: InvoiceValidationStatus
    public let xmlStatus: InvoiceValidationStatus?
    public let source: InvoiceValidationSource?
    public let profile: InvoiceValidationProfile?
    public let ruleSet: InvoiceValidationRuleSet?
    public let scenario: String?
    public let steps: [Step]
    public let issues: [Issue]
    public let notice: String

    public func isCurrent(at url: URL) -> Bool { source?.isCurrent(at: url) == true }

    func cancelled() -> Self {
        .init(schemaVersion: schemaVersion, id: id, checkedAt: checkedAt, status: .cancelled, xmlStatus: nil,
              source: source, profile: profile, ruleSet: ruleSet, scenario: scenario, steps: [],
              issues: [.init(severity: .information, code: "CANCELLED", location: nil,
                             message: "Die Prüfung wurde abgebrochen.")], notice: notice)
    }

    func stale() -> Self {
        .init(schemaVersion: schemaVersion, id: id, checkedAt: checkedAt, status: .stale, xmlStatus: nil,
              source: source, profile: profile, ruleSet: ruleSet, scenario: scenario, steps: [],
              issues: [.init(severity: .error, code: "SOURCE_CHANGED", location: nil,
                             message: "Die Datei wurde seit dem Einlesen verändert. Bitte erneut prüfen.")], notice: notice)
    }
}

/// Synchroner, UI-freier Dienst; die Session darunter führt ihn im Hintergrund
/// aus. Die CLI nutzt exakt denselben Dienst für die gemeinsame JSON-Ausgabe.
public enum InvoiceValidationService {
    public static func validate(url: URL, bundle: URL, timeout: TimeInterval = 60,
                                cancellation: ExternalToolRunner.Cancellation? = nil) -> InvoiceValidationResult {
        do {
            try cancellation?.check()
            if url.pathExtension.lowercased() == "pdf", !EInvoiceReader.isPDFExtractionAvailable {
                return result(.unsupported, input: nil, profile: nil, issues: [
                    .init(severity: .information, code: "PDF_EXTRACTION_UNAVAILABLE", location: nil,
                          message: "Die PDF-Extraktion steht auf dieser Plattform nicht zur Verfügung."),
                ])
            }
            let input = try InvoiceValidationInput.capture(at: url, cancellation: cancellation)
            return validate(input: input, bundle: bundle, timeout: timeout, cancellation: cancellation)
        } catch {
            return failure(error, input: nil, profile: nil)
        }
    }

    public static func validate(input: InvoiceValidationInput, bundle: URL, timeout: TimeInterval = 60,
                                cancellation: ExternalToolRunner.Cancellation? = nil) -> InvoiceValidationResult {
        var profile: InvoiceValidationProfile?
        do {
            try cancellation?.check()
            guard input.source.isCurrent(at: input.source.url) else { throw InvoiceValidationInput.Failure.changed }
            try XRechnungValidator.checkInput(input.payload.xml)
            do {
                profile = try detectProfile(input.payload.xml)
            } catch {
                try cancellation?.check()
                return result(.failed, input: input, profile: nil,
                    steps: [.init(id: "val-xml", status: .failed)],
                    issues: [.init(severity: .error, code: "XML_NOT_WELL_FORMED", location: nil,
                                   message: "Die XML-Datei ist nicht wohlgeformt.")])
            }
            try cancellation?.check()
            guard let profile, let scenario = expectedScenario(for: profile) else {
                return result(.unsupported, input: input, profile: profile,
                    issues: [.init(severity: .information, code: "PROFILE_UNSUPPORTED", location: nil,
                                   message: "Für diese Syntax und Spezifikationskennung ist kein freigegebenes Regelpaket vorhanden.")])
            }
            let report = try XRechnungValidator.validate(xml: input.payload.xml, bundle: bundle,
                processTimeout: timeout, cancellation: cancellation)
            try cancellation?.check()
            guard input.source.isCurrent(at: input.source.url) else { throw InvoiceValidationInput.Failure.changed }
            guard report.scenario == scenario else { throw XRechnungValidator.Failure.invalidReport }
            let xmlStatus = xmlStatus(for: report)
            let embedded: Bool = if case .pdfEmbedded = input.payload.source { true } else { false }
            let status: InvoiceValidationStatus = embedded && [.passed, .passedWithWarnings].contains(xmlStatus) ? .partial : xmlStatus
            var steps = report.steps.map { InvoiceValidationResult.Step(id: $0.id, status: $0.valid ? .passed : .failed) }
            var issues = report.issues.map { issue in
                InvoiceValidationResult.Issue(severity: severity(issue.severity), code: issue.code,
                    location: issue.location, message: issue.message)
            }
            if embedded {
                steps += [.init(id: "pdfa", status: .notChecked), .init(id: "pdf-embedding", status: .notChecked)]
                issues.append(.init(severity: .information, code: "PDF_NOT_CHECKED", location: nil,
                    message: "Geprüft wurde ausschließlich das eingebettete XML. PDF/A, Einbettung und Übereinstimmung mit dem sichtbaren PDF sind nicht geprüft."))
            }
            return result(status, input: input, profile: profile, ruleSet: .xrechnung,
                          xmlStatus: xmlStatus, scenario: report.scenario, steps: steps, issues: issues)
        } catch {
            return failure(error, input: input, profile: profile)
        }
    }

    static func expectedScenario(for profile: InvoiceValidationProfile) -> String? {
        InvoiceValidationRuleSet.xrechnung.profiles.first {
            $0.guidelineID == profile.guidelineID && $0.syntax == profile.syntax
        }?.scenario
    }

    static func xmlStatus(for report: XRechnungValidationReport) -> InvoiceValidationStatus {
        switch report.status {
        case .passed: report.issues.contains { $0.severity == "warning" } ? .passedWithWarnings : .passed
        case .failed: .failed
        case .unsupported: .unsupported
        }
    }

    static func detectProfile(_ data: Data) throws -> InvoiceValidationProfile {
        let document = try XMLTools.document(from: data, path: "Rechnungs-XML")
        guard let root = document.rootElement() else { throw XRechnungValidator.Failure.invalidReport }
        let syntax: EInvoiceSyntax?
        let identifiers: [XMLElement]
        let cbc = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
        switch (XMLTools.localName(root), XMLTools.namespace(of: root)) {
        case ("Invoice", "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"):
            syntax = .ublInvoice
            identifiers = XMLTools.elements(named: "CustomizationID", in: root, namespaceURI: cbc)
        case ("CreditNote", "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"):
            syntax = .ublCreditNote
            identifiers = XMLTools.elements(named: "CustomizationID", in: root, namespaceURI: cbc)
        case ("CrossIndustryInvoice", "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"):
            syntax = .cii
            let ram = "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
            identifiers = XMLTools.elements(named: "ExchangedDocumentContext", in: root).flatMap {
                XMLTools.elements(named: "GuidelineSpecifiedDocumentContextParameter", in: $0, namespaceURI: ram)
            }.flatMap { XMLTools.elements(named: "ID", in: $0, namespaceURI: ram) }
        default:
            syntax = nil
            identifiers = []
        }
        // KoSIT vergleicht BT-24 wortgetreu. Unbekannte Versionssuffixe,
        // fremde Namensräume und mehrere Kennungen werden nicht geraten.
        return .init(syntax: syntax, guidelineID: identifiers.count == 1 ? identifiers[0].stringValue : nil)
    }

    private static func severity(_ value: String) -> InvoiceValidationResult.Issue.Severity {
        switch value {
        case "warning": .warning
        case "info", "information": .information
        default: .error
        }
    }

    private static func failure(_ error: any Error, input: InvoiceValidationInput?,
                                profile: InvoiceValidationProfile?) -> InvoiceValidationResult {
        let status: InvoiceValidationStatus
        let code: String
        switch error {
        case is CancellationError: (status, code) = (.cancelled, "CANCELLED")
        case ExternalToolRunner.ProcessTimeoutError.exceeded: (status, code) = (.timedOut, "TIMEOUT")
        case InvoiceValidationInput.Failure.changed, TagError.fileChangedOnDisk:
            (status, code) = (.stale, "SOURCE_CHANGED")
        case XRechnungValidator.Failure.incompleteReport: (status, code) = (.partial, "VALIDATION_INCOMPLETE")
        case EInvoiceError.notAnInvoice: (status, code) = (.unsupported, "NO_EMBEDDED_INVOICE")
        default: (status, code) = (.technicalError, "VALIDATION_ERROR")
        }
        let message = switch status {
        case .cancelled: "Die Prüfung wurde abgebrochen."
        case .timedOut: "Die Prüfung hat das Zeitlimit überschritten. Es liegt kein vollständiges Prüfergebnis vor."
        default: error.localizedDescription
        }
        return result(status, input: input, profile: profile,
            issues: [.init(severity: status == .cancelled ? .information : .error, code: code, location: nil,
                           message: message)])
    }

    private static func result(_ status: InvoiceValidationStatus, input: InvoiceValidationInput?,
                               profile: InvoiceValidationProfile?, ruleSet: InvoiceValidationRuleSet? = nil,
                               xmlStatus: InvoiceValidationStatus? = nil, scenario: String? = nil,
                               steps: [InvoiceValidationResult.Step] = [],
                               issues: [InvoiceValidationResult.Issue] = []) -> InvoiceValidationResult {
        let needsSourceCheck = [.passed, .passedWithWarnings, .partial, .failed, .unsupported].contains(status)
        let stale = needsSourceCheck && (input.map { !$0.source.isCurrent(at: $0.source.url) } ?? false)
        let status: InvoiceValidationStatus = stale ? .stale : status
        let issues = status == .stale && !issues.contains(where: { $0.code == "SOURCE_CHANGED" })
            ? issues + [.init(severity: .error, code: "SOURCE_CHANGED", location: nil,
                              message: "Die Datei wurde seit dem Einlesen verändert. Bitte erneut prüfen.")]
            : issues
        return .init(schemaVersion: 1, id: UUID(), checkedAt: ISO8601DateFormatter().string(from: Date()),
              status: status, xmlStatus: status == .stale ? nil : xmlStatus, source: input?.source, profile: profile, ruleSet: ruleSet,
              scenario: scenario, steps: status == .stale ? [] : steps, issues: issues, notice: XRechnungValidationReport.notice)
    }
}

/// Eine Instanz pro Rechnungsansicht. Auswahlwechsel invalidieren auch einen
/// schon fast fertigen Auftrag; dessen Rückgabe ist dann nil.
public actor InvoiceValidationSession {
    public enum State: Sendable {
        case idle
        case running(id: UUID)
        case finished(InvoiceValidationResult)
    }

    public private(set) var state: State = .idle
    private var revision = UUID()
    private var cancellation: ExternalToolRunner.Cancellation?
    private var cancelRequested = false
    private let operation: @Sendable (URL, URL, TimeInterval, ExternalToolRunner.Cancellation) -> InvoiceValidationResult

    public init() {
        operation = { url, bundle, timeout, control in
            InvoiceValidationService.validate(url: url, bundle: bundle, timeout: timeout, cancellation: control)
        }
    }

    init(operation: @escaping @Sendable (URL, URL, TimeInterval, ExternalToolRunner.Cancellation) -> InvoiceValidationResult) {
        self.operation = operation
    }

    public func invalidate() {
        cancellation?.cancel()
        cancellation = nil
        cancelRequested = false
        revision = UUID()
        state = .idle
    }

    public func cancel() {
        guard let cancellation else { return }
        cancelRequested = true
        cancellation.cancel()
    }

    public func validate(url: URL, bundle: URL, timeout: TimeInterval = 60) async -> InvoiceValidationResult? {
        let operation = operation
        return await perform { operation(url, bundle, timeout, $0) }
    }

    public func validate(input: InvoiceValidationInput, bundle: URL, timeout: TimeInterval = 60) async -> InvoiceValidationResult? {
        await perform { InvoiceValidationService.validate(input: input, bundle: bundle, timeout: timeout, cancellation: $0) }
    }

    private func perform(_ operation: @escaping @Sendable (ExternalToolRunner.Cancellation) -> InvoiceValidationResult) async -> InvoiceValidationResult? {
        invalidate()
        let id = revision
        let control = ExternalToolRunner.Cancellation()
        cancellation = control
        state = .running(id: id)
        var result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                operation(control)
            }.value
        } onCancel: { control.cancel() }
        guard revision == id else { return nil }
        if cancelRequested || Task.isCancelled { result = result.cancelled() }
        else if [.passed, .passedWithWarnings, .failed, .partial, .unsupported].contains(result.status),
                let source = result.source, !source.isCurrent(at: source.url) {
            result = result.stale()
        }
        cancellation = nil
        state = .finished(result)
        return result
    }
}

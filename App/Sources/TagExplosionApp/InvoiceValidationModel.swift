import AppKit
import EInvoiceCore
import Observation
import TagExplosionCore

@MainActor @Observable
final class InvoiceValidationModel {
    static var hasActiveJobs: Bool { !InvoiceValidationJobs.pending.isEmpty }

    static func finishAllJobs(terminating: Bool = true) async {
        InvoiceValidationJobs.shuttingDown = terminating
        while !InvoiceValidationJobs.pending.isEmpty {
            let jobs = Array(InvoiceValidationJobs.pending.values)
            for job in jobs { job.cancel() }
            for job in jobs { await job.wait() }
        }
    }
    private(set) var isRunning = false
    private(set) var isCancelling = false
    private(set) var status: InvoiceValidationStatus?
    private(set) var result: InvoiceValidationResult?
    private(set) var document: EInvoiceDocument?
    private(set) var hasFreshDocument = false
    private(set) var error: String?
    private(set) var url: URL?
    private let bundle: URL
    private var revision = UUID()
    private var task: Task<Void, Never>?
    private var inputCancellation: ExternalToolRunner.Cancellation?
    private var session = InvoiceValidationSession()
    private var watcher: DispatchSourceFileSystemObject?

    init(bundle: URL? = nil, initialResult: InvoiceValidationResult? = nil) {
        self.bundle = bundle ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("XRechnungValidator")
        if let initialResult {
            result = initialResult
            status = initialResult.status
            url = initialResult.source?.url
            document = initialResult.source.flatMap { try? EInvoiceReader.read(url: $0.url) }
            hasFreshDocument = document != nil
        }
    }

    func observe(_ url: URL) {
        if self.url != url {
            watcher?.cancel()
            watcher = nil
            reset()
            self.url = url
        }
        guard watcher == nil else { return }
        watcher = InvoiceFileObservation.watch(url) { [weak self] in
            Task { @MainActor in
                guard let self, self.url == url else { return }
                self.reset(stale: self.isRunning || self.status != nil || self.result != nil)
                self.watcher?.cancel()
                self.watcher = nil
                self.observe(url)
            }
        }
    }

    func checkSource() {
        if let source = result?.source, FileStamp.current(of: source.url) != source.stamp {
            reset(stale: true)
        }
        if let url { observe(url) }
    }

    func reset(stale: Bool = false) {
        revision = UUID()
        task?.cancel()
        task = nil
        inputCancellation?.cancel()
        inputCancellation = nil
        let previous = session
        session = InvoiceValidationSession()
        Task { await previous.invalidate() }
        isRunning = false
        isCancelling = false
        result = nil
        status = stale ? .stale : nil
        error = nil
        document = nil
        hasFreshDocument = false
    }

    func stopObserving() {
        reset()
        watcher?.cancel()
        watcher = nil
        url = nil
    }

    func start() {
        guard let url, !InvoiceValidationJobs.shuttingDown else { return }
        reset()
        isRunning = true
        let id = revision
        let control = ExternalToolRunner.Cancellation()
        inputCancellation = control
        let session = session
        let bundle = bundle
        task = Task { [weak self] in
            defer { InvoiceValidationJobs.pending.removeValue(forKey: id) }
            let captured = await Task.detached(priority: .userInitiated) {
                Result { try InvoiceValidationInput.capture(at: url, cancellation: control) }
            }.value
            guard let self, self.revision == id else { return }
            switch captured {
            case .failure(let failure):
                self.status = failure is CancellationError ? .cancelled : .technicalError
                self.error = failure is CancellationError ? nil : failure.localizedDescription
            case .success(let input):
                let document = await Task.detached(priority: .utility) { try? input.payload.document() }.value
                guard self.revision == id else { return }
                self.document = document
                self.hasFreshDocument = true
                let result = await session.validate(input: input, bundle: bundle)
                guard self.revision == id, let result else { return }
                self.result = result
                self.status = result.status
            }
            self.isRunning = false
            self.isCancelling = false
            self.inputCancellation = nil
            self.task = nil
        }
        if let task {
            InvoiceValidationJobs.pending[id] = .init(cancel: { control.cancel(); task.cancel() }, wait: { await task.value })
        }
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        inputCancellation?.cancel()
        task?.cancel()
    }

    func currentReport() async -> String? {
        if let result, let source = result.source {
            let current = await Task.detached(priority: .utility) { source.isCurrent(at: source.url) }.value
            guard current, self.result?.id == result.id else { reset(stale: true); return nil }
        }
        guard !isRunning, status != nil else { return nil }
        return InvoiceValidationPresentation.report(result: result, status: status, error: error, url: url, document: document)
    }

    enum ExportFailure: Error, LocalizedError {
        case sourceFile, outdated
        var errorDescription: String? {
            switch self {
            case .sourceFile: String(localized: "Der Prüfbericht darf die Rechnungsdatei nicht überschreiben. Bitte ein anderes Ziel wählen.")
            case .outdated: String(localized: "Das Prüfergebnis ist nicht mehr aktuell. Bitte erneut prüfen.")
            }
        }
    }

    func saveReport(to destination: URL) async throws {
        let id = revision
        guard !InvoiceValidationJobs.shuttingDown, let source = url else { throw ExportFailure.outdated }
        let exportID = UUID()
        let writer = Task<Result<Void, Error>, Never> {
            defer { InvoiceValidationJobs.pending.removeValue(forKey: exportID) }
            guard let report = await currentReport(), revision == id else { return .failure(ExportFailure.outdated) }
            let bytes = Data(report.utf8)
            return await Task.detached(priority: .userInitiated) {
                Result {
                    let target = MediaFormats.canonicalFileURL(destination)
                    let original = MediaFormats.canonicalFileURL(source)
                    let originalStamp = FileStamp.current(of: original)
                    guard target != original,
                          originalStamp.map({ stamp in FileStamp.current(of: target).map { !stamp.hasSameFileIdentity(as: $0) } ?? true }) ?? true
                    else { throw ExportFailure.sourceFile }
                    try FileExport.write(bytes, to: target)
                }
            }.value
        }
        // Bereits die erneute Quellenprüfung gehört zum bestätigten Export.
        // App-Ende wartet darauf; Prüfvorgänge werden dagegen abgebrochen.
        InvoiceValidationJobs.pending[exportID] = .init(cancel: {}, wait: { _ = await writer.value })
        try await writer.value.get()
    }
}

@MainActor private enum InvoiceValidationJobs {
    struct Job {
        let cancel: () -> Void
        let wait: () async -> Void
    }
    static var pending: [UUID: Job] = [:]
    static var shuttingDown = false
}

private enum InvoiceFileObservation {
    // GCD-Handler außerhalb des Main Actors erzeugen; Swift 6 würde sonst
    // dessen Isolation erben und auf der Hintergrundqueue absichtlich trapen.
    nonisolated static func watch(_ url: URL, onChange: @escaping @Sendable () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .global(qos: .utility))
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler(handler: onChange)
        source.resume()
        return source
    }
}

enum InvoiceValidationPresentation {
    struct DisplayedStep: Identifiable {
        let id: String
        let status: InvoiceValidationResult.Step.Status
    }

    static func steps(_ result: InvoiceValidationResult) -> [DisplayedStep] {
        var ids = result.ruleSet?.requiredSteps ?? []
        for step in result.steps where !ids.contains(step.id) { ids.append(step.id) }
        return ids.map { id in .init(id: id, status: result.steps.first { $0.id == id }?.status ?? .notChecked) }
    }

    static func stepStatus(_ status: InvoiceValidationResult.Step.Status) -> String {
        switch status {
        case .passed: String(localized: "Bestanden")
        case .failed: String(localized: "Fehlgeschlagen")
        case .notChecked: String(localized: "Nicht geprüft")
        }
    }
    static func title(_ status: InvoiceValidationStatus?) -> String {
        switch status {
        case .passed: String(localized: "XML-Prüfung bestanden")
        case .passedWithWarnings: String(localized: "XML-Prüfung bestanden · Warnungen")
        case .failed: String(localized: "Prüfung fehlgeschlagen")
        case .unsupported: String(localized: "Profil nicht unterstützt")
        case .partial: String(localized: "Teilweise geprüft")
        case .cancelled: String(localized: "Prüfung abgebrochen")
        case .timedOut: String(localized: "Zeitlimit überschritten")
        case .technicalError: String(localized: "Technischer Prüffehler")
        case .stale: String(localized: "Datei verändert · erneut prüfen")
        case nil: String(localized: "Noch nicht geprüft")
        }
    }

    static var shortNotice: String {
        String(localized: "Technische Prüfung ohne Gewähr. Keine Zusicherung rechtlicher oder steuerlicher Gültigkeit.")
    }

    static var notice: String {
        String(localized: "Technische Prüfung ausschließlich gegen das genannte Regelpaket. Keine Zusicherung rechtlicher oder steuerlicher Gültigkeit und keine Garantie der Annahme durch einen Empfänger. Die Software und ihre Prüfergebnisse werden ohne Gewähr für Richtigkeit, Vollständigkeit oder Eignung für einen bestimmten Zweck bereitgestellt. Gewährleistung und Haftung sind nach Maßgabe der MIT-Lizenz im gesetzlich zulässigen Umfang ausgeschlossen; zwingende gesetzliche Haftung bleibt unberührt.")
    }

    static var standardNotice: String {
        String(localized: "Diese Anwendung setzt den ZUGFeRD-/Factur-X-Standard um. Die Wiedergabe der zugrunde liegenden Veröffentlichung erfolgt nach den von FeRD veröffentlichten Nutzungsbedingungen mit Erlaubnis von CEN und DIN als Copyright-Inhabern.")
    }

    static func severity(_ severity: InvoiceValidationResult.Issue.Severity) -> String {
        switch severity {
        case .error: String(localized: "Fehler")
        case .warning: String(localized: "Warnung")
        case .information: String(localized: "Information")
        }
    }

    static func step(_ id: String, ruleSet: InvoiceValidationRuleSet? = nil) -> String {
        switch id {
        case "val-xml": String(localized: "XML-Syntax")
        case "val-xsd": String(localized: "XML-Schema (XSD)")
        case "val-sch.1": ruleSet?.id == InvoiceValidationRuleSet.facturX.id ? String(localized: "Factur-X-Profilregeln") : String(localized: "EN-16931-Regeln")
        case "val-sch.2": String(localized: "XRechnung-Regeln")
        case "pdfa": "PDF/A"
        case "pdf-embedding": String(localized: "PDF-Einbettung")
        default: id
        }
    }

    static func field(for issue: InvoiceValidationResult.Issue, document: EInvoiceDocument?) -> String? {
        if issue.code == "BR-DE-15" { return "BT-10 · " + String(localized: "Käuferreferenz (z. B. Leitweg-ID)") }
        guard let location = issue.location else { return nil }
        // Nur eindeutige Zuordnung aus dem tatsächlich angezeigten XML;
        // ein unklarer XPath bleibt als Fundstelle sichtbar.
        let matches = document?.fields.filter { field in
            field.path == location || (field.term != nil && location.hasSuffix("/" + field.element))
        } ?? []
        let terms = Set(matches.compactMap(\.term))
        guard terms.count == 1, let field = matches.first, let term = terms.first else { return nil }
        return term + (field.termName.map { " · " + $0 } ?? "")
    }

    static func report(result: InvoiceValidationResult?, status: InvoiceValidationStatus?, error: String?, url: URL?,
                       document: EInvoiceDocument? = nil) -> String {
        var lines = [String(localized: "E-Rechnungsprüfung"), url?.path ?? "", title(status)]
        lines.append(String(localized: "Das Ergebnis gilt ausschließlich für den dokumentierten Dateistand."))
        if let result {
            lines += [result.checkedAt, result.ruleSet?.id ?? "", result.ruleSet?.engine ?? "",
                      result.profile?.guidelineID ?? "", result.source.map { "XML SHA-256: " + $0.xmlSHA256 } ?? "",
                      result.source.map { "FILE SHA-256: " + $0.fileSHA256 } ?? ""]
            if let xmlStatus = result.xmlStatus, xmlStatus != result.status { lines.append(title(xmlStatus)) }
            for item in steps(result) { lines.append("\(step(item.id, ruleSet: result.ruleSet)) [\(item.id)]: \(stepStatus(item.status))") }
            for issue in result.issues {
                lines.append("\(severity(issue.severity)) [\(issue.code ?? "XML")]: \(issue.message)")
                if let field = field(for: issue, document: document) { lines.append(field) }
                if let location = issue.location { lines.append(location) }
            }
            if result.source?.url.pathExtension.lowercased() == "pdf" {
                lines.append(String(localized: "Prüfumfang: Rechnungs-XML. PDF/A, Einbettung und sichtbarer PDF-Inhalt sind nicht geprüft."))
            }
        }
        if let error { lines.append(error) }
        lines += ["", notice, "", standardNotice]
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

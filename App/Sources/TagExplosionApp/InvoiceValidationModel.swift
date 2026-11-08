import TagExplosionApplication
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
    private var session: InvoiceValidationSession
    private let pdfBundle: URL
    private var watcher: DispatchSourceFileSystemObject?

    init(bundle: URL? = nil, initialResult: InvoiceValidationResult? = nil) {
        self.bundle = bundle ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("XRechnungValidator")
        self.pdfBundle = self.bundle.deletingLastPathComponent().appendingPathComponent("PDFValidator")
        self.session = InvoiceValidationSession(pdfBundle: self.pdfBundle)
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
        session = InvoiceValidationSession(pdfBundle: pdfBundle)
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

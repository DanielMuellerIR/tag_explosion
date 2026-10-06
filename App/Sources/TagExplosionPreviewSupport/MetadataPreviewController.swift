import AppKit
import TagExplosionCore

@MainActor
open class MetadataPreviewController: NSViewController {
    public typealias Reader = @Sendable (URL) async throws -> MetadataPreview
    private let reader: Reader
    private var requestID = UUID()
    private var preparation: Task<Void, Never>?
    private(set) var preview: MetadataPreview?

    public init(reader: @escaping Reader = { url in
        try await BlockingWork.run { try MetadataPreview.read(url: url) }
    }) {
        self.reader = reader
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        reader = { url in try await BlockingWork.run { try MetadataPreview.read(url: url) } }
        super.init(coder: coder)
    }

    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        reader = { url in try await BlockingWork.run { try MetadataPreview.read(url: url) } }
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    open override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        preferredContentSize = NSSize(width: 680, height: 600)
    }

    public func prepare(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        preparation?.cancel()
        requestID = UUID()
        let request = requestID
        preview = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        preparation = Task { @MainActor in
            defer { if requestID == request { preparation = nil } }
            do {
                let preview = try await reader(url)
                guard requestID == request, !Task.isCancelled else {
                    handler(CocoaError(.userCancelled))
                    return
                }
                self.preview = preview
                let content = preview.makeView()
                content.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(content)
                NSLayoutConstraint.activate([
                    content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    content.topAnchor.constraint(equalTo: view.topAnchor),
                    content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
                handler(nil)
            } catch {
                handler(requestID == request && !Task.isCancelled ? error : CocoaError(.userCancelled))
            }
        }
    }
}

import AppKit
import QuickLookUI
import TagExplosionPreviewSupport
import TagExplosionCore

@objc(TagExplosionPreviewController)
@MainActor
final class PreviewController: NSViewController, @preconcurrency QLPreviewingController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))
        preferredContentSize = NSSize(width: 680, height: 600)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                let preview = try await BlockingWork.run { try MetadataPreview.read(url: url) }
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
                handler(error)
            }
        }
    }
}

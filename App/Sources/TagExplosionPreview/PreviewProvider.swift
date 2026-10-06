import AppKit
import QuickLookUI
import TagExplosionPreviewSupport
import TagExplosionCore

@objc(TagExplosionPreviewController)
@MainActor
final class PreviewController: MetadataPreviewController, @preconcurrency QLPreviewingController {
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        prepare(at: url, completionHandler: handler)
    }
}

// SwiftPMs natives Bausystem erwartet auch bei einer Erweiterung ein
// Executable-main-Symbol. Der Linker startet tatsächlich NSExtensionMain
// (App/Package.swift); dieser Einstieg wird nicht ausgeführt.
@main
private struct PreviewExtensionEntry {
    static func main() {}
}

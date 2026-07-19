// Brücke zwischen SwiftUI und dem echten NSWindow-Schließen. Der rote Button
// und Cmd-W laufen über `windowShouldClose`, nicht über `onDisappear` nach dem
// bereits erfolgten Schließen.
import AppKit
import SwiftUI

struct WindowCloseAccessor: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        context.coordinator.model = model
        if let window = nsView.window { context.coordinator.install(on: window) }
    }

    final class AccessorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator?.install(on: window) }
        }
    }

    /// Proxy statt blindem Überschreiben: Andere optionale NSWindowDelegate-
    /// Methoden werden weiterhin an den vorhandenen SwiftUI-Delegate geleitet.
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var model: AppModel?
        private weak var window: NSWindow?
        // NSObject fragt `responds(to:)` und `forwardingTarget(for:)` über
        // nonisolated Signaturen ab. AppKit ruft beides auf dem Hauptthread;
        // deshalb ist diese schwache Referenz dort bewusst als unsafe markiert.
        nonisolated(unsafe) private weak var forwardedDelegate: (any NSWindowDelegate)?
        private var bypassNextClose = false

        init(model: AppModel) {
            self.model = model
        }

        func install(on window: NSWindow) {
            guard self.window !== window || window.delegate !== self else { return }
            uninstall()
            self.window = window
            // Falls ein anderer Teil der App den Delegate seit dem letzten
            // Update ersetzt hat, wird genau dieser als nächstes weitergeleitet.
            forwardedDelegate = window.delegate
            window.delegate = self
        }

        private func uninstall() {
            guard let window else { return }
            // Nur den eigenen Proxy zurücknehmen. Hat ein anderer Besitzer den
            // Delegate inzwischen ersetzt, fassen wir dessen Einstellung nicht an.
            if window.delegate === self { window.delegate = forwardedDelegate }
            self.window = nil
            forwardedDelegate = nil
        }

        nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
            // AppKit ruft diese Delegate-Methode auf dem Hauptthread auf. Die
            // explizite Annahme hält die NSObject-Signatur nonisolated, ohne
            // den Zugriff auf NSWindow oder das AppModel nebenläufig zu machen.
            MainActor.assumeIsolated { handleWindowShouldClose(sender) }
        }

        private func handleWindowShouldClose(_ sender: NSWindow) -> Bool {
            if bypassNextClose {
                bypassNextClose = false
                return forwardedDelegate?.windowShouldClose?(sender) ?? true
            }

            Task { @MainActor [weak self, weak sender] in
                guard let self, let sender, let model else { return }
                await model.requestWindowClose { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    self.closeAfterApproval(sender)
                }
            }
            return false
        }

        private func closeAfterApproval(_ sender: NSWindow) {
            guard window === sender else { return }
            // Der nächste Delegate-Aufruf darf passieren; ohne diesen einmaligen
            // Bypass würde der bestätigte Close wieder einen Konfliktdialog öffnen.
            bypassNextClose = true
            sender.performClose(nil)
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector)
                || forwardedDelegate?.responds(to: aSelector) == true
        }

        nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: aSelector) == true,
               let target = forwardedDelegate {
                return target
            }
            return super.forwardingTarget(for: aSelector)
        }

        deinit {
            // Der Accessor kann beim Szenenwechsel verschwinden. Die Bedingung
            // in `uninstall` schützt dabei einen inzwischen neuen Delegate.
            MainActor.assumeIsolated { uninstall() }
        }
    }
}

// Brücke zwischen SwiftUI und dem echten NSWindow. Sie erledigt drei Dinge,
// für die SwiftUI allein keinen Weg bietet:
//
//  1. Schließen: Der rote Button und Cmd-W laufen über `windowShouldClose`,
//     nicht über `onDisappear` nach dem bereits erfolgten Schließen.
//  2. Zuordnung: Genau hier steht fest, welches AppModel zu welchem Fenster
//     gehört — deshalb meldet die Brücke das Modell bei `WindowSessions` an
//     und wieder ab. Ohne diese Zuordnung wüsste die App nicht, in welches
//     Fenster eine von außen geöffnete Datei gehört.
//  3. Dokument-Identität: `representedURL` ist der native macOS-Vertrag für
//     Dokumentfenster — AppKit zeigt darüber das Datei-Icon und baut bei
//     Command-Klick auf Titel oder Icon das hierarchische Pfadmenü.
import AppKit
import SwiftUI

struct WindowBridge: NSViewRepresentable {
    let model: AppModel
    /// Datei, die das Fenster gerade zeigt (nil = keine oder mehrere).
    let documentURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        context.coordinator.model = model
        context.coordinator.documentURL = documentURL
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
        var documentURL: URL? {
            didSet { applyDocumentURL() }
        }
        private weak var window: NSWindow?
        // NSObject fragt `responds(to:)` und `forwardingTarget(for:)` über
        // nonisolated Signaturen ab. AppKit ruft beides auf dem Hauptthread;
        // deshalb ist diese schwache Referenz dort bewusst als unsafe markiert.
        nonisolated(unsafe) private weak var forwardedDelegate: (any NSWindowDelegate)?
        private var bypassNextClose = false
        private var keyObserver: NSObjectProtocol?

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
            // Erst jetzt hat das Modell wirklich ein Fenster. Anmeldung und
            // Fensterzeiger gehören deshalb zusammen an diese eine Stelle.
            if let model {
                model.hostWindow = window
                WindowSessions.shared.register(model)
            }
            observeKeyWindow(window)
            applyDocumentURL()
        }

        private func uninstall() {
            guard let window else { return }
            // Nur den eigenen Proxy zurücknehmen. Hat ein anderer Besitzer den
            // Delegate inzwischen ersetzt, fassen wir dessen Einstellung nicht an.
            if window.delegate === self { window.delegate = forwardedDelegate }
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            self.window = nil
            forwardedDelegate = nil
        }

        /// Merkt sich, welches Fenster zuletzt vorn war. Dateien von außen
        /// landen dadurch im Fenster, mit dem gerade gearbeitet wird.
        private func observeKeyWindow(_ window: NSWindow) {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model else { return }
                    WindowSessions.shared.markActive(model)
                }
            }
            if window.isKeyWindow, let model { WindowSessions.shared.markActive(model) }
        }

        /// AppKit bildet aus einer gesetzten URL notfalls selbst einen Titel.
        /// Den Titel setzt weiterhin SwiftUI (`navigationTitle`); hier geht es
        /// nur um Datei-Icon und Pfadmenü.
        private func applyDocumentURL() {
            guard let window else { return }
            guard window.representedURL != documentURL else { return }
            window.representedURL = documentURL
        }

        nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
            // AppKit ruft diese Delegate-Methode auf dem Hauptthread auf. Die
            // explizite Annahme hält die NSObject-Signatur nonisolated, ohne
            // den Zugriff auf NSWindow oder das AppModel nebenläufig zu machen.
            MainActor.assumeIsolated { handleWindowShouldClose(sender) }
        }

        /// Das Fenster ist wirklich weg: Das Modell darf keine Dateien mehr
        /// zugeteilt bekommen. Der SwiftUI-Delegate bekommt die Nachricht
        /// ausdrücklich weitergereicht — `forwardingTarget` greift nur für
        /// Methoden, die dieser Proxy selbst nicht kennt.
        func windowWillClose(_ notification: Notification) {
            if let model { WindowSessions.shared.unregister(model) }
            forwardedDelegate?.windowWillClose?(notification)
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
            // Der Accessor kann beim Szenenwechsel verschwinden, obwohl das
            // Fenster bleibt. Deshalb wird hier NICHT abgemeldet: Das erledigt
            // `windowWillClose`, wenn das Fenster wirklich weggeht. Die
            // Bedingung in `uninstall` schützt einen inzwischen neuen Delegate.
            MainActor.assumeIsolated { uninstall() }
        }
    }
}

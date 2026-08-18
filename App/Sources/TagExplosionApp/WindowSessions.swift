// Verzeichnis aller offenen Fenster. Jedes Fenster hat sein eigenes AppModel
// mit eigener Dateiliste; Ereignisse aus macOS (Datei öffnen, Beenden) treffen
// aber die App als Ganzes. Diese Registry ist die einzige Stelle, die alle
// Fenster kennt — und die weiß, was zu tun ist, wenn gerade keines offen ist.
import AppKit
import SwiftUI
import TagExplosionCore

/// Was AppKit über das Fenster eines Modells sagt. Als eigener Wert, damit die
/// Verteillogik unten ohne echte Fenster (und damit headless) prüfbar bleibt.
struct WindowStatus: Equatable {
    /// Das Fenster existiert noch. false = geschlossen und freigegeben.
    var exists = false
    var isVisible = false
    var isKey = false
    var isMain = false
}

@MainActor
final class WindowSessions {
    static let shared = WindowSessions()

    /// Offene Fenster in der Reihenfolge, in der sie entstanden sind.
    private(set) var models: [AppModel] = []
    /// Zuletzt nach vorn geholtes Fenster. Es ist das Ziel für Dateien von
    /// außen, wenn AppKit gerade kein Schlüsselfenster meldet.
    private var lastActive: AppModel?
    /// Dateien, die ankamen, als es kein Fenster gab. Sie warten auf das
    /// nächste Fenster — beim Kaltstart aus dem Finder ebenso wie nach dem
    /// Schließen des letzten Fensters.
    private var pendingURLs: [URL] = []
    /// Ein angefordertes Fenster ist noch nicht da. Ohne diesen Merker könnten
    /// zwei kurz aufeinanderfolgende Anforderungen (Öffnen-Ereignis und das
    /// Sicherheitsnetz beim Start) zwei Fenster erzeugen.
    private var isRequestingWindow = false
    /// Wie oft für die aktuell wartenden Dateien schon ein Fenster angefordert
    /// wurde. Begrenzt das automatische Nachfassen, wenn kein Fenster entsteht.
    private var windowRequestAttempts = 0

    /// Legt ein neues Fenster an. `false` = der Start ist fehlgeschlagen.
    /// Für Tests ersetzbar.
    var makeWindow: @MainActor () -> Bool = WindowSessions.reopenApplication
    /// Frist, nach der ein angefordertes, aber nie angemeldetes Fenster als
    /// ausgeblieben gilt. Für Tests verkürzbar.
    var windowRequestTimeout: Duration = .seconds(5)
    /// Wie oft ein ausbleibendes Fenster automatisch neu angefordert wird.
    /// Danach entscheidet wieder der Nutzer (Öffnen-Dialog, Datei aus dem
    /// Finder) — endloses Nachfassen im Hintergrund wäre schlimmer als gar
    /// keins.
    var maxWindowRequestAttempts = 2
    /// Fensterzustand eines Modells. Für Tests ersetzbar.
    var statusOf: @MainActor (AppModel) -> WindowStatus = WindowSessions.appKitStatus
    /// Öffnet Dateien in einem Fenster. Für Tests ersetzbar.
    var openInModel: @MainActor (AppModel, [URL]) -> Void = { model, urls in
        Task { await model.open(urls: urls) }
    }

    // MARK: - An- und Abmelden

    /// Wird von der Fensterbrücke gerufen, sobald das Modell wirklich ein
    /// Fenster hat. Erst dann darf es Dateien aufnehmen.
    func register(_ model: AppModel) {
        isRequestingWindow = false
        windowRequestAttempts = 0
        pruneClosedWindows()
        if !models.contains(where: { $0 === model }) { models.append(model) }
        lastActive = model
        deliverPending(to: model)
    }

    func unregister(_ model: AppModel) {
        models.removeAll { $0 === model }
        pruneClosedWindows()
        if lastActive === model { lastActive = models.last }
    }

    /// Das Fenster wurde nach vorn geholt.
    func markActive(_ model: AppModel) {
        guard models.contains(where: { $0 === model }) else { return }
        lastActive = model
    }

    /// Sicherheitsnetz: Angemeldet wird nur mit Fenster, ein verschwundenes
    /// Fenster bedeutet also ein totes Modell. Bliebe `windowWillClose` einmal
    /// aus, verschluckte ein solches Modell sonst geöffnete Dateien.
    private func pruneClosedWindows() {
        models.removeAll { !statusOf($0).exists }
        if let lastActive, !models.contains(where: { $0 === lastActive }) {
            self.lastActive = models.last
        }
    }

    // MARK: - Zielfenster

    /// Fenster, das Dateien von außen aufnehmen soll. Modelle ohne sichtbares
    /// Fenster kommen bewusst nicht in Frage: Genau das war der Fehler, durch
    /// den nach dem Schließen des letzten Fensters geöffnete Dateien unsichtbar
    /// in einem fensterlosen Modell landeten.
    var frontmost: AppModel? {
        let visible = models.filter { statusOf($0).isVisible }
        return visible.first { statusOf($0).isKey }
            ?? visible.first { statusOf($0).isMain }
            ?? visible.first { $0 === lastActive }
            ?? visible.last
    }

    // MARK: - Öffnen

    /// Öffnet Dateien im vordersten Fenster; ohne Fenster entsteht erst eins.
    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let target = frontmost else {
            pendingURLs.append(contentsOf: urls)
            requestWindow()
            return
        }
        openInModel(target, urls)
    }

    /// Öffnen-Dialog aus dem Menü. Er funktioniert auch ohne Fenster — dann
    /// legt das Öffnen selbst eines an.
    func presentOpenPanel() {
        guard let urls = MediaOpenPanel.run() else { return }
        open(urls: urls)
    }

    /// Fordert ein Fenster an, sofern nicht schon eines unterwegs ist.
    ///
    /// Der Merker wird auf JEDEM Weg wieder frei: bei einem fehlgeschlagenen
    /// Start sofort, sonst spätestens nach `windowRequestTimeout`. Vorher löste
    /// ihn ausschließlich `register`; blieb das Fenster aus, wies die Registry
    /// bis zum App-Neustart jede weitere Anforderung ab, und die wartenden
    /// Dateien blieben unsichtbar liegen (Review-Fund 2026-08-18).
    func requestWindow() {
        guard !isRequestingWindow else { return }
        isRequestingWindow = true
        windowRequestAttempts += 1
        guard makeWindow() else {
            isRequestingWindow = false
            return
        }
        let attempt = windowRequestAttempts
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.windowRequestTimeout ?? .seconds(5))
            guard let self, isRequestingWindow, windowRequestAttempts == attempt else { return }
            // Kein Fenster in der Frist: Merker lösen und, solange Dateien
            // warten, begrenzt nachfassen.
            isRequestingWindow = false
            guard !pendingURLs.isEmpty, windowRequestAttempts < maxWindowRequestAttempts else {
                return
            }
            requestWindow()
        }
    }

    private func deliverPending(to model: AppModel) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        openInModel(model, urls)
    }

    /// Der AppKit-Weg zu einem neuen Fenster: Ein Reopen auf das eigene Bundle
    /// wirkt wie ein Klick aufs Dock-Symbol, und SwiftUI legt daraufhin ein
    /// Fenster der `WindowGroup` an. Einen direkten Aufruf gibt es hier nicht —
    /// SwiftUIs `openWindow` lebt in der View-Umgebung, und genau die fehlt,
    /// wenn kein Fenster mehr offen ist.
    static func reopenApplication() -> Bool {
        NSWorkspace.shared.open(Bundle.main.bundleURL)
    }

    /// Fensterzustand aus AppKit. `hostWindow` ist schwach: Ist das Fenster
    /// freigegeben, steht dort nil.
    static func appKitStatus(_ model: AppModel) -> WindowStatus {
        guard let window = model.hostWindow else { return WindowStatus() }
        return WindowStatus(exists: true, isVisible: window.isVisible,
                            isKey: window.isKeyWindow, isMain: window.isMainWindow)
    }

    // MARK: - Beenden

    /// Hat irgendein Fenster etwas zu verlieren?
    var needsTerminationConfirmation: Bool {
        models.contains {
            $0.hasDirtyEntries || $0.hasSavingEntries || $0.isDestructiveActionLocked
        }
    }

    /// Höchstzahl der Fragerunden. Eine Runde genügt im Normalfall; weitere
    /// braucht es nur, wenn WÄHREND der Runde neue ungespeicherte Änderungen
    /// entstanden sind. Die Grenze verhindert eine Endlosschleife, wenn jemand
    /// unablässig weiterschreibt — dann bleibt die App eben offen.
    static let maxTerminationRounds = 8

    /// Fragt jedes Fenster mit ungespeicherten Änderungen der Reihe nach.
    /// Ein einziges Abbrechen beendet die Runde: Die App bleibt offen, und die
    /// übrigen Fenster werden nicht mehr behelligt.
    ///
    /// Gefragt wird in RUNDEN gegen die jeweils aktuelle Registry, und `true`
    /// gibt es erst, wenn danach kein Fenster mehr etwas zu verlieren hat:
    /// Während der Dialog eines Fensters offen steht, bleiben die anderen
    /// Fenster bedienbar. Ein längst bestätigtes Fenster kann dort erneut
    /// bearbeitet werden, und ein neues Fenster kann dazukommen — die einmal
    /// gebildete Fensterliste sah beides nicht, und AppKit beendete die App
    /// anschließend mitsamt diesen Änderungen (Review-Fund 2026-08-18).
    func confirmTermination() async -> Bool {
        for _ in 0..<Self.maxTerminationRounds {
            for model in models {
                // Saubere Fenster werden nicht behelligt — in einer
                // Wiederholungsrunde sind das fast alle.
                guard model.hasDirtyEntries || model.hasSavingEntries
                    || model.isDestructiveActionLocked else { continue }
                // Gefragt wird im sichtbaren Fenster — sonst stünde der Dialog
                // hinter einem anderen und niemand fände die Frage.
                model.hostWindow?.makeKeyAndOrderFront(nil)
                let decision = await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        await model.requestTermination { continuation.resume(returning: $0) }
                    }
                }
                switch decision {
                case .terminateCancel: return false
                case .terminateNow: continue
                }
            }
            // Schlussabgleich gegen die aktuelle Registry: Erst ein Stand ohne
            // jede offene Änderung darf das Beenden freigeben.
            if !needsTerminationConfirmation { return true }
        }
        return false
    }
}

/// Öffnen-Dialog für Mediendateien und Ordner. Eigener Typ, weil ihn sowohl
/// ein Fenster (Werkzeugleiste) als auch die fensterlose Registry (Menü) braucht.
enum MediaOpenPanel {
    /// Zeigt den Dialog. nil = abgebrochen.
    @MainActor
    static func run() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Mediendateien (Audio, Bild, Video, E-Book, E-Rechnung) oder Ordner auswählen")
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

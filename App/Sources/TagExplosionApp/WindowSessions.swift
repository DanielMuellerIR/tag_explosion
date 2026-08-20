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
    /// Zustand einer laufenden Fensteranforderung. Merker, Versuchszähler und
    /// Watchdog gehören zusammen und liegen deshalb in EINEM Wert: Als drei
    /// unabhängige Variablen liefen sie auseinander — der Watchdog einer längst
    /// erledigten Anforderung hielt sich für den der laufenden und forderte ein
    /// zweites Fenster an (Review-Fund 2026-08-20).
    private struct WindowRequest {
        /// Fortlaufende Nummer JEDER Anforderung. Sie wird nie zurückgesetzt —
        /// nur so erkennt ein Watchdog zuverlässig, dass er veraltet ist.
        var generation = 0
        /// Wie oft in DIESER Anforderungskette schon ein Fenster verlangt wurde.
        /// Eine Kette beginnt mit einem Nutzerereignis und endet, sobald ein
        /// Fenster da ist oder der Etat aufgebraucht wurde.
        var attempts = 0
        /// Eine Anforderung ist unterwegs. Ohne diesen Merker könnten zwei kurz
        /// aufeinanderfolgende Anforderungen (Öffnen-Ereignis und das
        /// Sicherheitsnetz beim Start) zwei Fenster erzeugen.
        var isPending = false
        /// Wacht über die Frist der laufenden Anforderung.
        var watchdog: Task<Void, Never>?
    }
    private var windowRequest = WindowRequest()

    /// Legt ein neues Fenster an. `false` = der Start ist fehlgeschlagen.
    /// Für Tests ersetzbar.
    var makeWindow: @MainActor () -> Bool = WindowSessions.reopenApplication
    /// Frist, nach der ein angefordertes, aber nie angemeldetes Fenster als
    /// ausgeblieben gilt. Für Tests verkürzbar.
    var windowRequestTimeout: Duration = .seconds(5)
    /// Höchstzahl der Anforderungen INSGESAMT je Kette, Erstversuch
    /// eingeschlossen: 2 heißt also „einmal nachfassen". Danach entscheidet
    /// wieder der Nutzer (Öffnen-Dialog, Datei aus dem Finder) — endloses
    /// Nachfassen im Hintergrund wäre schlimmer als gar keins.
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
        // Die Anforderung ist erfüllt: Merker frei, Watchdog abbestellen. Ohne
        // das Abbestellen fasste er später für eine ganz andere Anforderung
        // nach. `unregister` räumt bewusst NICHT auf — schließt sich ein
        // Fenster, während ein anderes angefordert ist, wird das angeforderte
        // weiterhin gebraucht.
        finishWindowRequest()
        windowRequest.attempts = 0
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

    /// Fordert ein Fenster an, sofern nicht schon eines unterwegs ist. Startet
    /// eine NEUE Kette: Der Nachfass-Etat gilt je Kette und beginnt hier von
    /// vorn. Vorher zählte ein einziger Zähler über die ganze Sitzung — nach
    /// dem ersten ausgebliebenen Fenster war das Nachfassen für immer
    /// abgeschaltet (Review-Fund 2026-08-20).
    ///
    /// Der Merker wird auf JEDEM Weg wieder frei: bei einem fehlgeschlagenen
    /// Start sofort, sonst spätestens nach `windowRequestTimeout`. Vorher löste
    /// ihn ausschließlich `register`; blieb das Fenster aus, wies die Registry
    /// bis zum App-Neustart jede weitere Anforderung ab, und die wartenden
    /// Dateien blieben unsichtbar liegen (Review-Fund 2026-08-18).
    func requestWindow() {
        guard !windowRequest.isPending else { return }
        windowRequest.attempts = 0
        startWindowRequest()
    }

    /// Ein einzelner Versuch innerhalb der laufenden Kette.
    private func startWindowRequest() {
        windowRequest.generation += 1
        windowRequest.isPending = true
        windowRequest.attempts += 1
        guard makeWindow() else {
            // Ein Fehlstart darf den Etat nicht belasten: Sonst wäre nach einem
            // einzigen Fehlversuch für den Rest der Kette nichts mehr übrig.
            windowRequest.attempts -= 1
            windowRequest.isPending = false
            return
        }
        let generation = windowRequest.generation
        let timeout = windowRequestTimeout
        windowRequest.watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, windowRequest.isPending,
                  windowRequest.generation == generation else { return }
            // Kein Fenster in der Frist: Merker lösen und, solange Dateien
            // warten, innerhalb des Etats dieser Kette nachfassen.
            windowRequest.isPending = false
            windowRequest.watchdog = nil
            guard !pendingURLs.isEmpty,
                  windowRequest.attempts < maxWindowRequestAttempts else { return }
            startWindowRequest()
        }
    }

    /// Beendet die laufende Anforderung und bestellt ihren Watchdog ab.
    private func finishWindowRequest() {
        windowRequest.isPending = false
        windowRequest.watchdog?.cancel()
        windowRequest.watchdog = nil
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
        models.contains(where: \.hasUnfinishedWork)
    }

    /// Höchstzahl der Fragerunden. Eine Runde genügt im Normalfall; weitere
    /// braucht es nur, wenn WÄHREND der Runde neue ungespeicherte Änderungen
    /// entstanden sind. Die Grenze verhindert eine Endlosschleife, wenn jemand
    /// unablässig weiterschreibt — dann bleibt die App eben offen. Als
    /// Instanzfeld, damit Tests den Erschöpfungsfall überhaupt erreichen
    /// (Review-Fund 2026-08-20).
    var maxTerminationRounds = 8

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
        for _ in 0..<maxTerminationRounds {
            for model in models {
                // Saubere Fenster werden nicht behelligt — in einer
                // Wiederholungsrunde sind das fast alle.
                guard model.hasUnfinishedWork else { continue }
                // Und Fenster, die sich WÄHREND der Runde abgemeldet haben,
                // erst recht nicht: Ihr Dialog erschiene nirgends mehr, die
                // Continuation unten würde nie fortgesetzt und ⌘Q hinge ohne
                // Antwort an AppKit (Review-Fund 2026-08-20).
                guard models.contains(where: { $0 === model }) else { continue }
                // Nach vorn nur, wenn der Nutzer dort auch etwas zu sehen
                // bekommt: die eigene Rückfrage (ungespeicherte Änderungen)
                // oder den bereits offenen Dialog, an dem ⌘Q gerade scheitert.
                // Ein reines Speichern beantwortet `requestTermination` ohne
                // jede Frage — das Fenster dafür nach vorn zu reißen wäre nur
                // ein Zucken ohne Erklärung (Review-Fund 2026-08-20).
                if model.hasDirtyEntries || model.isDestructiveActionLocked {
                    model.hostWindow?.makeKeyAndOrderFront(nil)
                }
                let decision = await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        await model.requestTermination { continuation.resume(returning: $0) }
                    }
                }
                if case .terminateCancel = decision { return false }
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

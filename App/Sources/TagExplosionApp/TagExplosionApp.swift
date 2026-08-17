// Einstiegspunkt der macOS-App.
import Combine
import Sparkle
import SwiftUI
import TagExplosionCore

/// Hält den Sparkle-Updater. Sparkle verwaltet Suche, Download, Signaturprüfung,
/// Austausch der App und Neustart. Als langlebiges Feld bleibt der Controller
/// während der gesamten App-Laufzeit erhalten; mehr als eine Instanz darf es
/// nicht geben.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var terminationReplyPending = false

    /// Finder, Dock und `open -a` liefern Dateien über diesen Weg — zuverlässig
    /// auch beim Kaltstart, anders als SwiftUIs `onOpenURL`. Wohin die Dateien
    /// gehören, entscheidet `WindowSessions`: ins vorderste Fenster, und wenn
    /// gerade keines offen ist, in ein neu angelegtes.
    func application(_ application: NSApplication, open urls: [URL]) {
        WindowSessions.shared.open(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindowIfHidden()
    }

    /// Startet man die App aus dem Finder mit einer Datei ("Öffnen mit …",
    /// Drag aufs Dock-Symbol), legt SwiftUI überhaupt kein Fenster der
    /// `WindowGroup` an — `NSApp.windows` bleibt leer. Die App läuft dann
    /// unsichtbar weiter und bekommt die zu öffnende Datei nie zugestellt, weil
    /// macOS das Öffnen-Ereignis erst an ein vorhandenes Fenster ausliefert.
    ///
    /// `WindowSessions.requestWindow()` holt das Fenster nach (Reopen aufs
    /// eigene Bundle) und sorgt zugleich dafür, dass ein bereits angefordertes
    /// Fenster nicht ein zweites Mal entsteht. Ohne Datei gestartet ist längst
    /// ein Fenster da, dann tut diese Prüfung nichts.
    private func showWindowIfHidden() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            WindowSessions.shared.requestWindow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sessions = WindowSessions.shared
        guard sessions.needsTerminationConfirmation else { return .terminateNow }
        // AppKit kann die Anfrage wiederholen, solange wir terminateLater
        // gemeldet haben. Genau ein Modellauftrag darf darauf antworten.
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        Task { @MainActor [weak self] in
            // Jedes Fenster wird einzeln gefragt; ein Abbrechen hält die App.
            let shouldTerminate = await sessions.confirmTermination()
            self?.terminationReplyPending = false
            NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}

/// Menüpunkt „Nach Updates suchen …". Deaktiviert sich über Sparkles
/// KVO-Eigenschaft canCheckForUpdates selbst, z.B. während einer bereits
/// laufenden Suche oder Installation.
struct CheckForUpdatesButton: View {
    let updater: SPUUpdater
    @State private var canCheck = false

    var body: some View {
        Button("Nach Updates suchen …") {
            updater.checkForUpdates()
        }
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

/// Das Modell des Fensters, in dem gerade gearbeitet wird. Menübefehle wirken
/// darüber immer auf das vorderste Fenster — jedes hat seine eigene Dateiliste.
private struct FocusedAppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[FocusedAppModelKey.self] }
        set { self[FocusedAppModelKey.self] = newValue }
    }
}

@main
struct TagExplosionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Kennung der Fenstergruppe — nötig, damit „Neues Fenster" gezielt ein
    /// weiteres Fenster dieser Gruppe öffnen kann.
    static let windowGroupID = "hauptfenster"

    var body: some Scene {
        WindowGroup(id: Self.windowGroupID) {
            MainWindow()
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updaterController.updater)
            }
            FileCommands()
            EditingCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Inhalt eines Fensters. Das Modell entsteht hier und nicht in der App:
/// So bekommt jedes Fenster seine eigene Dateiliste und Auswahl.
struct MainWindow: View {
    @State private var model = AppModel()

    var body: some View {
        ContentView()
            .environment(model)
            .frame(minWidth: 900, minHeight: 600)
            // Menübefehle greifen auf das Modell des vordersten Fensters zu.
            .focusedSceneValue(\.appModel, model)
            .onAppear { AppModel.applySafeMode() }
    }
}

/// Ablage-Menü: neues Fenster und Öffnen. Beides muss auch dann gehen, wenn
/// gerade kein Fenster offen ist — die Menüleiste bleibt ja bestehen.
struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Neues Fenster") {
                openWindow(id: TagExplosionApp.windowGroupID)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Öffnen …") {
                WindowSessions.shared.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}

/// Speichern und Verwerfen wirken auf das Fenster, das gerade vorn ist.
struct EditingCommands: Commands {
    @FocusedValue(\.appModel) private var model

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Speichern") {
                guard let model else { return }
                Task { await model.saveSelected() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.map { !$0.selectionIsDirty || $0.selectionIsSaving
                                 || $0.isDestructiveActionLocked } ?? true)

            Button("Alle speichern") {
                guard let model else { return }
                Task { await model.saveAll() }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model.map { !$0.hasDirtyEntries || $0.hasSavingEntries
                                 || $0.isDestructiveActionLocked } ?? true)

            Button("Änderungen verwerfen") {
                model?.revertSelected()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.map { !$0.selectionIsDirty || $0.isDestructiveActionLocked } ?? true)
        }
    }
}

/// Einstellungen (⌘,): abgesicherter Modus und Tag-Backup vor Batch-Speichern.
struct SettingsView: View {
    @AppStorage(AppModel.safeModeDefaultsKey) private var safeMode = true
    @AppStorage(AppModel.autoBackupDefaultsKey) private var autoBackup = true
    /// Wird beim Öffnen und nach jedem Speichern neu gelesen, damit die
    /// Größenangabe nicht veraltet.
    @State private var backedUpBytes: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle("Originale vor jeder Änderung in den Papierkorb kopieren", isOn: $safeMode)
                    .onChange(of: safeMode) { AppModel.applySafeMode() }
                Text("""
                Vor jeder Änderung landet eine unveränderte Kopie der Datei im \
                Papierkorb — gesammelt in einem Ordner je Sitzung. Geht etwas \
                schief, ziehen Sie die Kopie einfach zurück; zum Aufräumen \
                genügt es, den Papierkorb zu leeren.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                if backedUpBytes > 0 {
                    HStack {
                        Text("In dieser Sitzung gesichert: \(formattedBytes)")
                            .font(.caption)
                        Spacer()
                        Button("Papierkorb öffnen") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle("Vor Batch-Speichern Tag-Backup anlegen", isOn: $autoBackup)
                Text("""
                Schreibt vor dem Speichern mehrerer Dateien je Ordner ein \
                tags-backup-<Zeitstempel>.json mit dem bisherigen Zustand \
                (inklusive Cover). Wiederherstellen: „Tags aus JSON importieren …" \
                im Batch-Editor oder `tagx import`.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { backedUpBytes = TrashBackup.shared.backedUpBytes }
    }

    private var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: backedUpBytes, countStyle: .file)
    }
}

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
    /// Das SwiftUI-Modell gehört der App-Szene; der Delegate hält nur eine
    /// schwache Referenz, um Cmd-Q durch dieselbe Konfliktlogik zu leiten.
    weak var model: AppModel?
    private var terminationReplyPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.hasDirtyEntries || model.hasSavingEntries || model.isDestructiveActionLocked else {
            return .terminateNow
        }
        // AppKit kann die Anfrage wiederholen, solange wir terminateLater
        // gemeldet haben. Genau ein Modellauftrag darf darauf antworten.
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await model.requestTermination { [weak self] decision in
                guard let self else { return }
                self.terminationReplyPending = false
                let shouldTerminate: Bool
                switch decision {
                case .terminateNow: shouldTerminate = true
                case .terminateCancel: shouldTerminate = false
                }
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
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

@main
struct TagExplosionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.model = model
                    AppModel.applySafeMode()
                }
                // Dateien aus Finder/Dock ("Öffnen mit …")
                .onOpenURL { url in
                    Task { await model.open(urls: [url]) }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Öffnen …") {
                    model.presentOpenPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Speichern") {
                    Task { await model.saveSelected() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.selectionIsDirty || model.selectionIsSaving
                          || model.isDestructiveActionLocked)

                Button("Alle speichern") {
                    Task { await model.saveAll() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.hasDirtyEntries || model.hasSavingEntries
                          || model.isDestructiveActionLocked)

                Button("Änderungen verwerfen") {
                    model.revertSelected()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.selectionIsDirty || model.isDestructiveActionLocked)
            }
        }

        Settings {
            SettingsView()
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

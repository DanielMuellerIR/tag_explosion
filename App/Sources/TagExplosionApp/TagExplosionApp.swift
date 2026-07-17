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
                .disabled(!model.selectionIsDirty)

                Button("Alle speichern") {
                    Task { await model.saveAll() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.hasDirtyEntries)

                Button("Änderungen verwerfen") {
                    model.revertSelected()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.selectionIsDirty)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Einstellungen (⌘,): momentan nur das Auto-Backup vor Batch-Speichern.
struct SettingsView: View {
    @AppStorage(AppModel.autoBackupDefaultsKey) private var autoBackup = true

    var body: some View {
        Form {
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
        .padding(20)
        .frame(width: 460)
    }
}

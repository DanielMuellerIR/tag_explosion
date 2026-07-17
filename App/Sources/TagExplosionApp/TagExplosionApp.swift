// Einstiegspunkt der macOS-App.
import SwiftUI
import TagExplosionCore

@main
struct TagExplosionApp: App {
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
    }
}
